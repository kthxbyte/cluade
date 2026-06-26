-- Tests for loopdetect: warn-then-stop loop detection.
-- check() returns one of: nil (fine), "warn", "stop", plus a reason string.
-- Detection uses CONSECUTIVE semantics so changed behavior resets cleanly.

package.path = "./?.lua;" .. package.path
local LoopDetect = require("loopdetect")

local fail = 0
local function ok(cond, msg)
  if cond then print("  ok  - " .. msg) else print("  FAIL- " .. msg); fail = fail + 1 end
end

-- helper: feed one step's calls (list of {sig, err}) then return check()
local function step(d, calls)
  for _, c in ipairs(calls) do
    d:record_call(c[1])
    d:record_result(c[2] == true)
  end
  return d:check()
end

-- 1. Below threshold: identical calls fewer than 3 in a row -> no action.
do
  local d = LoopDetect.new()
  ok(step(d, { { "read:a" } }) == nil, "1 identical call: no action")
  ok(step(d, { { "read:a" } }) == nil, "2 identical calls: no action")
end

-- 2. Third identical consecutive call -> warn (not stop).
do
  local d = LoopDetect.new()
  step(d, { { "bash:ls" } })
  step(d, { { "bash:ls" } })
  local action, reason = step(d, { { "bash:ls" } })
  ok(action == "warn", "3rd identical call warns")
  ok(reason == "repeat", "warn reason is 'repeat'")
end

-- 3. Keeps repeating after the warning -> stop.
do
  local d = LoopDetect.new()
  step(d, { { "bash:ls" } }); step(d, { { "bash:ls" } }); step(d, { { "bash:ls" } }) -- warn here
  local action, reason = step(d, { { "bash:ls" } })
  ok(action == "stop", "4th identical call (after warn) stops")
  ok(reason == "repeat", "stop reason is 'repeat'")
end

-- 4. Changing the call after a warning disarms it (no immediate stop).
do
  local d = LoopDetect.new()
  step(d, { { "bash:ls" } }); step(d, { { "bash:ls" } }); step(d, { { "bash:ls" } }) -- warn
  ok(step(d, { { "read:other" } }) == nil, "different call after warn: no action (disarmed)")
  -- and a fresh repeat run warns again rather than stopping
  step(d, { { "grep:x" } }); step(d, { { "grep:x" } })
  ok(step(d, { { "grep:x" } }) == "warn", "a new distinct loop gets its own warning")
end

-- 5. Consecutive errors: 4 in a row -> warn, 5th -> stop.
do
  local d = LoopDetect.new()
  step(d, { { "bash:x", true } })
  step(d, { { "bash:y", true } })   -- different sigs, but all errors
  step(d, { { "bash:z", true } })
  local a4 = step(d, { { "bash:w", true } })
  ok(a4 == "warn", "4 consecutive errors warns")
  ok(select(2, (function() local d2 = LoopDetect.new(); for i=1,4 do step(d2,{{"e"..i,true}}) end; return d2:check() end)()) == "error", "error trip reason is 'error'")
  local a5 = step(d, { { "bash:v", true } })
  ok(a5 == "stop", "5th consecutive error (after warn) stops")
end

-- 6. A success resets the error streak.
do
  local d = LoopDetect.new()
  step(d, { { "a", true } }); step(d, { { "b", true } }); step(d, { { "c", true } })
  ok(step(d, { { "d", false } }) == nil, "a success breaks the error streak")
  ok(step(d, { { "e", true } }) == nil, "error count restarts after success")
end

-- 7. Three identical calls within a SINGLE step (parallel) also warn.
do
  local d = LoopDetect.new()
  local action = step(d, { { "bash:ls" }, { "bash:ls" }, { "bash:ls" } })
  ok(action == "warn", "3 identical calls in one step warns")
end

-- 8. Custom thresholds honored.
do
  local d = LoopDetect.new({ repeat_threshold = 2, error_threshold = 2 })
  step(d, { { "x" } })
  ok(step(d, { { "x" } }) == "warn", "repeat_threshold=2 warns on 2nd identical")
end

if fail == 0 then print("\nALL PASS") else print("\n" .. fail .. " FAILED"); os.exit(1) end
