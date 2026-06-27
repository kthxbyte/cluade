-- Tests for Tools.execute_glob, especially the recursive ** branch.
-- Builds a small temp tree and exercises non-recursive vs recursive patterns.

package.path = "./?.lua;./?/init.lua;" .. package.path
local T = require("tools")

local fail = 0
local function ok(cond, msg)
  if cond then print("  ok  - " .. msg) else print("  FAIL- " .. msg); fail = fail + 1 end
end

-- Temp tree: a.lua, b.lua at top; sub/c.lua nested; readme.md as a non-match.
local base = os.tmpname()
os.remove(base)
os.execute('mkdir -p "' .. base .. '/sub"')
os.execute('touch "' .. base .. '/a.lua" "' .. base .. '/b.lua" "' .. base .. '/sub/c.lua" "' .. base .. '/readme.md"')

local function count(out)
  if not out or out == "(no matches)" then return 0 end
  local n = 0
  for _ in out:gmatch("[^\n]+") do n = n + 1 end
  return n
end

-- Non-recursive: top-level only.
do
  local r = T.execute_glob(base, { pattern = base .. "/*.lua" })
  ok(count(r.output) == 2, "non-recursive *.lua -> 2 top-level files")
end

-- Recursive **: every depth.
do
  local r = T.execute_glob(base, { pattern = base .. "/**/*.lua" })
  ok(count(r.output) == 3, "recursive **/*.lua -> 3 files incl. nested")
end

-- Recursive ** with a relative pattern resolves against cwd.
do
  local r = T.execute_glob(base, { pattern = "**/*.lua" })
  ok(count(r.output) == 3, "relative recursive resolves against cwd -> 3")
end

-- params.path: a relative pattern resolves against it (like grep), NOT cwd.
-- Run from an empty cwd so a dropped path would yield zero matches.
local emptycwd = os.tmpname(); os.remove(emptycwd); os.execute('mkdir -p "' .. emptycwd .. '"')
do
  local r = T.execute_glob(emptycwd, { pattern = "**/*.lua", path = base })
  ok(count(r.output) == 3, "recursive pattern honors params.path -> 3")
end
do
  local r = T.execute_glob(emptycwd, { pattern = "*.lua", path = base })
  ok(count(r.output) == 2, "non-recursive pattern honors params.path -> 2 top-level")
end
-- An absolute pattern wins; params.path is ignored.
do
  local r = T.execute_glob(emptycwd, { pattern = base .. "/**/*.lua", path = "/does/not/exist" })
  ok(count(r.output) == 3, "absolute pattern ignores params.path -> 3")
end
os.execute('rm -rf "' .. emptycwd .. '"')

os.execute('rm -rf "' .. base .. '"')

if fail == 0 then print("\nALL PASS") else print("\n" .. fail .. " FAILED"); os.exit(1) end
