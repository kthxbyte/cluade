-- Tests for Agent._format_tool_json: the --show-tools-json debug formatter.
-- It renders a tool call as "<name> <raw arguments>", showing exactly what the
-- model emitted (the arguments string verbatim), so malformed/odd payloads are
-- visible before cluade parses them.

package.path = "./?.lua;./?/init.lua;" .. package.path
local Agent = require("agent")
local json = require("vendor.json")

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
  ok(out:match('"id":%s*"call_1"') ~= nil, "decoded structure includes the envelope (id)")
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

-- 8. _pretty_json: scalars delegate to json.encode; objects/arrays indent 2
--    spaces per level; object keys sorted for deterministic output.
do
  ok(Agent._pretty_json(5) == json.encode(5), "scalar number delegates to json.encode")
  ok(Agent._pretty_json("hi") == '"hi"', "scalar string")
  ok(Agent._pretty_json({ b = "y", a = "x" }) == '{\n  "a": "x",\n  "b": "y"\n}',
    "object: sorted keys, 2-space indent")
  ok(Agent._pretty_json({ "x", "y" }) == '[\n  "x",\n  "y"\n]', "array: one element per line")
  ok(Agent._pretty_json({ a = { b = "y" } }) == '{\n  "a": {\n    "b": "y"\n  }\n}',
    "nested object indents progressively")
  ok(Agent._pretty_json({}) == json.encode({}), "empty table delegates to json.encode")
end

-- 9. reasoning_content is surfaced on the decoded header when present.
do
  local resp = {
    reasoning_content = "Checking the OS via uname.",
    tool_calls = { { ["function"] = { name = "bash", arguments = '{"command":"uname -a"}' } } },
  }
  local out = Agent._format_tools_debug(resp)
  ok(out:find('[tool_calls decoded - reasoning: "Checking the OS via uname."]', 1, true) ~= nil,
    "decoded header carries the reasoning text in the requested format")
end

-- 10. No reasoning_content: plain decoded header, no 'reasoning:' suffix.
do
  local resp = { tool_calls = { { ["function"] = { name = "read", arguments = "{}" } } } }
  local out = Agent._format_tools_debug(resp)
  ok(out:match("%[tool_calls decoded%]") ~= nil, "plain header when no reasoning")
  ok(not out:find("reasoning:", 1, true), "no reasoning suffix when absent")
end

if fail == 0 then print("\nALL PASS") else print("\n" .. fail .. " FAILED"); os.exit(1) end
