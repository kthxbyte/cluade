-- Lazy persistence: a session file is written only once it has a user message.
-- A REPL launched and exited with no input persists nothing; a one-shot run
-- persists exactly one session (carrying the user message). Offline base_url so
-- the single provider call fails instantly (connection refused), no network.

package.path = "./?.lua;./?/init.lua;" .. package.path
local Store = require("store")

local fail = 0
local function ok(cond, msg)
  if cond then print("  ok  - " .. msg) else print("  FAIL- " .. msg); fail = fail + 1 end
end

local OFFLINE = "--base-url http://127.0.0.1:1/v1 -m x"
local function fresh_home()
  local h = os.tmpname(); os.remove(h); os.execute("mkdir -p '" .. h .. "'"); return h
end
local function count_sessions(home)
  local f = io.popen("ls '" .. home .. "'/.cluade/sessions/*.json 2>/dev/null | wc -l")
  local n = tonumber((f:read("*a") or ""):match("%d+")); f:close(); return n or 0
end

-- (a) REPL with immediate EOF (no input) -> nothing persisted
local ha = fresh_home()
os.execute("echo -n '' | HOME='" .. ha .. "' lua5.1 cluade.lua " .. OFFLINE .. " >/dev/null 2>&1")
ok(count_sessions(ha) == 0, "empty REPL persists no session (got " .. count_sessions(ha) .. ")")
os.execute("rm -rf '" .. ha .. "'")

-- (b) one-shot with a prompt -> exactly one session, and it lists
local hb = fresh_home()
os.execute("HOME='" .. hb .. "' lua5.1 cluade.lua " .. OFFLINE .. " 'hello there' >/dev/null 2>&1")
ok(count_sessions(hb) == 1, "one-shot persists exactly one session (got " .. count_sessions(hb) .. ")")
ok(#Store.list_sessions(hb .. "/.cluade/sessions") == 1, "the persisted session lists")
-- --list-sessions CLI output shows the title (snippet of the first message)
local lf = io.popen("HOME='" .. hb .. "' lua5.1 cluade.lua --list-sessions 2>/dev/null")
local lout = lf:read("*a") or ""; lf:close()
ok(lout:find("hello there", 1, true) ~= nil, "--list-sessions CLI output shows the title")
os.execute("rm -rf '" .. hb .. "'")

if fail == 0 then print("\nALL PASS") else print("\n" .. fail .. " FAILED"); os.exit(1) end
