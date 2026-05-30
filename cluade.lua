#!/usr/bin/env lua

-- cluade -- a minimal coding agent for OpenWRT / constrained Linux

local script_dir = debug.getinfo(1, "S").source:match("@(.*/)") or "."
if script_dir:sub(1, 1) ~= "/" then
  local f = io.popen("pwd")
  script_dir = f:read("*l") .. "/" .. script_dir
  f:close()
end

package.path = script_dir .. "/?.lua;" .. script_dir .. "/?/init.lua;" .. package.path

local json = require("vendor.json")
local Store = require("store")
local Agent = require("agent")
local c = require("colors")
local lineedit = require("lineedit")

local function handle_command(line, config, sessions_dir, session)
  if line == "/help" then
    print(c.dim("Commands: /help /exit /sessions /resume <id> /new /model <name>"))
    return "continue"
  elseif line == "/exit" then
    print(c.cyan("Exiting..."))
    return "exit"
  elseif line == "/sessions" then
    local sessions = Store.list_sessions(sessions_dir)
    if #sessions == 0 then
      print(c.dim("No sessions found."))
    else
      for _, s in ipairs(sessions) do
        print(string.format("%s  %s  %d msgs  %s", s.id, s.created, s.messages, s.cwd))
      end
    end
    return "continue"
  elseif line:match("^/resume%s+(.+)$") then
    local id = line:match("^/resume%s+(.+)$")
    local ok, loaded = pcall(function() return Store.load_session(sessions_dir, id) end)
    if not ok or not loaded then
      print(c.red("Session '" .. id .. "' not found."))
    else
      session.id = loaded.id
      session.messages = loaded.messages or {}
      session.cwd = loaded.cwd or session.cwd
      print(c.cyan("Resumed session " .. id))
    end
    return "continue"
  elseif line == "/new" then
    local new_s = Store.new_session_data(session.cwd or ".")
    Store.save_session(sessions_dir, new_s.id, new_s)
    session.id = new_s.id
    session.messages = {}
    session.cwd = new_s.cwd
    print(c.cyan("New session: " .. new_s.id))
    return "continue"
  elseif line:match("^/model%s+(.+)$") then
    local model = line:match("^/model%s+(.+)$")
    config.model = model
    print(c.cyan("Model set to: " .. model))
    return "continue"
  end
  return nil
end

