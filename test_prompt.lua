-- Tests for Agent:prompt_yes_no terminal handling.
-- A permission prompt must read the answer in cooked mode (canonical + echo)
-- even when the REPL has left the terminal in raw (-icanon -echo) mode, and it
-- must restore the exact prior mode afterward. The tty operations are behind
-- seams so the contract can be verified without a real terminal.

package.path = "./?.lua;./?/init.lua;" .. package.path
local Agent = require("agent")

local fail = 0
local function ok(cond, msg)
  if cond then print("  ok  - " .. msg) else print("  FAIL- " .. msg); fail = fail + 1 end
end

-- Drive prompt_yes_no with injected seams; record the call order.
local function run(answer, save_ret)
  local log = {}
  Agent._tty_save = function() log[#log + 1] = "save"; return save_ret end
  Agent._tty_cooked = function() log[#log + 1] = "cooked" end
  Agent._tty_restore = function(s) log[#log + 1] = "restore:" .. tostring(s) end
  Agent._read_line = function() log[#log + 1] = "read"; return answer end
  local real_write = io.write
  io.write = function() end            -- keep test output clean
  local result = Agent:prompt_yes_no("Allow X?")
  io.write = real_write
  return result, log
end

local function concat(t) return table.concat(t, ",") end

-- 1. Answer parsing.
do
  ok(select(1, run("y", "S")) == true, "'y' is approval")
  ok(select(1, run("yes", "S")) == true, "'yes' is approval")
  ok(select(1, run("n", "S")) == false, "'n' is denial")
  ok(select(1, run("", "S")) == false, "empty line is denial")
  ok(select(1, run(nil, "S")) == false, "EOF (nil) is denial, not an error")
end

-- 2. When a tty mode was captured: cooked before read, restore after.
do
  local _, log = run("y", "SAVED")
  ok(concat(log) == "save,cooked,read,restore:SAVED",
    "cooked mode set before read, prior mode restored after")
end

-- 3. When no tty mode is available (save returns nil): skip toggling, still read.
do
  local _, log = run("y", nil)
  ok(concat(log) == "save,read", "no tty -> no cooked/restore, but still reads")
end

if fail == 0 then print("\nALL PASS") else print("\n" .. fail .. " FAILED"); os.exit(1) end
