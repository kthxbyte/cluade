-- marketplace.lua -- browse a Claude Code plugin marketplace and report, per
-- plugin, how much of it cluade can actually use.
--
-- A marketplace is a git repo with a .claude-plugin/marketplace.json cataloguing
-- plugins. Each plugin declares component types: skills/commands/agents (which
-- cluade can consume -- skills natively, commands/agents as text) and
-- hooks/mcpServers/lspServers (which need a runtime cluade lacks). We clone the
-- marketplace, parse the manifest, and -- reusing skillimport's per-skill check
-- (portable vs python/node-bound) -- give each plugin a compatibility verdict.
--
-- Usage:  lua5.1 marketplace.lua <git-url | owner/repo | local-path>
--   (e.g.  lua5.1 marketplace.lua anthropics/skills)

local json = require("vendor.json")
local skillimport = require("skillimport")

local M = {}

-- Count a component value: array -> length, object -> key count, scalar -> 1.
function M.count(v)
  if v == nil then return 0 end
  if type(v) == "table" then
    if #v > 0 then return #v end
    local n = 0
    for _ in pairs(v) do n = n + 1 end
    return n
  end
  return 1
end

-- Parse a marketplace.json string into { name, description, plugin_root, plugins }.
-- Each plugin carries component counts plus the raw skill paths for deeper checks.
function M.parse(str)
  local data = json.decode(str)
  local m = {
    name = data.name,
    description = data.metadata and data.metadata.description,
    plugin_root = data.metadata and data.metadata.pluginRoot,
    plugins = {},
  }
  for _, p in ipairs(data.plugins or {}) do
    m.plugins[#m.plugins + 1] = {
      name = p.name,
      description = p.description,
      source = p.source,
      skill_paths = p.skills or {},
      counts = {
        skills = M.count(p.skills),
        commands = M.count(p.commands),
        agents = M.count(p.agents),
        hooks = M.count(p.hooks),
        mcp = M.count(p.mcpServers),
        lsp = M.count(p.lspServers),
      },
    }
  end
  return m
end

