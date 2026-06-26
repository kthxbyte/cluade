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

-- 9. signature(): JSON key order does not change the signature.
do
  local s1 = LoopDetect.signature("bash", { command = "ls", cwd = "/tmp" })
  local s2 = LoopDetect.signature("bash", { cwd = "/tmp", command = "ls" })
  ok(s1 == s2, "same args, different key order -> identical signature")
end

-- 10. signature(): different values still differ.
do
  local s1 = LoopDetect.signature("bash", { command = "ls" })
  local s2 = LoopDetect.signature("bash", { command = "pwd" })
  ok(s1 ~= s2, "different arg values -> different signatures")
end

-- 11. signature(): different tool name differs even with same args.
do
  local s1 = LoopDetect.signature("read", { path = "a" })
  local s2 = LoopDetect.signature("grep", { path = "a" })
  ok(s1 ~= s2, "different tool name -> different signatures")
end

-- 12. signature(): nested table key order also normalized.
do
  local s1 = LoopDetect.signature("x", { a = { p = 1, q = 2 }, b = 3 })
  local s2 = LoopDetect.signature("x", { b = 3, a = { q = 2, p = 1 } })
  ok(s1 == s2, "nested key order normalized too")
end

-- 13. signature(): array element order is preserved (it is meaningful).
do
  local s1 = LoopDetect.signature("x", { items = { "a", "b" } })
  local s2 = LoopDetect.signature("x", { items = { "b", "a" } })
  ok(s1 ~= s2, "array order is significant -> different signatures")
end

-- 14. signature(): a non-table arg (e.g. raw unparsed string) passes through.
do
  local s1 = LoopDetect.signature("bash", "{malformed")
  local s2 = LoopDetect.signature("bash", "{malformed")
  ok(s1 == s2, "string args compare equal when identical")
  ok(LoopDetect.signature("bash", "{a") ~= LoopDetect.signature("bash", "{b"),
    "distinct string args stay distinct (no false collapse)")
end

-- 15. normalized signatures actually drive the detector (integration).
do
  local d = LoopDetect.new()
  local function call(args) return LoopDetect.signature("bash", args) end
  d:record_call(call({ command = "ls", cwd = "/tmp" })); d:record_result(false)
  d:record_call(call({ cwd = "/tmp", command = "ls" })); d:record_result(false)
  d:record_call(call({ command = "ls", cwd = "/tmp" })); d:record_result(false)
  ok(d:check() == "warn", "key-shuffled identical calls count as a repeat loop")
end

if fail == 0 then print("\nALL PASS") else print("\n" .. fail .. " FAILED"); os.exit(1) end
