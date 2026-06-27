local json = require("vendor.json")
local Store = require("store")
local c = require("colors")
local LoopDetect = require("loopdetect")
local dangercheck = require("dangercheck")

local Agent = {}

-- Smart bash gate: even when bash is otherwise allowed, escalate a catastrophic
-- command to a prompt. Only applies to an allowed bash call; never downgrades
-- deny, never touches a tool already set to ask, never gates non-bash tools.
-- Returns: effective_permission, flag_reason (reason is nil unless escalated).
-- Render a tool call for --show-tools-json: "<name> <raw arguments>". The
-- arguments string is shown verbatim (it's the JSON the model emitted), so a
-- malformed or oddly-shaped payload is visible before cluade parses it.
function Agent._format_tool_json(tc)
  local fn = (type(tc) == "table" and tc["function"]) or {}
  local name = fn.name or "?"
  local args = fn.arguments
  if type(args) ~= "string" then
    args = (args == nil) and "{}" or json.encode(args)
  end
  return name .. " " .. args
end

-- The green on-execution label: tool name + its parameters. skill shows its
-- skill name; compact omits its (long) summary; everything else shows the raw
-- argument JSON, truncated to keep the label to one tidy line.
function Agent._tool_label(name, params, args_str)
  if name == "skill" and type(params) == "table" and params.name then
    return "using skill: " .. params.name
  end
  if name == "compact" then
    return "using tool: compact"
  end
  local args = (type(args_str) == "string") and args_str or json.encode(params or {})
  if #args > 200 then args = args:sub(1, 200) .. "..." end
  return "using tool: " .. name .. " " .. args
end

-- Pretty-print a decoded value as indented JSON (pure Lua, no external tools).
-- Scalars delegate to json.encode (consistent escaping); objects indent with
-- sorted keys for deterministic output; arrays put one element per line. Used
-- only for the decoded debug layer -- the raw-body layer stays literal.
function Agent._pretty_json(v, indent)
  if type(v) ~= "table" then return json.encode(v) end
  if next(v) == nil then return json.encode(v) end   -- empty {} or []
  indent = indent or ""
  local child = indent .. "  "
  local n = 0
  for _ in pairs(v) do n = n + 1 end
  local parts = {}
  if n == #v then
    for i = 1, n do parts[i] = child .. Agent._pretty_json(v[i], child) end
    return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
  end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for _, k in ipairs(keys) do
    parts[#parts + 1] = child .. json.encode(tostring(k)) .. ": " .. Agent._pretty_json(v[k], child)
  end
  return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
end

-- Build the --show-tools-json debug block for a response, in three layers:
--   [raw response body]   the literal wire bytes (when captured by the provider)
--   [tool_calls decoded]  the full decoded structure, pretty-printed (envelope + all)
--   [tool-call json] ...  one compact "<name> <args>" line per call
function Agent._format_tools_debug(response)
  local out = {}
  if response.raw_body then
    out[#out + 1] = "[raw response body]\n" .. response.raw_body
  end
  if response.tool_calls then
    local header = "[tool_calls decoded]"
    if response.reasoning_content and #response.reasoning_content > 0 then
      header = '[tool_calls decoded - reasoning: "' .. response.reasoning_content .. '"]'
    end
    out[#out + 1] = header .. "\n" .. Agent._pretty_json(response.tool_calls)
    for _, tc in ipairs(response.tool_calls) do
      out[#out + 1] = "[tool-call json] " .. Agent._format_tool_json(tc)
    end
  end
  return table.concat(out, "\n")
end

function Agent._effective_perm(base, name, params)
  if base == "allow" and name == "bash" and type(params) == "table" and params.command then
    local reason = dangercheck.match(params.command)
    if reason then return "ask", reason end
  end
  return base, nil
end

local SYSTEM_PROMPT = [[You are cluade, a coding agent running on OpenWRT (busybox ash, Linux MIPS).
You help the user with software engineering tasks.

Communication:
- Be concise. Your output is displayed on a terminal.
- Use GitHub-flavored markdown for formatting.
- Do not add unnecessary explanation unless asked.

Environment:
- You are running on a Linux system. Use standard Linux/ash commands.
- Busybox tools: grep, sed, awk, find, head, tail, cut, sort are available.
- Python is NOT available. Do not attempt Python commands.
- The shell is ash (busybox). Use ash-compatible syntax.
- Use /tmp for temporary files.]]

function Agent:init(config, cwd)
  self.config = config
  self.cwd = cwd
  self.tools = require("tools")
  -- Apply config-provided permissions as overrides on top of the tool defaults.
  -- Only the tools named in config change; everything else keeps tools.lua's
  -- defaults. (cluade.lua's --yes runs after this, so it still wins.)
  if type(config.permissions) == "table" then
    self.tools.set_permissions(config.permissions)
  end
  return self
end

-- Terminal-mode seams (overridable in tests). The real versions shell out to
-- stty against the controlling terminal so a permission prompt is always
-- canonical + echoed, even when the interactive REPL has left the terminal in
-- raw (-icanon -echo) mode. The prior mode is captured and restored exactly, so
-- one-shot mode (already cooked) is unaffected and the terminal is never left
-- in raw mode after a prompt.
function Agent._tty_save()
  local f = io.popen("stty -g 2>/dev/null </dev/tty")
  if not f then return nil end
  local saved = f:read("*l")
  f:close()
  if saved and #saved > 0 then return saved end
  return nil
end

function Agent._tty_cooked()
  os.execute("stty icanon echo 2>/dev/null </dev/tty")
end

function Agent._tty_restore(saved)
  os.execute("stty " .. saved .. " 2>/dev/null </dev/tty")
end

function Agent._read_line()
  return io.read("*l")
end

function Agent:prompt_yes_no(question)
  local saved = Agent._tty_save()
  if saved then Agent._tty_cooked() end
  io.write(question .. " [y/N] ")
  io.flush()
  local answer = Agent._read_line()
  if saved then Agent._tty_restore(saved) end
  return (answer and answer:lower():match("^y")) and true or false
end

function Agent:_read_instructions()
  local files = { "CLAUDE.md", "AGENTS.md", "GEMINI.md" }
  for _, name in ipairs(files) do
    local path = self.cwd .. "/" .. name
    local f = io.open(path, "r")
    if f then
      local content = f:read("*a")
      f:close()
      if #content > 0 then
        return "User instructions (from ./" .. name .. "):\n" .. content
      end
    end
  end
  return nil
end

function Agent:run(session, input)
  local provider = require("provider")
  local HttpProvider = provider
  local llm = HttpProvider:new(self.config)

  local messages = {}
  for _, m in ipairs(session.messages) do
    messages[#messages + 1] = m
  end

  if #messages == 0 then
    messages[1] = { role = "system", content = SYSTEM_PROMPT }
  end

  local skills = self.tools._scan_skills and self.tools._scan_skills() or {}
  if #skills > 0 then
    local lines = {}
    for _, s in ipairs(skills) do
      lines[#lines + 1] = "- " .. s.name .. ": " .. (s.description:sub(1, 80))
    end
    messages[1].content = messages[1].content .. "\n\nAvailable skills (use skill() to load):\n" .. table.concat(lines, "\n")
  end

  local instructions = self:_read_instructions()
  if instructions then
    messages[1].content = messages[1].content .. "\n\n" .. instructions
  end

  if input then
    messages[#messages + 1] = { role = "user", content = input }
  end

  local tool_names = { "read", "write", "edit", "bash", "glob", "grep", "web_search", "web_fetch", "remote_bash", "compact", "skill" }
  local tool_defs = self.tools.get_definitions(tool_names)
  local total_tokens = 0

  local function _estimate_total()
    local total = 0
    for _, m in ipairs(messages) do
      total = total + math.floor(#json.encode(m) / 3.5)
    end
    return total
  end

  local stopped_reason = "limit"
  local last_step = 0
  local detector = LoopDetect.new()
  for step = 1, self.config.max_steps do
    last_step = step
    io.write(c.step("[step " .. step .. "] thinking..."))
    io.flush()

    local t0 = os.time()
    local response, err = llm:chat(messages, tool_defs, { timeout = self.config.request_timeout or 600, max_tokens = self.config.max_tokens or 131072 })
    local elapsed = os.time() - t0

    if not response then
      io.write("\n" .. c.red("[provider error: " .. err .. "]") .. "\n")
      stopped_reason = "error"
      break
    end

    if response.usage then
      total_tokens = total_tokens + (response.usage.total_tokens or response.usage.completion_tokens or 0)
    end

    messages[#messages + 1] = {
      role = "assistant",
      content = response.content or "",
    }
    if response.reasoning_content then
      messages[#messages].reasoning_content = response.reasoning_content
    end
    if response.tool_calls then
      messages[#messages].tool_calls = response.tool_calls
    end

    if response.reasoning_content then
      io.write("\n" .. c.dim("[reasoned for " .. elapsed .. "s, " .. #response.reasoning_content .. " chars]") .. "\n")
    else
      io.write("\n" .. c.dim("[took " .. elapsed .. "s]") .. "\n")
    end
    if response.content and #response.content > 0 then
      io.write("\n" .. response.content .. "\n")
      io.flush()
    end

    if response.tool_calls and #response.tool_calls > 0 then
      if self.config.show_tools_json then
        io.write(c.step(Agent._format_tools_debug(response)) .. "\n")
      end
      for _, tc in ipairs(response.tool_calls) do
        local fn = tc["function"]
        local name = fn.name
        local base_perm = self.tools.get_permission(name)
        local params = {}
        local args_str = fn.arguments
        if args_str and type(args_str) == "string" then
          local ok, parsed = pcall(json.decode, args_str)
          if ok then
            for k, v in pairs(parsed) do params[k] = v end
          else
            io.write(string.format("\n" .. c.error("[tool param parse error: %s]") .. "\n", tostring(parsed)))
          end
        elseif type(args_str) == "table" then
          for k, v in pairs(args_str) do params[k] = v end
        end

        -- Smart bash gate may escalate an allowed-but-dangerous command to a prompt.
        local perm, flagged = Agent._effective_perm(base_perm, name, params)

        local result = nil
        if perm == "deny" then
          io.write(string.format("\n" .. c.error("[denied: %s]") .. "\n", name))
          result = { status = "error", error = "tool '" .. name .. "' is denied" }
        elseif perm == "ask" then
          local prompt = name
          if name == "bash" then
            prompt = "bash: " .. (params.command and params.command:sub(1, 80) or "?")
            if flagged then prompt = prompt .. c.yellow("  [flagged: " .. flagged .. "]") end
          elseif name == "remote_bash" then
            prompt = "remote_bash: " .. (params.username or "root") .. "@" .. (params.host or "?") .. ": " .. (params.command and params.command:sub(1, 60) or "?")
          elseif name == "write" then
            prompt = "write: " .. (params.filePath or "?")
          end
          if not self:prompt_yes_no("Allow " .. prompt .. "?") then
            result = { status = "error", error = "user denied " .. name }
          end
        end

        if not result then
          local label = Agent._tool_label(name, params, args_str)
          io.write(string.format(c.green("\n[%s]") .. "\n", label))
          result = self.tools.execute(self.cwd, name, params)
          io.write(result.output or tostring(result.error))
          io.write("\n")
        end

        messages[#messages + 1] = {
          role = "tool",
          tool_call_id = tc.id,
          content = json.encode(result),
        }

        -- Normalized signature: use the parsed params (key order canonicalized)
        -- when available, else fall back to the raw arg string so a call whose
        -- args failed to parse keeps its own identity.
        local sig = LoopDetect.signature(name, next(params) and params or args_str)
        detector:record_call(sig)
        detector:record_result(result.status == "error")

        if name == "compact" and result.status == "compacted" then
          local compact_msg = SYSTEM_PROMPT .. "\n\n[Session compressed. Summary of prior work:\n"
            .. result.summary .. "\nCurrent state preserved: open files, decisions, next steps.]"
          local new_messages = {
            { role = "system", content = compact_msg },
          }
          new_messages[#new_messages + 1] = messages[#messages - 1]
          new_messages[#new_messages + 1] = messages[#messages]
          messages = new_messages
          io.write(c.step("[Compacted: context freed for next task]") .. "\n")
        end
      end

      local action, reason = detector:check()
      if action == "warn" then
        local msg
        if reason == "repeat" then
          msg = "[cluade] You have called the same tool with identical arguments "
            .. detector.repeat_threshold .. " times in a row. This looks like a loop."
            .. " Change your approach, or stop if the task is already complete."
        else
          msg = "[cluade] The last " .. detector.error_threshold
            .. " tool calls all returned errors. Reconsider your approach, or stop if you cannot proceed."
        end
        messages[#messages + 1] = { role = "user", content = msg }
        io.write(c.yellow("\n[loop guard: warned the model (" .. reason .. ")]") .. "\n")
      elseif action == "stop" then
        stopped_reason = "loop"
        io.write("\n")
        break
      end
    elseif response.finish_reason == "stop" then
      io.write("\n")
      stopped_reason = "done"
      break
    end

    local context_limit = self.config.context_limit or 200000
    local threshold = self.config.compact_threshold or 0.85
    local est = _estimate_total()
    if est > context_limit * threshold then
      io.write(string.format("\n" .. c.step("[context at %d%% (%d/%d). Consider compacting.]") .. "\n",
        math.floor(est / context_limit * 100), est, context_limit))
    end
  end

  if stopped_reason == "limit" then
    io.write(c.yellow(string.format(
      "\n[reached the safety backstop of %d steps. Task may be incomplete -- send 'continue' to resume.]",
      self.config.max_steps)) .. "\n")
  elseif stopped_reason == "loop" then
    io.write(c.yellow(
      "\n[stopped: the model appears stuck (repeated the same action or errored repeatedly). send 'continue' to resume.]") .. "\n")
  end

  local new_messages = {}
  for _, m in ipairs(messages) do
    new_messages[#new_messages + 1] = m
  end
  session.messages = new_messages
  session.steps = last_step
  session.total_tokens = total_tokens
  session.context_tokens = _estimate_total()
  Store.save_session(self.config.sessions_dir, session.id, session)
end

return Agent
