-- The ask tool must be in the interactive toolset but excluded from the
-- unattended --subagent and --plan toolsets (no human to answer), and its tool
-- label must not dump the raw argument JSON.

package.path = "./?.lua;./?/init.lua;" .. package.path
local Agent = require("agent")

local fail = 0
local function ok(cond, msg)
  if cond then print("  ok  - " .. msg) else print("  FAIL- " .. msg); fail = fail + 1 end
end

local function has(t, name)
  for _, n in ipairs(t) do if n == name then return true end end
  return false
end

ok(has(Agent._tool_names({}), "ask"), "ask is in the normal toolset")
ok(not has(Agent._tool_names({ subagent = true }), "ask"), "ask excluded from --subagent toolset")
ok(not has(Agent._tool_names({ subagent = true, plan = true }), "ask"), "ask excluded from --plan toolset")

local label = Agent._tool_label("ask", { question = "Pick one", options = { { label = "A" } } })
ok(label:find("ask", 1, true) ~= nil and label:find("question", 1, true) == nil,
  "ask label names the tool without dumping its args")

if fail == 0 then print("\nALL PASS") else print("\n" .. fail .. " FAILED"); os.exit(1) end
