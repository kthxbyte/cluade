-- Tests that compaction preserves the per-turn augmentations (./CLAUDE.md
-- instructions + skills list) in the rebuilt system message. When compact
-- fires mid-run it replaces the system message with SYSTEM_PROMPT + summary;
-- without re-augmenting, the steps remaining in that same run would no longer
-- see the project's instructions. The files on disk are never lost, but the
-- live context for the rest of the run was -- this closes that gap.

package.path = "./?.lua;./?/init.lua;" .. package.path

local fail = 0
local function ok(cond, msg)
  if cond then print("  ok  - " .. msg) else print("  FAIL- " .. msg); fail = fail + 1 end
end

local json = require("vendor.json")

-- Throwaway working dir with a CLAUDE.md the agent ingests.
local tmp = os.tmpname()
os.remove(tmp)
os.execute("mkdir -p '" .. tmp .. "'")
local MARKER = "REMEMBER_THE_MARKER_42"
do
  local f = io.open(tmp .. "/CLAUDE.md", "w")
  f:write("Project rule: " .. MARKER .. "\n")
  f:close()
end

-- Stateful stub: step 1 emits a compact tool call; step 2 stops. This drives a
-- compaction mid-run, then a further step so the post-compact context matters.
local step = 0
package.loaded["provider"] = {
  new = function(self, _) return setmetatable({}, { __index = self }) end,
  chat = function()
    step = step + 1
    if step == 1 then
      return {
        content = "", finish_reason = "tool_calls",
        usage = { total_tokens = 1 },
        tool_calls = { {
          id = "c1", type = "function",
          ["function"] = { name = "compact", arguments = json.encode({ summary = "did stuff" }) },
        } },
      }
    end
    return { content = "ok", finish_reason = "stop", usage = { total_tokens = 1 } }
  end,
}

local Agent = require("agent")

local config = {
  model = "test", base_url = "x", max_steps = 5,
  sessions_dir = tmp .. "/sessions",
}
local agent = Agent:init(config, tmp)

local real_write, real_flush = io.write, io.flush
io.write = function() end
io.flush = function() end

local session = { id = "t", messages = {}, cwd = tmp }
agent:run(session, "go")

io.write, io.flush = real_write, real_flush

local sys = session.messages[1]
local content = tostring(sys and sys.content)
local count = 0
for _ in content:gmatch(MARKER) do count = count + 1 end

ok(content:find("did stuff", 1, true) ~= nil, "compacted system message carries the summary")
ok(count == 1, "CLAUDE.md instructions survive compaction exactly once (got " .. count .. ")")

os.execute("rm -rf '" .. tmp .. "'")

if fail == 0 then print("\nALL PASS") else print("\n" .. fail .. " FAILED"); os.exit(1) end
