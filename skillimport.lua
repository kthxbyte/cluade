-- skillimport.lua -- import Agent Skills (Anthropic SKILL.md format) from a git
-- repo or local path into cluade's ~/.cluade/skills, and report up front which
-- skills cluade can fully run.
--
-- A skill's `allowed-tools` frontmatter (the Agent Skills metadata field) is the
-- best available signal of which tools it touches. We map those onto cluade's
-- tool set: all known -> "full", some unknown -> "partial" (tools listed), none
-- declared -> "unknown" (can't verify from metadata, import at your discretion).
--
-- Usage:  lua5.1 skillimport.lua <git-url|local-path> [--dry-run] [--force]
--                                                     [--link] [--dest DIR]
--   --dry-run  report only; copy nothing
--   --force    overwrite a skill of the same name already installed
--   --link     symlink instead of copy (local sources only; updates propagate)
--   --dest DIR target skills dir (default: ~/.cluade/skills)

local M = {}

-- cluade's tool set, keyed by normalized name. Claude tool names (Read, Bash,
-- WebSearch, MultiEdit, ...) map onto their cluade equivalents.
M.SUPPORTED = {
  read = "read", write = "write", edit = "edit", multiedit = "edit",
  bash = "bash", glob = "glob", grep = "grep",
  websearch = "web_search", webfetch = "web_fetch",
  remotebash = "remote_bash", compact = "compact", skill = "skill",
}

-- Casing/separator-insensitive: "WebSearch", "web_search", "web-search" all match.
function M.normalize(name)
  return tostring(name):lower():gsub("[^%w]", "")
end

