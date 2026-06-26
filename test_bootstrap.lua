-- Running cluade through a symlink (e.g. /usr/local/bin/cluade -> .../cluade.lua)
-- must still resolve its own modules. The bootstrap derives its module dir from
-- the script path, which for a symlink is the LINK's location unless resolved.
-- This reproduces the real failure: invoke via a symlink, from an unrelated cwd.

local fail = 0
local function ok(cond, msg)
  if cond then print("  ok  - " .. msg) else print("  FAIL- " .. msg); fail = fail + 1 end
end

local pwd = io.popen("pwd"):read("*l")
local real = pwd .. "/cluade.lua"
local link = os.tmpname(); os.remove(link)
os.execute("ln -s '" .. real .. "' '" .. link .. "'")

-- Run from / so the default "./?.lua" path can't accidentally satisfy the
-- modules; resolution must come from the (symlinked) script's real location.
local f = io.popen("cd / && lua5.1 '" .. link .. "' --help 2>&1")
local out = f:read("*a"); f:close()
os.remove(link)

ok(not out:match("module '.-' not found"), "modules resolve when run via a symlink")
ok(out:match("Usage:") or out:match("cluade %["), "--help reached and printed usage")

if fail == 0 then print("\nALL PASS") else print("\n" .. fail .. " FAILED"); os.exit(1) end
