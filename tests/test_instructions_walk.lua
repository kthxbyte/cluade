-- Tests opencode-style instruction discovery: a directory-tree walk upward from
-- cwd (nearest ancestor file wins, but never past the git root), plus a global
-- ~/.cluade file combined ahead of the local one. The per-file precedence
-- (AGENTS.md > CLAUDE.md > GEMINI.md) is covered in test_instructions_order.lua.

package.path = "./?.lua;./?/init.lua;" .. package.path
local Agent = require("agent")

local fail = 0
local function ok(cond, msg)
  if cond then print("  ok  - " .. msg) else print("  FAIL- " .. msg); fail = fail + 1 end
end

local function mk(path) os.execute("mkdir -p '" .. path .. "'") end
local function put(path, body)
  local f = io.open(path, "w"); f:write(body); f:close()
end
local function newdir()
  local d = os.tmpname(); os.remove(d); mk(d); return d
end
-- Point the global ~/.cluade lookup at a dir of our choosing (empty = no global).
local function set_global(dir) Agent._user_dir = function() return dir end end

local empty_global = newdir()

-- 1. Nearest ancestor wins when cwd has no file of its own.
do
  set_global(empty_global)
  local root = newdir()
  mk(root .. "/.git"); put(root .. "/.git/HEAD", "ref: x")
  put(root .. "/AGENTS.md", "ROOT_RULES")
  mk(root .. "/a/b")
  local agent = Agent:init({}, root .. "/a/b")
  local instr = agent:_read_instructions() or ""
  ok(instr:find("ROOT_RULES", 1, true) ~= nil, "walk finds an ancestor's AGENTS.md")
  ok(instr:find(root .. "/AGENTS.md", 1, true) ~= nil, "label shows the ancestor path")
  os.execute("rm -rf '" .. root .. "'")
end

-- 2. A file in cwd beats an ancestor's file.
do
  set_global(empty_global)
  local root = newdir()
  mk(root .. "/.git")
  put(root .. "/AGENTS.md", "ROOT_RULES")
  mk(root .. "/sub"); put(root .. "/sub/AGENTS.md", "SUB_RULES")
  local agent = Agent:init({}, root .. "/sub")
  local instr = agent:_read_instructions() or ""
  ok(instr:find("SUB_RULES", 1, true) ~= nil and instr:find("ROOT_RULES", 1, true) == nil,
    "nearest file (cwd) wins over ancestor")
  ok(instr:find("from ./AGENTS.md", 1, true) ~= nil, "cwd file labelled ./AGENTS.md")
  os.execute("rm -rf '" .. root .. "'")
end

-- 3. The walk stops at the git root: a file above it is never read.
do
  set_global(empty_global)
  local base = newdir()
  put(base .. "/AGENTS.md", "OUTSIDE_REPO")        -- above the repo
  mk(base .. "/repo/.git"); put(base .. "/repo/.git/HEAD", "ref: x")
  mk(base .. "/repo/sub")                            -- no instruction files inside repo
  local agent = Agent:init({}, base .. "/repo/sub")
  local instr = agent:_read_instructions()
  ok(instr == nil, "walk stops at git root; ancestor-of-repo file is ignored")
  os.execute("rm -rf '" .. base .. "'")
end

-- 4. Global file is combined ahead of the local file.
do
  local g = newdir(); put(g .. "/AGENTS.md", "GLOBAL_RULES"); set_global(g)
  local root = newdir(); mk(root .. "/.git"); put(root .. "/AGENTS.md", "LOCAL_RULES")
  local agent = Agent:init({}, root)
  local instr = agent:_read_instructions() or ""
  local gp = instr:find("GLOBAL_RULES", 1, true)
  local lp = instr:find("LOCAL_RULES", 1, true)
  ok(gp ~= nil and lp ~= nil, "both global and local instructions present")
  ok(gp and lp and gp < lp, "global appears before local (base then override)")
  os.execute("rm -rf '" .. g .. "'"); os.execute("rm -rf '" .. root .. "'")
end

-- 5. Global file alone, when there is no local file.
do
  local g = newdir(); put(g .. "/CLAUDE.md", "GLOBAL_ONLY"); set_global(g)
  local root = newdir(); mk(root .. "/.git")   -- .git stops the walk immediately; no local file
  local agent = Agent:init({}, root)
  local instr = agent:_read_instructions() or ""
  ok(instr:find("GLOBAL_ONLY", 1, true) ~= nil, "global instructions used with no local file")
  os.execute("rm -rf '" .. g .. "'"); os.execute("rm -rf '" .. root .. "'")
end

os.execute("rm -rf '" .. empty_global .. "'")

if fail == 0 then print("\nALL PASS") else print("\n" .. fail .. " FAILED"); os.exit(1) end
