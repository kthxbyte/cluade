-- Tests the agent side of session titling: the run loop applies a model
-- set_title (set-once), a first-message snippet backfills when the model never
-- titles, the titling nudge is gated, and set_title is in the normal toolset but
-- excluded from the subagent toolset.

package.path = "./?.lua;./?/init.lua;" .. package.path
local json = require("vendor.json")

local fail = 0
local function ok(cond, msg)
  if cond then print("  ok  - " .. msg) else print("  FAIL- " .. msg); fail = fail + 1 end
end

-- Configurable provider stub: each test sets `responses`, chat pops them.
local responses = {}
package.loaded["provider"] = {
  new = function(self, _) return setmetatable({}, { __index = self }) end,
  chat = function() return table.remove(responses, 1) end,
}
local Agent = require("agent")

local function set_title_call(title)
  return { content = "", finish_reason = "tool_calls", usage = { total_tokens = 1 },
    tool_calls = { { id = "c1", type = "function",
      ["function"] = { name = "set_title", arguments = json.encode({ title = title }) } } } }
end
local stop = { content = "ok", finish_reason = "stop", usage = { total_tokens = 1 } }

local tmp = os.tmpname(); os.remove(tmp); os.execute("mkdir -p '" .. tmp .. "'")
local function new_agent() return Agent:init({ model = "t", base_url = "x", max_steps = 5, sessions_dir = tmp .. "/s" }, tmp) end
local real_write, real_flush = io.write, io.flush
local function run(session, input) io.write = function() end; io.flush = function() end
  new_agent():run(session, input); io.write, io.flush = real_write, real_flush end

-- (a) model set_title wins
local sa = { id = "a", messages = {}, cwd = tmp }
responses = { set_title_call("Model Title"), stop }
run(sa, "hello")
ok(sa.title == "Model Title", "model set_title becomes the session title (got " .. tostring(sa.title) .. ")")

-- (b) set-once: an existing title is not overwritten
local sb = { id = "b", messages = {}, cwd = tmp, title = "Kept" }
responses = { set_title_call("New"), stop }
run(sb, "hello")
ok(sb.title == "Kept", "set-once: existing title not overwritten")

-- (c) snippet fallback when the model never titles
local sc = { id = "c", messages = {}, cwd = tmp }
responses = { stop }
run(sc, "do the thing")
ok(sc.title == "do the thing", "fallback titles from the first user message (got " .. tostring(sc.title) .. ")")

-- (d) nudge gating
local a = new_agent()
ok(a:_augmentations(true):find("set_title", 1, true) ~= nil, "nudge present when want_title")
ok(a:_augmentations(false):find("set_title", 1, true) == nil, "nudge absent when not want_title")

-- (e) toolset membership
local function has(t, n) for _, x in ipairs(t) do if x == n then return true end end return false end
ok(has(Agent._tool_names({}), "set_title"), "set_title in the normal toolset")
ok(not has(Agent._tool_names({ subagent = true }), "set_title"), "set_title excluded from the subagent toolset")

os.execute("rm -rf '" .. tmp .. "'")
if fail == 0 then print("\nALL PASS") else print("\n" .. fail .. " FAILED"); os.exit(1) end
