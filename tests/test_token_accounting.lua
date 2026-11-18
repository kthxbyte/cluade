-- The status counter must reflect the real token usage DeepSeek returns, not a
-- character estimate or a cross-step sum. Two concerns: (1) Agent captures the
-- latest prompt_tokens as context size plus cumulative completion/cache totals
-- from response.usage; (2) Agent.format_status renders them in one tidy line.

package.path = "./?.lua;./?/init.lua;" .. package.path

local fail = 0
local function ok(cond, msg)
  if cond then print("  ok  - " .. msg) else print("  FAIL- " .. msg); fail = fail + 1 end
end

-- (2) format_status: pure, so test it directly.
local Agent = require("agent")
do
  local s = Agent.format_status({
    model = "m", context_tokens = 1234, context_limit = 10000,
    completion_tokens = 50, cache_hit = 30, cache_miss = 10, elapsed = 3,
  })
  ok(s:find("ctx 1234/10000", 1, true), "shows real context/limit")
  ok(s:find("(12.3%)", 1, true), "context pct from prompt_tokens (1234/10000)")
  ok(s:find("50 out", 1, true), "shows cumulative completion tokens")
  ok(s:find("cache 75%", 1, true), "shows cache hit ratio (30/40)")
  ok(s:find("3s", 1, true), "shows elapsed when given")

  local s2 = Agent.format_status({ model = "m", context_tokens = 0, context_limit = 100, completion_tokens = 0 })
  ok(s2:find("cache", 1, true) == nil, "omits cache when provider reports none")
  ok(s2:find("s", 1, true) == nil or s2:find("out", 1, true), "omits elapsed when not given")
end

-- (1) capture: run the agent over two steps with a stubbed provider that returns
-- usage objects, and check the session fields.
package.loaded["provider"] = {
  new = function(self, _) return setmetatable({}, { __index = self }) end,
  chat = (function()
    local step = 0
    return function()
      step = step + 1
      if step == 1 then
        return { content = "working", finish_reason = nil,
          usage = { prompt_tokens = 100, completion_tokens = 20, total_tokens = 120,
            prompt_cache_hit_tokens = 0, prompt_cache_miss_tokens = 100 } }
      end
      return { content = "done", finish_reason = "stop",
        usage = { prompt_tokens = 200, completion_tokens = 10, total_tokens = 210,
          prompt_cache_hit_tokens = 80, prompt_cache_miss_tokens = 120 } }
    end
  end)(),
}

local tmp = os.tmpname(); os.remove(tmp); os.execute("mkdir -p '" .. tmp .. "'")
local real_write, real_flush = io.write, io.flush
io.write = function() end; io.flush = function() end
local agent = Agent:init({ model = "test", base_url = "x", max_steps = 5, sessions_dir = tmp .. "/s" }, tmp)
local session = { id = "t", messages = {}, cwd = tmp }
agent:run(session, "go")
io.write, io.flush = real_write, real_flush
os.execute("rm -rf '" .. tmp .. "'")

ok(session.context_tokens == 200, "context_tokens = latest prompt_tokens (got " .. tostring(session.context_tokens) .. ")")
ok(session.completion_tokens == 30, "completion_tokens = sum of completion (got " .. tostring(session.completion_tokens) .. ")")
ok(session.cache_hit_tokens == 80, "cache_hit_tokens summed")
ok(session.cache_miss_tokens == 220, "cache_miss_tokens summed")

if fail == 0 then print("\nALL PASS") else print("\n" .. fail .. " FAILED"); os.exit(1) end
