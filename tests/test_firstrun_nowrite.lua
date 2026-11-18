-- A non-interactive first run (--subagent / --quiet / no tty) must NOT create
-- ~/.cluade/config.json. The spec's anti-goal forbids writing files in those
-- modes; only an interactive first run (or --init) persists the generated prompt.
-- Integration test: spawn cluade in --subagent mode in a throwaway HOME with a
-- base_url that refuses instantly (offline, no network), and assert no config
-- file was written.

package.path = "./?.lua;./?/init.lua;" .. package.path

local fail = 0
local function ok(cond, msg)
  if cond then print("  ok  - " .. msg) else print("  FAIL- " .. msg); fail = fail + 1 end
end

local home = os.tmpname(); os.remove(home); os.execute("mkdir -p '" .. home .. "'")

-- --subagent is non-interactive (no human to ask); the bogus base_url makes the
-- single provider call fail at once, so the run exits without touching the net.
local cmd = "HOME='" .. home .. "' lua5.1 cluade.lua --subagent --no-session"
  .. " --base-url http://127.0.0.1:1/v1 -m x 'hi' >/dev/null 2>&1"
os.execute(cmd)

local f = io.open(home .. "/.cluade/config.json", "r")
if f then f:close() end
ok(f == nil, "non-interactive first run does not create ~/.cluade/config.json")

os.execute("rm -rf '" .. home .. "'")

if fail == 0 then print("\nALL PASS") else print("\n" .. fail .. " FAILED"); os.exit(1) end
