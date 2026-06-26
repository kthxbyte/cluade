-- Tests for dangercheck: a conservative destructive-bash-command detector.
-- match(cmd) returns a short reason string when the command looks catastrophic
-- (irreversible / system-wide), or nil otherwise. The bar is HIGH: routine
-- destructive-but-scoped commands (rm -rf ./build, dd to a file, > /dev/null)
-- must NOT trip it -- the gate must never block a valid workflow.

package.path = "./?.lua;" .. package.path
local D = require("dangercheck")

local fail = 0
local function ok(cond, msg)
  if cond then print("  ok  - " .. msg) else print("  FAIL- " .. msg); fail = fail + 1 end
end
local function flagged(cmd) return D.match(cmd) ~= nil end

-- === Should FLAG (catastrophic) ===
ok(flagged("rm -rf /"),                  "rm -rf /")
ok(flagged("rm -rf /etc"),               "rm -rf /etc")
ok(flagged("rm -fr ~"),                  "rm -fr ~ (home)")
ok(flagged("rm -rf $HOME"),              "rm -rf $HOME")
ok(flagged("rm -rf /*"),                 "rm -rf /*")
ok(flagged("rm -rf *"),                  "rm -rf * (bare wildcard)")
ok(flagged("sudo rm -rf /var/lib"),      "sudo rm -rf /var/lib")
ok(flagged("rm -r -f /usr"),             "split flags rm -r -f /usr")
ok(flagged("dd if=/dev/zero of=/dev/sda"), "dd to /dev/sda")
ok(flagged("mkfs.ext4 /dev/sda1"),       "mkfs.ext4")
ok(flagged("mkfs -t ext4 /dev/mmcblk0"), "mkfs -t")
ok(flagged("echo 1 > /dev/sda"),         "redirect to block device")
ok(flagged("cat x >/dev/mmcblk0"),       "redirect to mmc block device")
ok(flagged("shutdown -h now"),           "shutdown")
ok(flagged("reboot"),                    "reboot")
ok(flagged("halt"),                      "halt")
ok(flagged("poweroff"),                  "poweroff")
ok(flagged(":(){ :|:& };:"),             "fork bomb")

-- === Should NOT flag (routine / scoped / read-only) ===
ok(not flagged("rm -rf ./build"),        "rm -rf ./build (relative dir)")
ok(not flagged("rm -rf build/dist"),     "rm -rf relative subdir")
ok(not flagged("rm -rf /tmp/cluade-x"),  "rm -rf /tmp scratch")
ok(not flagged("rm file.txt"),           "rm without -rf")
ok(not flagged("rm -f stale.lock"),      "rm -f single file (no -r)")
ok(not flagged("ls -la /"),              "ls of /")
ok(not flagged("cat /etc/passwd"),       "reading /etc")
ok(not flagged("grep -r foo /etc"),      "grep -r in /etc")
ok(not flagged("dd if=/dev/zero of=/tmp/img bs=1M count=10"), "dd to a file (not device)")
ok(not flagged("echo hi > /dev/null"),   "redirect to /dev/null")
ok(not flagged("echo rebooting the box"),"'rebooting' substring, not the command")
ok(not flagged("mkfsobject --help"),     "mkfs-prefixed word, not mkfs")
ok(not flagged("git status"),            "ordinary command")

-- === Reason is a short non-empty string when flagged ===
do
  local r = D.match("rm -rf /")
  ok(type(r) == "string" and #r > 0, "reason is a non-empty string")
end

-- === Agent._effective_perm: the smart gate escalates only allowed bash ===
local Agent = require("agent")
local function eff(base, name, cmd)
  return Agent._effective_perm(base, name, cmd and { command = cmd } or {})
end
do
  local p, r = eff("allow", "bash", "rm -rf /")
  ok(p == "ask" and type(r) == "string", "allowed dangerous bash -> ask, with reason")

  ok(select(1, eff("allow", "bash", "ls -la")) == "allow", "allowed safe bash stays allow")
  ok(select(2, eff("allow", "bash", "ls -la")) == nil, "safe bash has no reason")

  -- A tool already gated to ask/deny is never changed (and never downgraded).
  ok(select(1, eff("ask", "bash", "ls")) == "ask", "ask stays ask")
  ok(select(1, eff("deny", "bash", "rm -rf /")) == "deny", "deny is not downgraded by the gate")

  -- Only bash is gated; other tools pass through.
  ok(select(1, eff("allow", "write", "rm -rf /")) == "allow", "non-bash tools are not danger-gated")

  -- Missing command is harmless.
  ok(select(1, Agent._effective_perm("allow", "bash", {})) == "allow", "bash without a command stays allow")
end

if fail == 0 then print("\nALL PASS") else print("\n" .. fail .. " FAILED"); os.exit(1) end
