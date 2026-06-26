-- Conservative detector for catastrophic shell commands.
--
-- Philosophy: protect against irreversible, system-wide mistakes WITHOUT
-- babysitting the operator. The bar is high on purpose -- prefer false negatives
-- to false positives, so routine destructive-but-scoped work (rm -rf ./build,
-- dd to a file, > /dev/null) is never flagged. This is a guard against the model
-- erring on an irreversible action, not an adversarial sandbox.
--
-- match(cmd) -> reason string (short) if the command looks catastrophic, else nil.

local Danger = {}

-- System/root/home locations whose recursive removal is catastrophic. A relative
-- path (build/, ./dist) or scratch path (/tmp/...) is intentionally NOT here.
local DANGER_PREFIXES = {
  "/", "/etc", "/usr", "/bin", "/sbin", "/lib", "/lib64", "/boot", "/root",
  "/home", "/var", "/dev", "/sys", "/proc", "/opt", "/srv",
}

-- Block-device node prefixes -- writing to these destroys a disk/partition.
local BLOCK_DEVS = { "sd", "mmcblk", "nvme", "hd", "vd" }

local function has_word(cmd, word)
  return cmd:match("%f[%w]" .. word .. "%f[%W]") ~= nil
end

-- Strip surrounding quotes from a token.
local function unquote(tok)
  return (tok:gsub("^['\"]", ""):gsub("['\"]$", ""))
end

-- Is this an rm invocation with BOTH recursive and force flags?
local function rm_recursive_force(cmd)
  if not has_word(cmd, "rm") then return false end
  local recursive, force = false, false
  for flag in cmd:gmatch("%-%-?[%w-]+") do
    local f = flag:lower()
    if f == "--recursive" or f:match("^%-[%a]*r[%a]*$") then recursive = true end
    if f == "--force" or f:match("^%-[%a]*f[%a]*$") then force = true end
  end
  return recursive and force
end

-- Does a token name a catastrophic removal target?
local function dangerous_target(tok)
  tok = unquote(tok)
  if tok == "*" or tok == "." or tok == ".." or tok == "~" then return true end
  if tok:match("^~/") then return true end
  if tok:match("^%$HOME") then return true end
  for _, p in ipairs(DANGER_PREFIXES) do
    if tok == p or tok == p .. "*" or tok:sub(1, #p + 1) == p .. "/" then return true end
  end
  return false
end

local function rm_targets_danger(cmd)
  for tok in cmd:gmatch("%S+") do
    if tok:sub(1, 1) ~= "-" and dangerous_target(tok) then return true end
  end
  return false
end

function Danger.match(cmd)
  if type(cmd) ~= "string" then return nil end

  -- Fork bomb: :(){ :|:& };: (compare with whitespace removed).
  local squished = cmd:gsub("%s", "")
  if squished:find(":(){", 1, true) and squished:find(":|:", 1, true) then
    return "fork bomb"
  end

  -- mkfs: format a filesystem (matches `mkfs` and `mkfs.ext4`, not `mkfsobject`).
  if has_word(cmd, "mkfs") then
    return "filesystem format (mkfs)"
  end

  -- dd writing to a device node.
  if has_word(cmd, "dd") and cmd:match("of=[\"']?/dev/") then
    return "dd write to a device"
  end

  -- Redirect onto a raw block device.
  for _, dev in ipairs(BLOCK_DEVS) do
    if cmd:match(">%s*[\"']?/dev/" .. dev) then
      return "write to block device /dev/" .. dev
    end
  end

  -- Power state changes.
  for _, w in ipairs({ "shutdown", "reboot", "halt", "poweroff" }) do
    if has_word(cmd, w) then return "power-off/reboot (" .. w .. ")" end
  end

  -- Recursive force-remove of a system/root/home path.
  if rm_recursive_force(cmd) and rm_targets_danger(cmd) then
    return "recursive force-remove of a sensitive path"
  end

  return nil
end

return Danger
