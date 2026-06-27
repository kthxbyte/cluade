-- Tests the precedence of project instruction files. cluade follows opencode's
-- ordering: AGENTS.md (the cross-tool standard) is preferred, with CLAUDE.md as
-- a fallback and GEMINI.md last. First match in that order wins; the others are
-- ignored (mirroring opencode, and matching the common symlink convention where
-- the files are identical anyway).

package.path = "./?.lua;./?/init.lua;" .. package.path
local Agent = require("agent")

local fail = 0
local function ok(cond, msg)
  if cond then print("  ok  - " .. msg) else print("  FAIL- " .. msg); fail = fail + 1 end
end

local function with_files(files)
  local tmp = os.tmpname()
  os.remove(tmp)
  os.execute("mkdir -p '" .. tmp .. "'")
  for name, body in pairs(files) do
    local f = io.open(tmp .. "/" .. name, "w")
    f:write(body)
    f:close()
  end
  local agent = Agent:init({}, tmp)
  local instr = agent:_read_instructions()
  os.execute("rm -rf '" .. tmp .. "'")
  return instr or ""
end

-- AGENTS.md wins over CLAUDE.md and GEMINI.md.
do
  local instr = with_files({ ["AGENTS.md"] = "A", ["CLAUDE.md"] = "C", ["GEMINI.md"] = "G" })
  ok(instr:find("from ./AGENTS.md", 1, true) ~= nil, "AGENTS.md preferred over CLAUDE.md/GEMINI.md")
end

-- CLAUDE.md is the fallback when AGENTS.md is absent.
do
  local instr = with_files({ ["CLAUDE.md"] = "C", ["GEMINI.md"] = "G" })
  ok(instr:find("from ./CLAUDE.md", 1, true) ~= nil, "CLAUDE.md used when AGENTS.md absent")
end

-- GEMINI.md is the last resort.
do
  local instr = with_files({ ["GEMINI.md"] = "G" })
  ok(instr:find("from ./GEMINI.md", 1, true) ~= nil, "GEMINI.md used when it is the only file")
end

if fail == 0 then print("\nALL PASS") else print("\n" .. fail .. " FAILED"); os.exit(1) end
