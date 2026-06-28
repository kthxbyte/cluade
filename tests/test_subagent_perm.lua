-- Tests the permission rule for unattended --subagent mode. The single rule:
-- with no human to approve, anything that would have been "ask" becomes "deny";
-- "allow" stays "allow"; and a dangercheck escalation (which is an "ask" in
-- normal mode) becomes a hard "deny". The knife still cuts -- write/edit and
-- ordinary bash stay allowed -- only the catastrophic set and would-be prompts
-- are refused.

package.path = "./?.lua;./?/init.lua;" .. package.path
local Agent = require("agent")

local fail = 0
local function ok(cond, msg)
  if cond then print("  ok  - " .. msg) else print("  FAIL- " .. msg); fail = fail + 1 end
end
local function perm(...) return (select(1, Agent._effective_perm(...))) end

-- Normal (attended) mode is unchanged.
do
  ok(perm("allow", "bash", { command = "ls -la" }) == "allow", "normal: safe bash allowed")
  ok(perm("allow", "bash", { command = "rm -rf /" }) == "ask", "normal: catastrophic bash -> ask (prompt)")
  ok(perm("ask", "remote_bash", {}) == "ask", "normal: remote_bash stays ask")
  ok(perm("allow", "write", {}) == "allow", "normal: write allowed")
end

-- Subagent (unattended) mode: 4th arg true.
do
  ok(perm("allow", "bash", { command = "ls -la" }, true) == "allow", "subagent: safe bash still allowed (knife cuts)")
  ok(perm("allow", "write", {}, true) == "allow", "subagent: write still allowed")
  ok(perm("allow", "edit", {}, true) == "allow", "subagent: edit still allowed")
  ok(perm("allow", "bash", { command = "rm -rf ./build" }, true) == "allow", "subagent: ordinary rm of a subdir allowed")
  ok(perm("allow", "bash", { command = "rm -rf /" }, true) == "deny", "subagent: catastrophic bash -> deny (no human)")
  ok(perm("ask", "remote_bash", {}, true) == "deny", "subagent: would-be-ask remote_bash -> deny")
  ok(perm("deny", "bash", { command = "ls" }, true) == "deny", "subagent: explicit deny stays deny")
end

if fail == 0 then print("\nALL PASS") else print("\n" .. fail .. " FAILED"); os.exit(1) end
