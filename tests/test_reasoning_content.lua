-- In DeepSeek thinking mode, an assistant message carrying tool_calls must also
-- carry reasoning_content when replayed, or the API returns 400 ("reasoning_content
-- in the thinking mode must be passed back"). cluade normally replays what the
-- model returned, but a turn that returned none (or a session resumed across
-- providers) would omit it. HttpProvider._ensure_reasoning closes that gap by
-- defaulting a missing reasoning_content to "" -- but ONLY on assistant messages
-- that have tool_calls, so the non-standard field is never added elsewhere.

package.path = "./?.lua;./?/init.lua;" .. package.path
local Provider = require("provider")

local fail = 0
local function ok(cond, msg)
  if cond then print("  ok  - " .. msg) else print("  FAIL- " .. msg); fail = fail + 1 end
end

local msgs = {
  { role = "system", content = "sys" },
  { role = "user", content = "hi" },
  -- assistant with tool_calls, no reasoning_content -> should be defaulted to ""
  { role = "assistant", content = "", tool_calls = { { id = "c1", type = "function",
    ["function"] = { name = "x", arguments = "{}" } } } },
  -- assistant with tool_calls AND reasoning_content -> left intact
  { role = "assistant", content = "", reasoning_content = "kept",
    tool_calls = { { id = "c2", type = "function", ["function"] = { name = "y", arguments = "{}" } } } },
  -- assistant WITHOUT tool_calls -> must NOT gain a reasoning_content field
  { role = "assistant", content = "just text" },
  { role = "tool", tool_call_id = "c1", content = "{}" },
}

Provider._ensure_reasoning(msgs)

ok(msgs[3].reasoning_content == "", "tool-call assistant missing reasoning_content -> defaulted to \"\"")
ok(msgs[4].reasoning_content == "kept", "existing reasoning_content left intact")
ok(msgs[5].reasoning_content == nil, "assistant without tool_calls gains no reasoning_content")
ok(msgs[1].reasoning_content == nil and msgs[6].reasoning_content == nil,
  "non-assistant messages untouched")

if fail == 0 then print("\nALL PASS") else print("\n" .. fail .. " FAILED"); os.exit(1) end
