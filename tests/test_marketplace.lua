-- Tests the marketplace parser and the per-plugin compatibility verdict. A
-- Claude Code marketplace (.claude-plugin/marketplace.json) lists plugins, each
-- declaring its component types (skills/commands/agents/hooks/mcpServers/...).
-- cluade can consume skills (and read commands/agents as text) but not run
-- hooks/MCP/LSP, so the verdict reflects how much of a plugin actually crosses
-- over -- refined by the per-skill portable/limited check from skillimport.

package.path = "./?.lua;./?/init.lua;" .. package.path
local MP = require("marketplace")

local fail = 0
local function ok(cond, msg)
  if cond then print("  ok  - " .. msg) else print("  FAIL- " .. msg); fail = fail + 1 end
end

-- 1. Parse a marketplace manifest into plugins with component counts.
do
  local json = [[
  {
    "name": "anthropic-agent-skills",
    "metadata": { "description": "Anthropic example skills" },
    "plugins": [
      { "name": "document-skills", "description": "docs", "source": "./",
        "skills": ["./skills/xlsx", "./skills/docx", "./skills/pptx", "./skills/pdf"] },
      { "name": "claude-api", "source": "./", "skills": ["./skills/claude-api"] }
    ]
  }]]
  local m = MP.parse(json)
  ok(m.name == "anthropic-agent-skills", "marketplace name parsed")
  ok(#m.plugins == 2, "two plugins parsed")
  ok(m.plugins[1].name == "document-skills", "plugin name parsed")
  ok(m.plugins[1].counts.skills == 4, "skill count parsed")
  ok(m.plugins[1].skill_paths[1] == "./skills/xlsx", "skill paths captured")
end

-- 2. Component counting handles arrays, objects, and absence.
do
  ok(MP.count(nil) == 0, "absent -> 0")
  ok(MP.count({ "a", "b" }) == 2, "array -> length")
  ok(MP.count({ x = 1, y = 2, z = 3 }) == 3, "object -> key count")
end

-- 3. Plugin verdict: usable / degraded / text-only / blockers.
do
  local V = MP.plugin_verdict
  ok(V(1, 0, 0, false) == "compatible", "portable skills, no blockers -> compatible")
  ok(V(0, 4, 0, false) == "limited", "only runtime-bound (limited) skills -> limited")
  ok(V(3, 2, 0, false) == "partial", "mix of usable and degraded skills -> partial")
  ok(V(2, 0, 0, true) == "partial", "skills plus hooks/MCP blockers -> partial")
  ok(V(0, 0, 0, true) == "incompatible", "only hooks/MCP/LSP, nothing consumable -> incompatible")
  ok(V(0, 0, 2, false) == "partial", "only commands/agents (text-portable) -> partial")
end

if fail == 0 then print("\nALL PASS") else print("\n" .. fail .. " FAILED"); os.exit(1) end
