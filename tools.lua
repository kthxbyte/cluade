local json = require("vendor.json")

local CHROME_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36"

local Tools = {}

local function _parse_frontmatter(content)
  local fm = {}
  local body = content
  if content:match("^%-%-%-") then
    local s, e = content:find("\n%-%-%-\n")
    if s then
      local fm_str = content:sub(5, s - 1)
      body = content:sub(e + 1)
      for line in fm_str:gmatch("[^\n]+") do
        local key, val = line:match("^(%S+):%s*(.+)$")
        if key then
          val = val:gsub('^["\']', ""):gsub('["\']$', "")
          if val == "true" then val = true
          elseif val == "false" then val = false end
          fm[key] = val
        end
      end
    end
  end
  return fm, body
end

local function _scan_skills()
  local home = os.getenv("HOME") or os.getenv("USERPROFILE") or "/tmp"
  local dirs = { home .. "/.cluade/skills", "./.cluade/skills" }
  local skills = {}
  for _, dir in ipairs(dirs) do
    local f = io.popen('ls -1 "' .. dir .. '" 2>/dev/null')
    if f then
      for entry in f:lines() do
        local skill_dir = dir .. "/" .. entry
        local md_path = skill_dir .. "/SKILL.md"
        local md_file = io.open(md_path, "r")
        if md_file then
          local content = md_file:read("*a")
          md_file:close()
          local fm = _parse_frontmatter(content)
          if fm["disable-model-invocation"] ~= true then
            local name = fm["name"] or entry
            local desc = fm["description"] or "(no description)"
            if not skills[name] then
              skills[name] = { name = name, path = md_path, description = desc }
            end
          end
        end
      end
      f:close()
    end
  end
  local list = {}
  for _, s in pairs(skills) do list[#list + 1] = s end
  table.sort(list, function(a, b) return a.name < b.name end)
  return list
end

Tools._scan_skills = _scan_skills

local DEFAULT_PERMISSIONS = {
  read       = "allow",
  write      = "ask",
  edit       = "allow",
  bash       = "ask",
  glob       = "allow",
  grep       = "allow",
  web_search = "allow",
  web_fetch  = "allow",
  remote_bash = "ask",
  compact    = "allow",
  skill      = "allow",
}

local DEFS = {}

DEFS.read = {
  type = "function",
  ["function"] = {
    name = "read",
    description = "Read a file from the local filesystem. Returns the content with line numbers.",
    parameters = {
      type = "object",
      properties = {
        filePath = { type = "string", description = "Absolute path to the file" },
      },
      required = { "filePath" },
    },
  },
}

DEFS.write = {
  type = "function",
  ["function"] = {
    name = "write",
    description = "Write content to a file. Creates or overwrites the file.",
    parameters = {
      type = "object",
      properties = {
        filePath = { type = "string", description = "Absolute path to the file" },
        content  = { type = "string", description = "Content to write" },
      },
      required = { "filePath", "content" },
    },
  },
}

DEFS.edit = {
  type = "function",
  ["function"] = {
    name = "edit",
    description = "Perform exact string replacement in a file. Fails if old_string is not found or matches multiple locations.",
    parameters = {
      type = "object",
      properties = {
        filePath  = { type = "string", description = "Absolute path to the file" },
        oldString = { type = "string", description = "Text to replace (must match exactly)" },
        newString = { type = "string", description = "Replacement text" },
        replaceAll = { type = "boolean", description = "Replace all occurrences (default false)" },
      },
      required = { "filePath", "oldString", "newString" },
    },
  },
}

DEFS.bash = {
  type = "function",
  ["function"] = {
    name = "bash",
    description = "Execute a shell command. The system is a Linux/OpenWRT system using busybox ash. Use ash-compatible syntax.",
    parameters = {
      type = "object",
      properties = {
        command = { type = "string", description = "Shell command to execute" },
        workdir = { type = "string", description = "Working directory for the command" },
      },
      required = { "command" },
    },
  },
}

DEFS.glob = {
  type = "function",
  ["function"] = {
    name = "glob",
    description = "Find files matching a glob pattern. Use ** for recursive matching.",
    parameters = {
      type = "object",
      properties = {
        pattern = { type = "string", description = "Glob pattern (e.g. src/**/*.lua)" },
      },
      required = { "pattern" },
    },
  },
}

DEFS.grep = {
  type = "function",
  ["function"] = {
    name = "grep",
    description = "Search for a pattern in files. Returns matching files with line numbers.",
    parameters = {
      type = "object",
      properties = {
        pattern = { type = "string", description = "Regex pattern to search for" },
        path    = { type = "string", description = "Directory to search in (default: cwd)" },
        include = { type = "string", description = "File pattern filter (e.g. *.lua)" },
      },
      required = { "pattern" },
    },
  },
}

DEFS.web_search = {
  type = "function",
  ["function"] = {
    name = "web_search",
    description = "Search the web using DuckDuckGo HTML and return results.",
    parameters = {
      type = "object",
      properties = {
        query = { type = "string", description = "Search query" },
      },
      required = { "query" },
    },
  },
}

DEFS.web_fetch = {
  type = "function",
  ["function"] = {
    name = "web_fetch",
    description = "Fetch content from a URL and return as text.",
    parameters = {
      type = "object",
      properties = {
        url = { type = "string", description = "URL to fetch" },
      },
      required = { "url" },
    },
  },
}

DEFS.remote_bash = {
  type = "function",
  ["function"] = {
    name = "remote_bash",
    description = "Execute a shell command on a remote host via SSH (uses SSH keys, not passwords).",
    parameters = {
      type = "object",
      properties = {
        host     = { type = "string", description = "Remote hostname or IP" },
        command  = { type = "string", description = "Shell command to run on the remote host" },
        username = { type = "string", description = "SSH username (default: root)" },
        port     = { type = "integer", description = "SSH port (default: 22)" },
      },
      required = { "host", "command" },
    },
  },
}

DEFS.compact = {
  type = "function",
  ["function"] = {
    name = "compact",
    description = "Frees context by summarizing prior conversation. Call after completing a significant task (feature done, bug fixed, commit >100 lines). Provide a concise summary of what was done, decisions made, and what remains.",
    parameters = {
      type = "object",
      properties = {
        summary = { type = "string", description = "Paragraph summarizing progress, key decisions, files changed, and next steps" },
      },
      required = { "summary" },
    },
  },
}

DEFS.skill = {
  type = "function",
  ["function"] = {
    name = "skill",
    description = "Load a skill's full instructions from a SKILL.md file. Use when a skill name matches the current task.",
    parameters = {
      type = "object",
      properties = {
        name = { type = "string", description = "Name of the skill to load (e.g., brainstorming)" },
      },
      required = { "name" },
    },
  },
}

-- === executors ===

local function _read_file(path)
  local f, err = io.open(path, "r")
  if not f then return nil, err end
  local content = f:read("*a")
  f:close()
  return content
end

local function _write_file(path, content)
  local dir = path:match("^(.*)/")
  if dir then os.execute('mkdir -p "' .. dir .. '" 2>/dev/null') end
  local f, err = io.open(path, "w")
  if not f then return nil, err end
  f:write(content)
  f:close()
  return true
end

local function _shell_escape(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function _run(cmd)
  local f = io.popen(cmd .. " 2>&1")
  if not f then return nil, "failed to execute" end
  local output = f:read("*a")
  local ok = { f:close() }
  return output, ok[3]  -- exit code
end

local function _token_estimate(text)
  return math.floor(#text / 3.5)
end

function Tools.execute_read(cwd, params)
  local path = params.filePath
  if not path:match("^/") then path = cwd .. "/" .. path end
  local content, err = _read_file(path)
  if not content then
    return ({ status = "error", error = tostring(err) }), _token_estimate(tostring(err))
  end
  local lines = {}
  for line in content:gmatch("[^\n]*\n?") do
    if #line > 0 then
      lines[#lines + 1] = #lines + 1 .. ": " .. line:gsub("\n$", "")
    end
  end
  local result = table.concat(lines, "\n")
  return ({ status = "ok", output = result }), _token_estimate(result)
end

function Tools.execute_write(cwd, params)
  if not params.filePath then
    return ({ status = "error", error = "missing required param: filePath" }), 10
  end
  if not params.content then
    return ({ status = "error", error = "missing required param: content" }), 10
  end
  local path = params.filePath
  if not path:match("^/") then path = cwd .. "/" .. path end
  local ok, err = _write_file(path, params.content)
  if not ok then
    return ({ status = "error", error = err }), _token_estimate(err)
  end
  local result = "wrote " .. path
  return ({ status = "ok", output = result }), _token_estimate(result)
end

function Tools.execute_edit(cwd, params)
  local path = params.filePath
  if not path:match("^/") then path = cwd .. "/" .. path end
  local content, err = _read_file(path)
  if not content then
    return ({ status = "error", error = err }), _token_estimate(err)
  end
  local old_str = params.oldString
  local new_str = params.newString
  local count = 0
  local start, finish = content:find(old_str, 1, true)
  if not start then
    return ({ status = "error", error = "oldString not found in content" }), _token_estimate("oldString not found")
  end
  if params.replaceAll then
    local n = 0
    content, n = content:gsub(old_str:gsub("([%-%^%$%(%)%%%.%[%]%*%+%?])", "%%%1"), new_str)
    count = n
  else
    local pos = content:find(old_str, start + #old_str, true)
    if pos then
      return ({ status = "error", error = "Found multiple matches for oldString" }), _token_estimate("multiple matches")
    end
    content = content:sub(1, start - 1) .. new_str .. content:sub(finish + 1)
    count = 1
  end
  _write_file(path, content)
  local result = "replaced " .. count .. " occurrence(s) in " .. path
  return ({ status = "ok", output = result }), _token_estimate(result)
end

function Tools.execute_bash(cwd, params)
  if not params.command then
    return ({ status = "error", error = "missing required param: command" }), 10
  end
  local command = params.command
  local workdir = params.workdir or cwd
  local cmd = "cd " .. _shell_escape(workdir) .. " && " .. command
  local output, exit_code = _run(cmd)
  local result = output
  if exit_code and exit_code ~= 0 then
    result = result .. "\n[exit code: " .. exit_code .. "]"
  end
  return ({ status = "ok", output = result }), _token_estimate(result)
end

function Tools.execute_glob(cwd, params)
  local pattern = params.pattern
  local recursive = pattern:find("%*%*") ~= nil
  if not pattern:match("^/") then pattern = cwd .. "/" .. pattern end
  local cmd
  if recursive then
    cmd = 'find "' .. pattern:match("^(.*)%*.*$") .. '" -path "' .. pattern .. '" 2>/dev/null | head -100'
  else
    cmd = 'ls -d ' .. pattern .. ' 2>/dev/null | head -100'
  end
  local output = _run(cmd)
  local result = (output and #output > 0) and output or "(no matches)"
  return ({ status = "ok", output = result }), _token_estimate(result)
end

function Tools.execute_grep(cwd, params)
  local pattern = params.pattern
  local search_path = params.path or cwd
  if not search_path:match("^/") then search_path = cwd .. "/" .. search_path end
  local include = params.include and ('--include="' .. params.include .. '"') or ""
  local cmd = 'grep -rn ' .. include .. ' ' .. _shell_escape(pattern) .. ' ' .. _shell_escape(search_path) .. ' 2>/dev/null | head -100'
  local output = _run(cmd)
  local result = (output and #output > 0) and output or "(no matches)"
  return ({ status = "ok", output = result }), _token_estimate(result)
end

function Tools.execute_web_search(cwd, params)
  local query = params.query:gsub("%s+", "+")
  local url = "https://html.duckduckgo.com/html/?q=" .. query
  local http = require("socket.http")
  local https = require("ssl.https")
  local ltn12 = require("ltn12")
  local resp = {}
  local ok, code = https.request({
    url = url,
    sink = ltn12.sink.table(resp),
    timeout = 15,
    protocol = "tlsv1_2",
    headers = { ["User-Agent"] = CHROME_UA },
  })
  if not ok then
    return ({ status = "error", error = "search failed: " .. tostring(code) }), _token_estimate("search failed")
  end
  local html = table.concat(resp)
  local results = {}
  for title, snippet, link in html:gmatch('result__a[^>]*>([^<]+).-result__snippet">([^<]+).-href="([^"]+)"') do
    results[#results + 1] = title .. "\n  " .. snippet:gsub("<.->", "") .. "\n  " .. link .. "\n"
  end
  if #results == 0 then
    return ({ status = "ok", output = "(no results)" }), _token_estimate("(no results)")
  end
  local out = table.concat(results, "\n")
  return ({ status = "ok", output = out }), _token_estimate(out)
end

function Tools.execute_web_fetch(cwd, params)
  local url = params.url
  local http = require("socket.http")
  local https = require("ssl.https")
  local ltn12 = require("ltn12")
  local resp = {}
  local is_tls = url:sub(1, 8) == "https://"
  local ok, code
  if is_tls then
    ok, code = https.request({
      url = url,
      sink = ltn12.sink.table(resp),
      timeout = 15,
      protocol = "tlsv1_2",
      headers = { ["User-Agent"] = CHROME_UA },
    })
  else
    ok, code = http.request({
      url = url,
      sink = ltn12.sink.table(resp),
      timeout = 15,
      headers = { ["User-Agent"] = CHROME_UA },
    })
  end
  if not ok then
    return ({ status = "error", error = "fetch failed: " .. tostring(code) }), _token_estimate("fetch failed")
  end
  local content = table.concat(resp)
  local max_len = 32000
  if #content > max_len then
    content = content:sub(1, max_len) .. "\n[... truncated at " .. max_len .. " bytes]"
  end
  return ({ status = "ok", output = content }), _token_estimate(content)
end

function Tools.execute_remote_bash(cwd, params)
  local host = params.host
  local command = params.command
  local username = params.username or "root"
  local port = params.port or "22"

  local cmd = "ssh -y -p " .. port .. " " .. username .. "@" .. host .. " " .. _shell_escape(command)
  local output, exit_code = _run(cmd)
  local result = output or ""
  if exit_code and exit_code ~= 0 then
    result = result .. "\n[exit code: " .. exit_code .. "]"
  end
  return ({ status = "ok", output = result }), _token_estimate(result)
end

function Tools.execute_compact(cwd, params)
  return ({ status = "compacted", summary = params.summary }), _token_estimate(params.summary)
end

function Tools.execute_skill(cwd, params)
  local skills = _scan_skills()
  for _, s in ipairs(skills) do
    if s.name == params.name then
      local f = io.open(s.path, "r")
      if f then
        local content = f:read("*a")
        f:close()
        local _, body = _parse_frontmatter(content)
        return ({ status = "ok", output = body }), _token_estimate(body)
      end
    end
  end
  local available = {}
  for _, s in ipairs(skills) do available[#available + 1] = s.name end
  local msg = "skill '" .. params.name .. "' not found. Available: " .. table.concat(available, ", ")
  return ({ status = "error", error = msg }), _token_estimate(msg)
end

-- === registry ===

local EXECUTORS = {
  read        = Tools.execute_read,
  write       = Tools.execute_write,
  edit        = Tools.execute_edit,
  bash        = Tools.execute_bash,
  glob        = Tools.execute_glob,
  grep        = Tools.execute_grep,
  web_search  = Tools.execute_web_search,
  web_fetch   = Tools.execute_web_fetch,
  remote_bash = Tools.execute_remote_bash,
  compact     = Tools.execute_compact,
  skill       = Tools.execute_skill,
}

function Tools.get_definitions(names)
  local defs = {}
  for _, name in ipairs(names) do
    if DEFS[name] then
      defs[#defs + 1] = DEFS[name]
    end
  end
  return defs
end

function Tools.get_permission(name)
  return DEFAULT_PERMISSIONS[name] or "ask"
end

function Tools.set_permissions(overrides)
  for name, level in pairs(overrides) do
    DEFAULT_PERMISSIONS[name] = level
  end
end

function Tools.execute(cwd, name, params)
  local executor = EXECUTORS[name]
  if not executor then
    return ({ status = "error", error = "unknown tool: " .. name }), 0
  end
  local ok, result, tokens = pcall(executor, cwd, params)
  if not ok then
    return ({ status = "error", error = tostring(result) }), 0
  end
  return result, tokens or 0
end

return Tools
