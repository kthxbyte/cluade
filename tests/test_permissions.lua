-- Tests for config-driven tool permissions.
-- Agent:init should apply config.permissions as overrides on top of the
-- tool defaults in tools.lua, honoring only the tools the config names.

package.path = "./?.lua;./?/init.lua;" .. package.path
local Agent = require("agent")
local tools = require("tools")

local fail = 0
local function ok(cond, msg)
  if cond then print("  ok  - " .. msg) else print("  FAIL- " .. msg); fail = fail + 1 end
end

local function snapshot(names)
  local s = {}
  for _, n in ipairs(names) do s[n] = tools.get_permission(n) end
  return s
end
local function restore(s) tools.set_permissions(s) end

-- 1. A config permissions block is honored.
do
  local orig = snapshot({ "bash" })
  Agent:init({ permissions = { bash = "deny" } }, "/tmp")
  ok(tools.get_permission("bash") == "deny", "config permission is applied by Agent:init")
  restore(orig)
end

-- 2. Absent permissions leaves the tool defaults untouched.
do
  local orig = snapshot({ "bash" })
  Agent:init({}, "/tmp")
  ok(tools.get_permission("bash") == orig.bash, "no permissions key -> tool defaults unchanged")
  restore(orig)
end

-- 3. Only the named tools change; others keep their defaults.
do
  local orig = snapshot({ "bash", "write" })
  Agent:init({ permissions = { bash = "ask" } }, "/tmp")
  ok(tools.get_permission("bash") == "ask", "named tool overridden")
  ok(tools.get_permission("write") == orig.write, "unnamed tool keeps its default")
  restore(orig)
end

if fail == 0 then print("\nALL PASS") else print("\n" .. fail .. " FAILED"); os.exit(1) end
