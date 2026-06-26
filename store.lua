local json = require("vendor.json")

local Store = {}

local function _mkdir(path)
  os.execute('mkdir -p "' .. path .. '" 2>/dev/null')
end

local function _read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

local function _write_file(path, content)
  _mkdir(path:match("^(.*)/"))
  local f = io.open(path, "w")
  if not f then return nil, "cannot write " .. path end
  f:write(content)
  f:close()
  return true
end

local function _merge_config(base, override)
  if not override then return base end
  for k, v in pairs(override) do
    if type(v) == "table" and type(base[k]) == "table" then
      _merge_config(base[k], v)
    else
      base[k] = v
    end
  end
  return base
end

function Store.load_config(project_dir)
  local home = os.getenv("HOME") or os.getenv("USERPROFILE") or "/tmp"
  local defaults = {
    base_url = "https://api.deepseek.com/v1",
    model = "deepseek-v4-pro",
    api_key = "",
    max_steps = 100,   -- safety backstop only; loop detection is the real guard
    max_tokens = 131072,
    request_timeout = 600,
    context_limit = 200000,
    compact_threshold = 0.85,
    permissions = { bash = "ask", remote_bash = "ask", write = "ask" },
  }

  local home_config_path = home .. "/.cluade/config.json"
  local home_raw = _read_file(home_config_path)
  if home_raw then
    local ok, parsed = pcall(json.decode, home_raw)
    if ok then _merge_config(defaults, parsed) end
  end

  local project_config_path = project_dir .. "/.cluade/config.json"
  local proj_raw = _read_file(project_config_path)
  if proj_raw then
    local ok, parsed = pcall(json.decode, proj_raw)
    if ok then _merge_config(defaults, parsed) end
  end

  local env_key = os.getenv("OPENAI_API_KEY") or os.getenv("ANTHROPIC_API_KEY")
  if env_key and #env_key > 0 then
    defaults.api_key = env_key
  end

  return defaults
end

function Store.load_session(sessions_dir, id)
  local path = sessions_dir .. "/" .. id .. ".json"
  local raw = _read_file(path)
  if not raw then return nil, "session not found: " .. id end
  local ok, parsed = pcall(json.decode, raw)
  if not ok then return nil, "corrupt session: " .. parsed end
  return parsed
end

function Store.save_session(sessions_dir, id, data)
  _mkdir(sessions_dir)
  local path = sessions_dir .. "/" .. id .. ".json"
  local body = json.encode(data)
  return _write_file(path, body)
end

function Store.list_sessions(sessions_dir)
  local cmd = 'ls -t "' .. sessions_dir .. '"/*.json 2>/dev/null'
  local f = io.popen(cmd)
  if not f then return {} end
  local sessions = {}
  local home = os.getenv("HOME") or os.getenv("USERPROFILE") or "/tmp"
  for line in f:lines() do
    local id = line:match("([^/]+)%.json$")
    if id and id ~= "last_session" then
      local raw = _read_file(line)
      if raw then
        local ok, parsed = pcall(json.decode, raw)
        if ok then
          sessions[#sessions + 1] = {
            id = id,
            created = parsed.created or "",
            messages = #(parsed.messages or {}),
            cwd = parsed.cwd or "",
          }
        end
      end
    end
  end
  f:close()
  return sessions
end

function Store.get_last_session_id(home_dir)
  local path = home_dir .. "/.cluade/last_session"
  local raw = _read_file(path)
  return raw and raw:match("^%s*(.-)%s*$")
end

function Store.set_last_session_id(home_dir, id)
  _mkdir(home_dir .. "/.cluade")
  _write_file(home_dir .. "/.cluade/last_session", id)
end

function Store.make_session_id()
  return os.date("%Y%m%d-%H%M%S") .. "-" .. tostring(math.random(1000, 9999))
end

function Store.new_session_data(cwd)
  local home = os.getenv("HOME") or os.getenv("USERPROFILE") or "/tmp"
  return {
    id = Store.make_session_id(),
    cwd = cwd,
    created = os.date("%Y-%m-%d %H:%M:%S"),
    messages = {},
  }
end

return Store
