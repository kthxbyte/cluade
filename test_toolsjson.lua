-- Tests for Agent._format_tool_json: the --show-tools-json debug formatter.
-- It renders a tool call as "<name> <raw arguments>", showing exactly what the
-- model emitted (the arguments string verbatim), so malformed/odd payloads are
-- visible before cluade parses them.

package.path = "./?.lua;./?/init.lua;" .. package.path
local Agent = require("agent")

local fail = 0
local function ok(cond, msg)
  if cond then print("  ok  - " .. msg) else print("  FAIL- " .. msg); fail = fail + 1 end
end

-- 1. String arguments are shown verbatim, prefixed by the tool name.
do
  local tc = { id = "call_1", type = "function",
               ["function"] = { name = "glob", arguments = '{"pattern":"*.lua"}' } }
  ok(Agent._format_tool_json(tc) == 'glob {"pattern":"*.lua"}', "name + raw arguments string verbatim")
end

-- 2. Table arguments (non-standard) get JSON-encoded.
do
  local tc = { ["function"] = { name = "read", arguments = { filePath = "a.lua" } } }
  local out = Agent._format_tool_json(tc)
  ok(out:match("^read "), "table args keep the name prefix")
  ok(out:match('"filePath"'), "table args are encoded to JSON")
end

-- 3. Missing arguments render as an empty object, not an error.
do
  local tc = { ["function"] = { name = "compact" } }
  ok(Agent._format_tool_json(tc) == "compact {}", "nil arguments -> {}")
end

-- 4. Malformed argument strings are passed through untouched (the whole point).
do
  local tc = { ["function"] = { name = "bash", arguments = '{"command": "ls' } }
  ok(Agent._format_tool_json(tc) == 'bash {"command": "ls', "malformed JSON shown as-is")
end

-- 5. Defensive: missing function / nil never crashes.
do
  ok(type(Agent._format_tool_json({})) == "string", "tc with no function is safe")
  ok(type(Agent._format_tool_json(nil)) == "string", "nil tc is safe")
end

-- 6. _format_tools_debug: all three layers (raw body, decoded array, compact).
do
  local resp = {
    raw_body = '{"choices":[{"message":{"tool_calls":[{"id":"call_1"}]}}]}',
    tool_calls = {
      { id = "call_1", type = "function",
        ["function"] = { name = "glob", arguments = '{"pattern":"*.lua"}' } },
    },
  }
  local out = Agent._format_tools_debug(resp)
  ok(out:match("%[raw response body%]"), "shows the raw response body section")
  ok(out:find(resp.raw_body, 1, true) ~= nil, "raw body bytes present verbatim")
  ok(out:match("%[tool_calls decoded%]"), "shows the decoded tool_calls structure")
  ok(out:find('"id":"call_1"', 1, true) ~= nil, "decoded structure includes the envelope (id)")
  ok(out:match("%[tool%-call json%] glob"), "shows the per-call compact view")
end

-- 7. No raw_body: omit the raw section, still show decoded + compact.
do
  local resp = { tool_calls = {
    { ["function"] = { name = "read", arguments = '{"filePath":"a.lua"}' } } } }
  local out = Agent._format_tools_debug(resp)
  ok(not out:match("%[raw response body%]"), "no raw section when raw_body absent")
  ok(out:match("%[tool%-call json%] read"), "still shows the compact view")
end

if fail == 0 then print("\nALL PASS") else print("\n" .. fail .. " FAILED"); os.exit(1) end