-- Compatibility verdict for one plugin, from how much of it crosses over:
--   usable     pieces cluade runs natively (portable skills, commands)
--   degraded   skills that load but need a python/node runtime (limited)
--   text_only  commands/agents -- portable as text, but not wired into cluade
--   blockers   hooks / mcpServers / lspServers present (cluade can't run them)
-- Tiers: compatible / partial / limited / incompatible.
function M.plugin_verdict(usable, degraded, text_only, blockers)
  if usable == 0 and degraded == 0 and text_only == 0 then return "incompatible" end
  if usable == 0 and degraded == 0 and text_only > 0 then return "partial" end
  if usable == 0 and degraded > 0 then return "limited" end
  if blockers or degraded > 0 or text_only > 0 then return "partial" end
  return "compatible"
end

-- === filesystem / CLI (only exercised when run as a script) ===

local function sh_quote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
local function basename(p) return (p:gsub("/+$", ""):match("([^/]+)$")) or p end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local c = f:read("*a"); f:close(); return c
end

local ICON = {
  compatible = "[OK  ]", partial = "[PART]", limited = "[LTD ]", incompatible = "[ X  ]",
}

local function parts_summary(c)
  local bits = {}
  local order = { "skills", "commands", "agents", "hooks", "mcp", "lsp" }
  for _, k in ipairs(order) do
    if c[k] > 0 then bits[#bits + 1] = c[k] .. " " .. k end
  end
  return (#bits > 0) and table.concat(bits, ", ") or "no declared components"
end

function M.main(argv)
  local src = argv[1]
  if not src then
    io.write("usage: lua5.1 marketplace.lua <git-url | owner/repo | local-path>\n")
    return 1
  end
  local resolved, is_remote = skillimport.resolve_source(src)

  local root, tmp
  if is_remote then
    tmp = io.popen("mktemp -d 2>/dev/null"):read("*l")
    if not tmp then io.write("error: mktemp failed\n"); return 1 end
    io.write("cloning " .. resolved .. " ...\n")
    if os.execute("git clone --depth 1 " .. sh_quote(resolved) .. " " .. sh_quote(tmp) .. " 2>/dev/null") ~= 0 then
      io.write("error: git clone failed\n"); os.execute("rm -rf " .. sh_quote(tmp)); return 1
    end
    root = tmp
  else
    root = resolved
  end

  local raw = read_file(root .. "/.claude-plugin/marketplace.json")
  if not raw then
    io.write("error: no .claude-plugin/marketplace.json found at " .. src .. "\n")
    if tmp then os.execute("rm -rf " .. sh_quote(tmp)) end
    return 1
  end

  local okp, m = pcall(M.parse, raw)
  if not okp then
    io.write("error: could not parse marketplace.json: " .. tostring(m) .. "\n")
    if tmp then os.execute("rm -rf " .. sh_quote(tmp)) end
    return 1
  end

  io.write(string.format("\n%s  --  %d plugin(s)\n", m.name or basename(src), #m.plugins))
  if m.description then io.write("  " .. m.description .. "\n") end
  io.write("\n")

  local tally = { compatible = 0, partial = 0, limited = 0, incompatible = 0 }
  for _, p in ipairs(m.plugins) do
    -- Inspect each skill (when the source is local to the clone) to split
    -- portable from runtime-bound; otherwise fall back to declared counts.
    local usable, degraded = 0, 0
    local skill_notes = {}
    local base = (type(p.source) == "string" and not p.source:match("://"))
      and (root .. "/" .. (m.plugin_root and (m.plugin_root .. "/") or "") .. p.source) or nil
    for _, sp in ipairs(p.skill_paths) do
      local dir = base and (base:gsub("/+$", "") .. "/" .. sp:gsub("^%./", "")) or nil
      if dir and read_file(dir .. "/SKILL.md") then
        local info = skillimport.inspect(dir)
        if info.status == "limited" or info.status == "partial" then
          degraded = degraded + 1
          skill_notes[#skill_notes + 1] = info.name .. " (" .. info.status .. ")"
        else
          usable = usable + 1
        end
      else
        usable = usable + 1                       -- can't inspect; assume usable
      end
    end
    local text_only = p.counts.commands + p.counts.agents
    local blockers = (p.counts.hooks + p.counts.mcp + p.counts.lsp) > 0
    local verdict = M.plugin_verdict(usable, degraded, text_only, blockers)
    tally[verdict] = tally[verdict] + 1

    io.write(ICON[verdict] .. " " .. (p.name or "?") .. "   {" .. parts_summary(p.counts) .. "}\n")
    if p.description then io.write("        " .. p.description:sub(1, 100) .. "\n") end
    if blockers then
      local nb = {}
      if p.counts.hooks > 0 then nb[#nb + 1] = "hooks" end
      if p.counts.mcp > 0 then nb[#nb + 1] = "MCP" end
      if p.counts.lsp > 0 then nb[#nb + 1] = "LSP" end
      io.write("        ! not consumed by cluade: " .. table.concat(nb, ", ") .. "\n")
    end
    if #skill_notes > 0 then
      io.write("        ! runtime-bound skills: " .. table.concat(skill_notes, ", ") .. "\n")
    end
  end

  io.write(string.format("\nsummary: %d compatible, %d partial, %d limited, %d incompatible\n",
    tally.compatible, tally.partial, tally.limited, tally.incompatible))
  io.write("tip: import the usable skills with  lua5.1 skillimport.lua " .. src .. " --dry-run\n")
  if tmp then os.execute("rm -rf " .. sh_quote(tmp)) end
  return 0
end

if arg and arg[0] and basename(arg[0]) == "marketplace.lua" then
  os.exit(M.main(arg))
end

return M
