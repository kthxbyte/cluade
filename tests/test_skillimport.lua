-- Tests the tool-support classifier and frontmatter parser used by the skill
-- importer. The classifier maps a skill's declared `allowed-tools` (the Agent
-- Skills metadata field) onto cluade's tool set, so we can tell up front which
-- imported skills are fully supported, partially supported, or unverifiable.

package.path = "./?.lua;./?/init.lua;" .. package.path
local SI = require("skillimport")

local fail = 0
local function ok(cond, msg)
  if cond then print("  ok  - " .. msg) else print("  FAIL- " .. msg); fail = fail + 1 end
end
local function has(list, want)
  for _, v in ipairs(list) do if v == want then return true end end
  return false
end

-- Tool-name normalization across casing/separators (Claude vs cluade naming).
do
  ok(SI.normalize("WebSearch") == SI.normalize("web_search"), "WebSearch == web_search after normalize")
  ok(SI.normalize("Read") == "read", "Read normalizes to read")
end

-- 1. All tools supported -> full.
do
  local r = SI.classify("Read, Grep, Glob")
  ok(r.status == "full", "Read/Grep/Glob -> full support")
  ok(#r.unsupported == 0, "no unsupported tools")
end

-- 2. Claude tool names map to cluade equivalents.
do
  local r = SI.classify("WebSearch WebFetch")
  ok(r.status == "full", "WebSearch/WebFetch map to web_search/web_fetch -> full")
end

-- 3. An unknown tool -> partial, and it is reported.
do
  local r = SI.classify("Read Bash Task")
  ok(r.status == "partial", "Task is unsupported -> partial")
  ok(has(r.unsupported, "Task"), "Task listed as unsupported")
  ok(has(r.supported, "Read") and has(r.supported, "Bash"), "Read/Bash listed as supported")
end

-- 4. MCP tools are unsupported and flagged as MCP.
do
  local r = SI.classify("mcp__github__create_issue")
  ok(r.status == "partial", "MCP tool -> partial")
  ok(r.has_mcp == true, "MCP usage flagged")
end

-- 5. No allowed-tools declared -> unknown (cannot verify from metadata).
do
  local r = SI.classify(nil)
  ok(r.status == "unknown", "absent allowed-tools -> unknown")
end

-- 6. YAML inline-list form is accepted.
do
  local r = SI.classify("[Read, Edit]")
  ok(r.status == "full", "inline YAML list parsed")
end

-- 7. Frontmatter parsing: scalar fields + multiline allowed-tools list.
do
  local content = table.concat({
    "---",
    "name: my-skill",
    "description: does a thing",
    "allowed-tools:",
    "  - Read",
    "  - Grep",
    "---",
    "body text here",
  }, "\n")
  local fm = SI.parse_skill(content)
  ok(fm.name == "my-skill", "parsed name")
  ok(fm.description == "does a thing", "parsed description")
  local r = SI.classify(fm["allowed-tools"])
  ok(r.status == "full", "multiline allowed-tools list -> full support")
end

-- 8. Frontmatter parsing: inline allowed-tools value.
do
  local content = "---\nname: x\nallowed-tools: Read Bash\n---\nbody"
  local fm = SI.parse_skill(content)
  ok(SI.classify(fm["allowed-tools"]).status == "full", "inline allowed-tools value parsed")
end

if fail == 0 then print("\nALL PASS") else print("\n" .. fail .. " FAILED"); os.exit(1) end
