-- Tests that the system message is rebuilt fresh on every Agent:run, so the
-- ./CLAUDE.md instructions (and the skills list) are injected exactly once no
-- matter how many turns a session has run. Appending to the persisted system
-- message instead of rebuilding it duplicated the instructions on every turn
-- of an interactive or resumed session, silently bloating the context.

package.path = "./?.lua;./?/init.lua;" .. package.path

local fail = 0
local function ok(cond, msg)
  if cond then print("  ok  - " .. msg) else print("  FAIL- " .. msg); fail = fail + 1 end
end

-- A throwaway working dir with a CLAUDE.md the agent should ingest.
local tmp = os.tmpname()
os.remove(tmp)
os.execute("mkdir -p '" .. tmp .. "'")
local MARKER = "REMEMBER_THE_MARKER_42"
do
  local f = io.open(tmp .. "/CLAUDE.md", "w")
  f:write("Project rule: " .. MARKER .. "\n")
  f:close()
end

-- Stub the provider so a run ends after one step with no tool calls.
package.loaded["provider"] = {
  new = function(self, _) return setmetatable({}, { __index = self }) end,
  chat = function()
    return { content = "ok", finish_reason = "stop", usage = { total_tokens = 1 } }
  end,
}

local Agent = require("agent")

local config = {
  model = "test", base_url = "x", max_steps = 5,
  sessions_dir = tmp .. "/sessions",
}
local agent = Agent:init(config, tmp)

-- Silence the agent's terminal chatter during the run.
local real_write = io.write
io.write = function() end
io.flush = function() end

local session = { id = "t", messages = {}, cwd = tmp }
agent:run(session, "first")   -- turn 1
agent:run(session, "second")  -- turn 2

io.write = real_write

-- Count how many times the CLAUDE.md marker appears in the system message.
local sys = session.messages[1]
local count = 0
for _ in tostring(sys and sys.content):gmatch(MARKER) do count = count + 1 end

ok(sys ~= nil and sys.role == "system", "first message is the system prompt")
ok(count == 1, "CLAUDE.md instructions appear exactly once after two turns (got " .. count .. ")")

os.execute("rm -rf '" .. tmp .. "'")

if fail == 0 then print("\nALL PASS") else print("\n" .. fail .. " FAILED"); os.exit(1) end
