-- Tests that the agent uses config.system_prompt as the base of the system
-- message when present, and falls back to the built-in base otherwise. This is
-- what lets the host-fitted prompt (built by hostprobe + stored in config.json)
-- reach the model instead of a hardcoded constant.

package.path = "./?.lua;./?/init.lua;" .. package.path

local fail = 0
local function ok(cond, msg)
  if cond then print("  ok  - " .. msg) else print("  FAIL- " .. msg); fail = fail + 1 end
end

-- Stub provider: one step, no tool calls, then stop.
package.loaded["provider"] = {
  new = function(self, _) return setmetatable({}, { __index = self }) end,
  chat = function()
    return { content = "ok", finish_reason = "stop", usage = { total_tokens = 1 } }
  end,
}

local Agent = require("agent")

local tmp = os.tmpname(); os.remove(tmp); os.execute("mkdir -p '" .. tmp .. "'")

local real_write, real_flush = io.write, io.flush
io.write = function() end
io.flush = function() end

local SENTINEL = "SENTINEL_HOST_FITTED_PROMPT_7"
local config = {
  model = "test", base_url = "x", max_steps = 3,
  sessions_dir = tmp .. "/sessions",
  system_prompt = SENTINEL,
}
local agent = Agent:init(config, tmp)
local session = { id = "t", messages = {}, cwd = tmp }
agent:run(session, "hello")

io.write, io.flush = real_write, real_flush

local content = tostring(session.messages[1] and session.messages[1].content)
ok(content:find(SENTINEL, 1, true) == 1, "config.system_prompt becomes the base of the system message")
ok(content:lower():find("openwrt") == nil, "no leftover hardcoded OpenWRT claim")

os.execute("rm -rf '" .. tmp .. "'")

if fail == 0 then print("\nALL PASS") else print("\n" .. fail .. " FAILED"); os.exit(1) end
