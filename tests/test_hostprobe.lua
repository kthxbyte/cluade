-- Tests for hostprobe: probing the host, building a fitted system prompt, and
-- fingerprinting for drift detection. The shell-command seam (_run) is injected
-- so the probe is deterministic and never shells out during tests.

package.path = "./?.lua;./?/init.lua;" .. package.path
local hostprobe = require("hostprobe")

local fail = 0
local function ok(cond, msg)
  if cond then print("  ok  - " .. msg) else print("  FAIL- " .. msg); fail = fail + 1 end
end

-- Build a fake _run mapping exact command strings to canned stdout.
local function fake(map)
  return function(cmd) return map[cmd] or "" end
end

-- 1. probe() parses injected command output.
hostprobe._run = fake({
  ["uname -s"] = "Linux",
  ["uname -m"] = "x86_64",
  ["readlink -f /bin/sh"] = "/usr/bin/dash",
  ["command -v bash"] = "/bin/bash",
  ["command -v python3"] = "/usr/bin/python3",
})
local p = hostprobe.probe()
ok(p.os == "Linux", "probe os")
ok(p.arch == "x86_64", "probe arch")
ok(p.shell == "dash", "probe shell is the basename of /bin/sh target")
ok(p.bash == true, "probe detects bash on PATH")
ok(p.python == "/usr/bin/python3", "probe detects python3 path")

-- 2. Missing commands degrade to fallbacks, never error.
hostprobe._run = function() return "" end
local q = hostprobe.probe()
ok(q.os == "unknown", "missing uname -> os unknown")
ok(q.arch == "unknown", "missing uname -> arch unknown")
ok(q.shell == "sh", "missing readlink -> shell sh")
ok(q.bash == false, "no bash -> false")
ok(q.python == false, "no python -> false")
ok(type(hostprobe.build_prompt(q)) == "string", "build_prompt never errors on sparse probe")

-- 3. Environment wording reflects the facts.
ok(hostprobe.environment_section(p):find("python", 1, true) ~= nil,
  "environment names python when present")
ok(hostprobe.environment_section(q):lower():find("python is not") ~= nil,
  "environment says python is not available when absent")
ok(hostprobe.build_prompt(p):find(hostprobe.BASE, 1, true) == 1,
  "build_prompt starts with BASE")
ok(hostprobe.BASE:lower():find("openwrt") == nil and hostprobe.BASE:lower():find("busybox") == nil,
  "BASE carries no hardcoded host claims")

-- 4. fingerprint + differs.
local a = hostprobe.fingerprint(p)
ok(a.python == true, "fingerprint reduces python to a boolean")
ok(a.os == "Linux" and a.arch == "x86_64" and a.shell == "dash", "fingerprint keeps os/arch/shell")
ok(hostprobe.differs(a, hostprobe.fingerprint(q)) == true, "differs: distinct hosts differ")
ok(hostprobe.differs(a, a) == false, "differs: identical fingerprint does not differ")

if fail == 0 then print("\nALL PASS") else print("\n" .. fail .. " FAILED"); os.exit(1) end
