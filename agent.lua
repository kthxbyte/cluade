local json = require("vendor.json")
local Store = require("store")
local c = require("colors")

local Agent = {}

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
  return self
end

function Agent:prompt_yes_no(question)
  io.write(question .. " [y/N] ")
  io.flush()
  local answer = io.read("*l")
  return answer and answer:lower():match("^y")
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

  for step = 1, self.config.max_steps do
    io.write(c.step("[step " .. step .. "/" .. self.config.max_steps .. "] thinking..."))
    io.flush()

    local t0 = os.time()
    local response, err = llm:chat(messages, tool_defs, { timeout = 120, max_tokens = self.config.max_tokens or 131072 })
    local elapsed = os.time() - t0

    if not response then
      io.write("\n" .. c.red("[provider error: " .. err .. "]") .. "\n")
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
    if response.content then
      io.write("\n" .. response.content .. "\n")
      io.flush()
    end

    if response.tool_calls and #response.tool_calls > 0 then
      for _, tc in ipairs(response.tool_calls) do
        local fn = tc["function"]
        local name = fn.name
        local perm = self.tools.get_permission(name)
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

        local result = nil
        if perm == "deny" then
          io.write(string.format("\n" .. c.error("[denied: %s]") .. "\n", name))
          result = { status = "error", error = "tool '" .. name .. "' is denied" }
        elseif perm == "ask" then
          local prompt = name
          if name == "bash" then
            prompt = "bash: " .. (params.command and params.command:sub(1, 80) or "?")
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
          local label = name
          if name == "skill" and params.name then
            label = "using skill: " .. params.name
          elseif name == "compact" then
            label = "using tool: compact"
          else
            label = "using tool: " .. name
          end
          io.write(string.format(c.green("\n[%s...]") .. "\n", label))
          local tokens
          result, tokens = self.tools.execute(self.cwd, name, params)
          if tokens > 100 then
            io.write(result.output and result.output:sub(1, 500) or tostring(result.error))
            io.write("\n")
          end
        end

        messages[#messages + 1] = {
          role = "tool",
          tool_call_id = tc.id,
          content = json.encode(result),
        }

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
    elseif response.finish_reason == "stop" then
      io.write("\n")
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

  local new_messages = {}
  for _, m in ipairs(messages) do
    new_messages[#new_messages + 1] = m
  end
  session.messages = new_messages
  session.steps = step
  session.total_tokens = total_tokens
  Store.save_session(self.config.sessions_dir, session.id, session)
end

return Agent
