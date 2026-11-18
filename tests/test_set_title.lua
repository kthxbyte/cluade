-- Tests for the session-title building blocks: Store.title_snippet (a one-line
-- trimmed/truncated snippet) and the set_title tool executor (returns a special
-- "titled" status the run loop applies, mirroring compact).

package.path = "./?.lua;./?/init.lua;" .. package.path
local Store = require("store")
local Tools = require("tools")

local fail = 0
local function ok(cond, msg)
  if cond then print("  ok  - " .. msg) else print("  FAIL- " .. msg); fail = fail + 1 end
end

-- title_snippet
ok(Store.title_snippet("fix the thing\nmore") == "fix the thing", "snippet = first line, trimmed")
ok(Store.title_snippet("   hello  ") == "hello", "snippet trims surrounding space")
ok(Store.title_snippet("   ") == nil, "blank -> nil")
ok(Store.title_snippet(nil) == nil, "nil -> nil")
do
  local long = Store.title_snippet(("x"):rep(80))
  ok(long and #long <= 53, "long snippet truncated to ~50 + ellipsis (got " .. tostring(long and #long) .. ")")
end

-- execute_set_title
ok(Tools.execute_set_title(".", { title = "Fix DeepSeek 400" }).status == "titled", "valid title -> titled status")
ok(Tools.execute_set_title(".", { title = "Fix DeepSeek 400" }).title == "Fix DeepSeek 400", "title returned")
ok(Tools.execute_set_title(".", { title = "  spaced out  " }).title == "spaced out", "title trimmed")
ok(Tools.execute_set_title(".", { title = "a\nb" }).title == "a", "title is first line only")
ok(Tools.execute_set_title(".", { title = "" }).status == "error", "empty title -> error")
ok(Tools.execute_set_title(".", {}).status == "error", "missing title -> error")

if fail == 0 then print("\nALL PASS") else print("\n" .. fail .. " FAILED"); os.exit(1) end
