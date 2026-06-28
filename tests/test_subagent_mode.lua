-- Tests --subagent mode's two output behaviors:
--  * quiet: progress (step markers, timings, tool chatter) goes to stderr, and
--    ONLY the final assistant message reaches stdout, so a parent can capture it.
--  * ephemeral: no session file is persisted (no traces left behind).

package.path = "./?.lua;./?/init.lua;" .. package.path

local fail = 0
local function ok(cond, msg)
  if cond then print("  ok  - " .. msg) else print("  FAIL- " .. msg); fail = fail + 1 end
end

-- Stub provider: one assistant message with content, then stop.
package.loaded["provider"] = {
  new = function(self, _) return setmetatable({}, { __index = self }) end,
  chat = function()
    return { content = "FINAL_ANSWER_X", finish_reason = "stop", usage = { total_tokens = 1 } }
  end,
}
local Agent = require("agent")

-- Run fn() with stdout redirected to a temp file; return what was written there.
local function capture_stdout(fn)
  local path = os.tmpname()
  local fh = io.open(path, "w")
  local prev = io.output()
  io.output(fh)
  fn()
  fh:flush()
  io.output(prev)
  fh:close()
  local f = io.open(path, "r"); local c = f:read("*a"); f:close(); os.remove(path)
  return c
end

local function newdir() local d = os.tmpname(); os.remove(d); os.execute("mkdir -p '" .. d .. "'"); return d end
local function has_json(dir)
  local f = io.popen("ls '" .. dir .. "'/*.json 2>/dev/null | wc -l")
  local n = tonumber(f:read("*l")); f:close(); return n and n > 0
end

-- 1. quiet: stdout carries only the final answer.
do
  local sd = newdir()
  local agent = Agent:init({ model = "t", base_url = "x", max_steps = 3, sessions_dir = sd,
    quiet = true, ephemeral = true }, ".")
  local out = capture_stdout(function() agent:run({ id = "q", messages = {}, cwd = "." }, "hi") end)
  ok(out == "FINAL_ANSWER_X\n", "quiet stdout is exactly the final answer (got " .. string.format("%q", out) .. ")")
  ok(not out:find("[step", 1, true), "quiet stdout has no step markers")
  os.execute("rm -rf '" .. sd .. "'")
end

-- 2. ephemeral: no session file written.
do
  local sd = newdir()
  local agent = Agent:init({ model = "t", base_url = "x", max_steps = 3, sessions_dir = sd,
    quiet = true, ephemeral = true }, ".")
  capture_stdout(function() agent:run({ id = "e", messages = {}, cwd = "." }, "hi") end)
  ok(not has_json(sd), "ephemeral run leaves no session file")
  os.execute("rm -rf '" .. sd .. "'")
end

-- 3. control: a non-ephemeral run still persists its session.
do
  local sd = newdir()
  local agent = Agent:init({ model = "t", base_url = "x", max_steps = 3, sessions_dir = sd,
    quiet = true }, ".")
  capture_stdout(function() agent:run({ id = "p", messages = {}, cwd = "." }, "hi") end)
  ok(has_json(sd), "non-ephemeral run persists a session file")
  os.execute("rm -rf '" .. sd .. "'")
end

if fail == 0 then print("\nALL PASS") else print("\n" .. fail .. " FAILED"); os.exit(1) end