local function print_help()
  print([[
cluade — minimal coding agent for constrained Linux environments

Usage: cluade [options] [prompt]

Options:
  -m, --model MODEL       LLM model name (default: gpt-4o)
  --base-url URL           API base URL (default: https://api.openai.com/v1)
  --api-key KEY            API key (or set OPENAI_API_KEY env var)
  -c, --continue           Resume the most recent session
  -r, --resume ID          Resume a specific session by ID
  --list-sessions          List saved sessions
  -y, --yes                Auto-approve all permission prompts
  --init                   Initialize a config file
  -h, --help               Show this help

Examples:
  cluade "write a hello world script"
  cluade -c
  cluade --base-url http://localhost:11434/v1 -m llama3 "explain this code"
  cluade --init
]])
end

local function parse_args(argv)
  local args = { cwd = os.getenv("PWD") or "." }
  local i = 1
  while i <= #argv do
    local a = argv[i]
    if a == "-h" or a == "--help" then
      print_help()
      os.exit(0)
    elseif a == "-m" or a == "--model" then
      i = i + 1; args.model = argv[i]
    elseif a == "--base-url" then
      i = i + 1; args.base_url = argv[i]
    elseif a == "--api-key" then
      i = i + 1; args.api_key = argv[i]
    elseif a == "-c" or a == "--continue" then
      args.continue_session = true
    elseif a == "-r" or a == "--resume" then
      i = i + 1; args.resume = argv[i]
    elseif a == "--list-sessions" then
      args.list_sessions = true
    elseif a == "-y" or a == "--yes" then
      args.yes = true
    elseif a == "--init" then
      args.init = true
    elseif a:sub(1, 1) ~= "-" then
      args.prompt = (args.prompt and args.prompt .. " " or "") .. a
    end
    i = i + 1
  end
  return args
end

local function deep_copy(t)
  if type(t) ~= "table" then return t end
  local copy = {}
  for k, v in pairs(t) do copy[k] = deep_copy(v) end
  return copy
end

-- === main ===

local args = parse_args(arg)

local home = os.getenv("HOME") or os.getenv("USERPROFILE") or "/tmp"
local config = Store.load_config(args.cwd)

if args.model then config.model = args.model end
if args.base_url then config.base_url = args.base_url end
if args.api_key then config.api_key = args.api_key end

if args.init then
  local config_dir = os.getenv("HOME") .. "/.cluade"
  os.execute('mkdir -p "' .. config_dir .. '" 2>/dev/null')
  local f = io.open(config_dir .. "/config.json", "w")
  f:write(json.encode({
    base_url = config.base_url,
    model = config.model,
    api_key = config.api_key,
    max_steps = 20,
    permissions = { bash = "ask", remote_bash = "ask", write = "ask" },
  }) .. "\n")
  f:close()
  print("written " .. config_dir .. "/config.json")
  os.exit(0)
end

local sessions_dir = home .. "/.cluade/sessions"
config.sessions_dir = sessions_dir

if args.list_sessions then
  local sessions = Store.list_sessions(sessions_dir)
  if #sessions == 0 then
    print("No sessions found.")
  else
    for _, s in ipairs(sessions) do
      print(string.format("%s  %s  %d msgs  %s", s.id, s.created, s.messages, s.cwd))
    end
  end
  os.exit(0)
end

local session
if args.continue_session then
  local last_id = Store.get_last_session_id(home)
  if not last_id then
    print("No previous session to continue.")
    os.exit(1)
  end
  local ok, err = pcall(function() session = Store.load_session(sessions_dir, last_id) end)
  if not ok then
    print("Failed to load session " .. last_id .. ": " .. tostring(err))
    os.exit(1)
  end
  print("continuing session " .. last_id)
elseif args.resume then
  local id = args.resume:gsub("%.json$", "")
  local ok, err = pcall(function() session = Store.load_session(sessions_dir, id) end)
  if not ok or not session then
    print("Failed to load session " .. id .. ": " .. tostring(err or session))
    os.exit(1)
  end
  print("resumed session " .. args.resume)
else
  session = Store.new_session_data(args.cwd)
  Store.save_session(sessions_dir, session.id, session)
end

Store.set_last_session_id(home, session.id)

local agent = Agent:init(config, args.cwd)

if args.yes then
  local tools = require("tools")
  tools.set_permissions({ bash = "allow", remote_bash = "allow", write = "allow" })
end

if args.prompt then
  agent:run(session, args.prompt)
  local est_total = session.total_tokens or 0
  local context_limit = config.context_limit or 200000
  local pct = math.floor(est_total / context_limit * 100 * 10) / 10
  print(c.dim(string.format("-- %s - %d tokens - %.1f%% context",
    config.model or "?", est_total, pct)))
else
  print(c.cyan("cluade session " .. session.id .. " -- " .. (config.model or "?")))
  print(c.dim("Type /help for commands, Ctrl+D to exit"))

  local function restore_term()
    os.execute("stty icanon echo 2>/dev/null")
  end

  local interactive = lineedit.init()
  if not interactive then
    print(c.dim("stdin is not a terminal -- line editing disabled"))
  else
    os.execute("stty -icanon -echo 2>/dev/null")
  end

  local ok, err = pcall(function()
    while true do
      local line = lineedit.readline(c.cyan("> "))
      if not line then
        print()
        return
      end
      if #line > 0 then
        lineedit.add_history(line)
        if line:sub(1, 1) == "/" then
          local status = handle_command(line, config, sessions_dir, session)
          if status == "exit" then return end
        else
          local t0 = os.time()
          agent:run(session, line)
          local elapsed = os.time() - t0
          local est_total = session.total_tokens or 0
          local context_limit = config.context_limit or 200000
          local pct = math.floor(est_total / context_limit * 100 * 10) / 10
          print(c.dim(string.format("-- %s - %d tokens - %.1f%% context - %ds",
            config.model or "?", est_total, pct, elapsed)))
        end
      end
    end
  end)

  if interactive then
    restore_term()
  end
  if not ok and err then
    print(c.red("Error: " .. tostring(err)))
  end
end