-- Classify a raw `allowed-tools` value against cluade's tools.
-- Returns { status = "full"|"partial"|"unknown", supported = {}, unsupported = {}, has_mcp = bool }.
function M.classify(raw)
  if raw == nil or raw:gsub("%s", "") == "" then
    return { status = "unknown", supported = {}, unsupported = {}, has_mcp = false }
  end
  local supported, unsupported, has_mcp = {}, {}, false
  local cleaned = raw:gsub("[%[%]]", " ")              -- drop YAML inline-list brackets
  for tok in cleaned:gmatch("[^%s,]+") do
    if tok ~= "-" then
      if tok:match("^[Mm][Cc][Pp]") then has_mcp = true end
      if M.SUPPORTED[M.normalize(tok)] then
        supported[#supported + 1] = tok
      else
        unsupported[#unsupported + 1] = tok
      end
    end
  end
  local status = (#unsupported == 0) and "full" or "partial"
  return { status = status, supported = supported, unsupported = unsupported, has_mcp = has_mcp }
end

-- Minimal YAML frontmatter reader: scalars plus multiline "- item" lists (which
-- are joined comma-separated so classify() can split them uniformly).
function M.parse_skill(content)
  local fm = {}
  if not content:match("^%-%-%-") then return fm end
  local _, body_start = content:find("\n%-%-%-")        -- end of the frontmatter block
  local fm_str = content:sub(4, (body_start or #content) - 3)
  local lines = {}
  for line in (fm_str .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  local i = 1
  while i <= #lines do
    local key, val = lines[i]:match("^([%w_-]+):%s*(.*)$")
    if key then
      if val == "" then
        local items, j = {}, i + 1
        while lines[j] and lines[j]:match("^%s*-%s+") do
          items[#items + 1] = lines[j]:match("^%s*-%s+(.+)$")
          j = j + 1
        end
        if #items > 0 then fm[key] = table.concat(items, ", "); i = j - 1 else fm[key] = "" end
      else
        fm[key] = val:gsub('^["\']', ""):gsub('["\']$', "")
      end
    end
    i = i + 1
  end
  return fm
end

-- Final verdict for a skill, folding the tool axis (classify) together with the
-- runtime-dependency axis. In practice `allowed-tools` is almost never declared,
-- so a dependency-free skill is reported as "portable" rather than an
-- unactionable "unknown"; bundled scripts / plugin.json are a hard blocker on a
-- constrained device and outweigh tool support entirely.
--   full     declared, every tool supported, no runtime deps
--   partial  declared, some tools unsupported, no runtime deps
--   portable undeclared tools, but no runtime deps (pure-instruction skill)
--   limited  bundles python/node scripts or a plugin.json the device can't run
function M.verdict(cls, has_scripts, has_plugin)
  if has_scripts or has_plugin then return "limited" end
  if cls.status == "unknown" then return "portable" end
  return cls.status                                   -- "full" or "partial"
end

-- === filesystem / CLI (only exercised when run as a script) ===

local function sh_quote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

local function popen_lines(cmd)
  local out = {}
  local f = io.popen(cmd)
  if f then for l in f:lines() do out[#out + 1] = l end; f:close() end
  return out
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local c = f:read("*a"); f:close(); return c
end

local function exists(path)
  local f = io.open(path, "r")
  if f then f:close(); return true end
  return false
end

local function basename(p) return (p:gsub("/+$", ""):match("([^/]+)$")) or p end
local function dirname(p) return (p:match("^(.*)/[^/]+/?$")) or "." end

local function is_git_url(s)
  return s:match("://") ~= nil or s:match("^git@") ~= nil or s:match("%.git$") ~= nil
end

function M.find_skill_dirs(root)
  local dirs = {}
  for _, md in ipairs(popen_lines("find " .. sh_quote(root) .. " -name SKILL.md 2>/dev/null")) do
    dirs[#dirs + 1] = dirname(md)
  end
  table.sort(dirs)
  return dirs
end

-- Inspect one skill dir: name, classification, and dependency warnings.
function M.inspect(skill_dir)
  local content = read_file(skill_dir .. "/SKILL.md") or ""
  local fm = M.parse_skill(content)
  local cls = M.classify(fm["allowed-tools"])
  local has_plugin = exists(skill_dir .. "/.claude-plugin/plugin.json")
  local has_scripts = #popen_lines("find " .. sh_quote(skill_dir)
    .. " \\( -name '*.py' -o -name '*.js' -o -name '*.ts' -o -name '*.mjs' \\) 2>/dev/null") > 0
  local warnings = {}
  if has_plugin then
    warnings[#warnings + 1] = "bundles agents/hooks/MCP (plugin.json) -- not consumed by cluade"
  end
  if has_scripts then
    warnings[#warnings + 1] = "bundles scripts (python/node) -- may not run on a constrained device"
  end
  return {
    name = fm.name or basename(skill_dir),
    description = fm.description,
    dir = skill_dir,
    cls = cls,
    status = M.verdict(cls, has_scripts, has_plugin),
    warnings = warnings,
  }
end

local ICON = { full = "[OK  ]", portable = "[OK* ]", partial = "[PART]", limited = "[LTD ]" }

local function report(info)
  io.write(ICON[info.status] .. " " .. info.name)
  if info.status == "partial" then
    io.write("  unsupported: " .. table.concat(info.cls.unsupported, ", "))
  elseif info.status == "portable" then
    io.write("  (pure instructions; no tool/runtime deps)")
  end
  io.write("\n")
  for _, w in ipairs(info.warnings) do io.write("        ! " .. w .. "\n") end
end

function M.main(argv)
  local source, dest, dry_run, force, link
  local i = 1
  while i <= #argv do
    local a = argv[i]
    if a == "--dry-run" then dry_run = true
    elseif a == "--force" then force = true
    elseif a == "--link" then link = true
    elseif a == "--dest" then i = i + 1; dest = argv[i]
    elseif a:sub(1, 1) ~= "-" then source = a end
    i = i + 1
  end
  if not source then
    io.write("usage: lua5.1 skillimport.lua <git-url|local-path> [--dry-run] [--force] [--link] [--dest DIR]\n")
    return 1
  end
  local home = os.getenv("HOME") or os.getenv("USERPROFILE") or "/tmp"
  dest = dest or (home .. "/.cluade/skills")

  -- Resolve the source to a local root, cloning a git URL into a temp dir.
  local root, tmp
  if is_git_url(source) then
    tmp = popen_lines("mktemp -d 2>/dev/null")[1]
    if not tmp then io.write("error: mktemp failed\n"); return 1 end
    io.write("cloning " .. source .. " ...\n")
    if os.execute("git clone --depth 1 " .. sh_quote(source) .. " " .. sh_quote(tmp) .. " 2>/dev/null") ~= 0 then
      io.write("error: git clone failed\n"); os.execute("rm -rf " .. sh_quote(tmp)); return 1
    end
    root = tmp
    if link then io.write("note: --link ignored for a git source (cloned to a temp dir)\n"); link = false end
  else
    root = source
    if not exists(root) then io.write("error: path not found: " .. root .. "\n"); return 1 end
  end

  local skills = M.find_skill_dirs(root)
  if #skills == 0 then
    io.write("no SKILL.md found under " .. source .. "\n")
    if tmp then os.execute("rm -rf " .. sh_quote(tmp)) end
    return 1
  end

  io.write(string.format("found %d skill(s)%s:\n", #skills, dry_run and " (dry run)" or ""))
  local count = { full = 0, portable = 0, partial = 0, limited = 0 }
  local n_imported, n_skipped = 0, 0
  for _, sd in ipairs(skills) do
    local info = M.inspect(sd)
    report(info)
    count[info.status] = count[info.status] + 1

    if not dry_run then
      local target = dest .. "/" .. info.name
      if exists(target) and not force then
        io.write("        -> skip (already installed; use --force)\n"); n_skipped = n_skipped + 1
      else
        os.execute("mkdir -p " .. sh_quote(dest) .. " 2>/dev/null")
        os.execute("rm -rf " .. sh_quote(target) .. " 2>/dev/null")
        local cmd = link
          and ("ln -s " .. sh_quote(info.dir) .. " " .. sh_quote(target))
          or ("cp -r " .. sh_quote(info.dir) .. " " .. sh_quote(target))
        if os.execute(cmd .. " 2>/dev/null") == 0 then
          io.write("        -> " .. (link and "linked" or "imported") .. " to " .. target .. "\n")
          n_imported = n_imported + 1
        else
          io.write("        -> FAILED to install\n")
        end
      end
    end
  end

  io.write(string.format("\nsummary: %d full, %d portable, %d partial, %d limited",
    count.full, count.portable, count.partial, count.limited))
  if not dry_run then io.write(string.format("  |  %d imported, %d skipped", n_imported, n_skipped)) end
  io.write("\n")
  if count.partial > 0 or count.limited > 0 then
    io.write("note: partial = reaches for unsupported tools; limited = bundles a python/node/plugin runtime the device may lack.\n")
  end
  if tmp then os.execute("rm -rf " .. sh_quote(tmp)) end
  return 0
end

-- Run as a script (not when required by a test).
if arg and arg[0] and basename(arg[0]) == "skillimport.lua" then
  os.exit(M.main(arg))
end

return M
