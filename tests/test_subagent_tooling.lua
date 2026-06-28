-- Tests the two pure pieces of the subagent feature:
--  * Agent._tool_names(config): a subagent never gets the `subagent` tool
--    (recursion is capped at 1 by construction, not a counter); plan mode is
--    read-only by toolset; build keeps the full set minus subagent.
--  * Tools._subagent_cmd: builds the child invocation, shell-escaping the prompt
--    and adding --plan only for plan mode.

package.path = "./?.lua;./?/init.lua;" .. package.path
local Agent = require("agent")
local Tools = require("tools")

local fail = 0
local function ok(cond, msg)
  if cond then print("  ok  - " .. msg) else print("  FAIL- " .. msg); fail = fail + 1 end
end
local function has(list, want)
  for _, v in ipairs(list) do if v == want then return true end end
  return false
end

-- Tool selection.
do
  local normal = Agent._tool_names({})
  ok(has(normal, "subagent"), "normal run offers the subagent tool")
  ok(has(normal, "write") and has(normal, "bash"), "normal run has write/bash")

  local build = Agent._tool_names({ subagent = true })
  ok(not has(build, "subagent"), "subagent (build) does NOT get subagent tool (no recursion)")
  ok(has(build, "write") and has(build, "edit") and has(build, "bash"), "build subagent keeps file/shell tools")

  local plan = Agent._tool_names({ subagent = true, plan = true })
  ok(not has(plan, "subagent"), "plan subagent has no subagent tool")
  ok(not has(plan, "write") and not has(plan, "edit") and not has(plan, "bash"),
    "plan subagent is read-only (no write/edit/bash)")
  ok(has(plan, "read") and has(plan, "grep") and has(plan, "glob"), "plan subagent keeps read/grep/glob")
end

-- Child command construction.
do
  local cmd = Tools._subagent_cmd("lua5.1 /opt/cluade.lua", "audit the repo", "build")
  ok(cmd:find("--subagent", 1, true) ~= nil, "build cmd carries --subagent")
  ok(cmd:find("--plan", 1, true) == nil, "build cmd has no --plan")
  ok(cmd:find("audit the repo", 1, true) ~= nil, "build cmd includes the prompt")

  local pcmd = Tools._subagent_cmd("lua5.1 /opt/cluade.lua", "find the bug", "plan")
  ok(pcmd:find("--plan", 1, true) ~= nil, "plan cmd carries --plan")

  -- A prompt with a single quote must be escaped, not left to break the shell.
  local q = Tools._subagent_cmd("cluade", "it's broken", "build")
  ok(q:find("'\\''", 1, true) ~= nil, "single quote in prompt is shell-escaped")
end

if fail == 0 then print("\nALL PASS") else print("\n" .. fail .. " FAILED"); os.exit(1) end
