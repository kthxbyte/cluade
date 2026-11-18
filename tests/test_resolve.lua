-- Tests for host-drift resolution (hostprobe.resolve) and config persistence
-- (Store.save_config). resolve decides generate/ok/regenerate/drift from a probe
-- against the stored fingerprint; save_config writes only the config whitelist,
-- never runtime-only flags.

package.path = "./?.lua;./?/init.lua;" .. package.path
local hostprobe = require("hostprobe")
local Store = require("store")
local json = require("vendor.json")

local fail = 0
local function ok(cond, msg)
  if cond then print("  ok  - " .. msg) else print("  FAIL- " .. msg); fail = fail + 1 end
end

local pr = { os = "Linux", arch = "x86_64", shell = "dash", bash = true, python = "/p" }

-- 1. generated when no prompt/host yet.
local cfg = {}
ok(select(1, hostprobe.resolve(cfg, pr, nil)) == "generated", "no prompt/host -> generated")
ok(type(cfg.system_prompt) == "string" and cfg.host.os == "Linux",
  "generated populates system_prompt and host")

-- 2. ok when host matches; a hand-edited prompt is left intact.
cfg.system_prompt = "HAND EDITED"
ok(select(1, hostprobe.resolve(cfg, pr, nil)) == "ok", "matching host -> ok")
ok(cfg.system_prompt == "HAND EDITED", "ok leaves hand-edited prompt untouched")

-- 3. old config (prompt present, host absent) -> generated (upgrade path).
local old = { system_prompt = "x" }
ok(select(1, hostprobe.resolve(old, pr, nil)) == "generated", "prompt but no host -> generated")

-- 4. drift + interactive yes -> regenerated.
local pr2 = { os = "Linux", arch = "mips", shell = "busybox", bash = false, python = false }
ok(select(1, hostprobe.resolve(cfg, pr2, function() return true end)) == "regenerated",
  "drift + yes -> regenerated")
ok(cfg.host.arch == "mips" and cfg.system_prompt ~= "HAND EDITED",
  "regenerate updates host and rewrites prompt")

-- 5. drift + interactive no -> drift, unchanged.
cfg.system_prompt = "KEEP"; cfg.host = hostprobe.fingerprint(pr2)
ok(select(1, hostprobe.resolve(cfg, pr, function() return false end)) == "drift",
  "drift + no -> drift")
ok(cfg.system_prompt == "KEEP", "declined regenerate keeps the stored prompt")

-- 6. drift + non-interactive (ask_fn nil) -> drift, no mutation.
ok(select(1, hostprobe.resolve(cfg, pr, nil)) == "drift", "drift + no asker -> drift")
ok(cfg.system_prompt == "KEEP", "non-interactive drift mutates nothing")

-- 7. save_config persists the whitelist and drops runtime-only flags.
local home = os.tmpname(); os.remove(home); os.execute("mkdir -p '" .. home .. "'")
Store.save_config(home, {
  model = "m", api_key = "k", system_prompt = "P", host = { os = "Linux" },
  quiet = true, sessions_dir = "/x", subagent = true,
})
local f = io.open(home .. "/.cluade/config.json"); local raw = f:read("*a"); f:close()
local back = json.decode(raw)
ok(back.system_prompt == "P" and back.model == "m" and back.host.os == "Linux",
  "save_config persists whitelist keys")
ok(back.quiet == nil and back.sessions_dir == nil and back.subagent == nil,
  "save_config drops runtime-only flags")
os.execute("rm -rf '" .. home .. "'")

if fail == 0 then print("\nALL PASS") else print("\n" .. fail .. " FAILED"); os.exit(1) end
