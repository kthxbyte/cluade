# Adaptive System Prompt Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace cluade's hardcoded (and often false) environment claims with a host-fitted system prompt stored in `config.json`, regenerated on consent when the host drifts.

**Architecture:** A new pure module `hostprobe.lua` probes the host, builds a fitted prompt, and compares host fingerprints. `cluade.lua` runs a first-run/drift resolution at boot (prompt-to-regenerate on drift, warn-only when non-interactive) and persists via a new `Store.save_config`. `agent.lua` consumes `config.system_prompt`, falling back to a claim-free static base.

**Tech Stack:** Lua 5.1, busybox/ash-safe shell probes (`uname`, `command -v`, `readlink`), vendored JSON.

**Spec:** `docs/superpowers/specs/2026-11-17-adaptive-system-prompt-design.md`

## Global Constraints

- Lua 5.1 only; probe commands must exist in busybox (`uname`, `command -v`, `readlink`).
- Probes degrade gracefully: a missing command yields `"unknown"`/`false`, never an error.
- `--subagent`/`--quiet`/non-tty runs: never prompt, never write files on drift, and emit all notices to **stderr** (stdout stays the clean final answer).
- `Store.save_config` persists only the config whitelist; never runtime-only flags (`quiet`, `subagent`, `ephemeral`, `sessions_dir`, `show_tools_json`, `plan`).
- Keep modules single-purpose in the existing `loopdetect`/`dangercheck` style; tests use injected seams, no live network.

## Review Focus

- **Probe command missing** (`uname`/`readlink`/`command -v` absent): `probe()` returns `"unknown"`/`false` and `build_prompt` still produces a valid prompt → Task 1 test.
- **Non-interactive drift** (`--subagent`): `resolve` with `ask_fn = nil` returns `"drift"`, mutates nothing, writes nothing → Task 2 test.
- **Old config, `system_prompt` present but `host` absent**: treated as `"generated"` (upgrade), not `"drift"` → Task 2 test.
- **save_config leaks runtime flags**: a config carrying `quiet=true`/`sessions_dir=...` must round-trip to a file without those keys → Task 2 test.
- **Hand-edited prompt, host unchanged**: `resolve` returns `"ok"` and leaves `config.system_prompt` byte-for-byte intact → Task 2 test.

---

### Task 1: `hostprobe.lua` — probe, prompt, fingerprint

**Files:**
- Create: `hostprobe.lua`
- Test: `tests/test_hostprobe.lua`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `hostprobe.BASE` (string) — role + communication guidance, **no** environment claims.
  - `hostprobe._run(cmd) -> string` — trimmed stdout of a shell command; test seam (overridable).
  - `hostprobe.probe() -> { os, arch, shell, bash, python }` where `os`/`arch`/`shell` are strings (fallback `"unknown"`/`"sh"`), `bash` is boolean, `python` is the interpreter path string or `false`.
  - `hostprobe.environment_section(probe) -> string`
  - `hostprobe.build_prompt(probe) -> string` (`BASE .. "\n\n" .. environment_section(probe)`)
  - `hostprobe.fingerprint(probe) -> { os, arch, shell, python = boolean }`
  - `hostprobe.differs(a, b) -> boolean`

- [ ] **Step 1: Write the failing test** `tests/test_hostprobe.lua`

```lua
-- probe parsing via injected _run
hostprobe._run = fake({ ["uname -s"]="Linux", ["uname -m"]="x86_64",
  ["readlink -f /bin/sh"]="/usr/bin/dash", ["command -v bash"]="/bin/bash",
  ["command -v python3"]="/usr/bin/python3" })
local p = hostprobe.probe()
assert(p.os=="Linux" and p.arch=="x86_64" and p.shell=="dash")
assert(p.bash==true and p.python=="/usr/bin/python3")

-- missing commands degrade, never error
hostprobe._run = function() return "" end
local q = hostprobe.probe()
assert(q.os=="unknown" and q.shell=="sh" and q.bash==false and q.python==false)
assert(type(hostprobe.build_prompt(q))=="string")

-- environment wording reflects facts
assert(hostprobe.environment_section(p):find("python", 1, true))
assert(hostprobe.environment_section(q):lower():find("python is not"))
assert(hostprobe.build_prompt(p):find(hostprobe.BASE, 1, true) == 1)

-- fingerprint + drift
local a = hostprobe.fingerprint(p)
assert(a.python==true)
assert(hostprobe.differs(a, hostprobe.fingerprint(q)) == true)
assert(hostprobe.differs(a, a) == false)
```

(`fake` is a small local helper mapping exact command strings to canned output; `probe()` must call `_run` with stable command strings matching those keys, trying `command -v python3` then `command -v python`.)

- [ ] **Step 2: Run test to verify it fails**

Run: `lua5.1 tests/test_hostprobe.lua`
Expected: FAIL (`module 'hostprobe' not found`).

- [ ] **Step 3: Implement `hostprobe.lua`**

`BASE` = role line + the three Communication bullets from the current `agent.lua` `SYSTEM_PROMPT` (drop every Environment bullet). `environment_section` emits an `Environment:` block: OS/arch line; shell line naming `/bin/sh`'s flavor and advising POSIX sh syntax (add "bash is available." when `probe.bash`); a busybox-applets line when `shell=="busybox"`; a Python line that is either "`<path>` is available." or "Python is not available; do not use Python."; and "Use /tmp for temporary files." `_run` wraps `io.popen(cmd.." 2>/dev/null")`, reads all, trims trailing whitespace. `probe` calls `_run` with the exact command strings the test keys use. `differs` compares `os`,`arch`,`shell`,`python`.

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.1 tests/test_hostprobe.lua`
Expected: `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add hostprobe.lua tests/test_hostprobe.lua
git commit -m "feat: add hostprobe (probe host, build fitted prompt, fingerprint)"
```

---

### Task 2: Resolution + persistence (`hostprobe.resolve`, `Store.save_config`)

**Files:**
- Modify: `hostprobe.lua` (add `resolve`)
- Modify: `store.lua` (add `Store.save_config`)
- Test: `tests/test_resolve.lua`

**Interfaces:**
- Consumes: `hostprobe.build_prompt`, `.fingerprint`, `.differs` (Task 1).
- Produces:
  - `hostprobe.resolve(config, probe, ask_fn) -> action, message` where `action` ∈ `"generated" | "ok" | "regenerated" | "drift"`. Mutates `config.system_prompt` and `config.host` on `"generated"`/`"regenerated"`. `ask_fn` is `function(question) -> boolean` or `nil` (non-interactive). `message` is a human string for every action except `"ok"` (`nil`).
  - `Store.save_config(home, config) -> ok, err` — writes the whitelist to `home .. "/.cluade/config.json"`.

- [ ] **Step 1: Write the failing test** `tests/test_resolve.lua`

```lua
-- generated when no prompt/host yet
local cfg = {}
local pr = { os="Linux", arch="x86_64", shell="dash", bash=true, python="/p" }
assert(select(1, hostprobe.resolve(cfg, pr, nil)) == "generated")
assert(type(cfg.system_prompt)=="string" and cfg.host.os=="Linux")

-- ok when host matches (prompt left untouched, even if hand-edited)
cfg.system_prompt = "HAND EDITED"
assert(select(1, hostprobe.resolve(cfg, pr, nil)) == "ok")
assert(cfg.system_prompt == "HAND EDITED")

-- old config: prompt present, host absent -> generated (upgrade)
local old = { system_prompt = "x" }
assert(select(1, hostprobe.resolve(old, pr, nil)) == "generated")

-- drift + interactive yes -> regenerated
local pr2 = { os="Linux", arch="mips", shell="busybox", bash=false, python=false }
assert(select(1, hostprobe.resolve(cfg, pr2, function() return true end)) == "regenerated")
assert(cfg.host.arch == "mips" and cfg.system_prompt ~= "HAND EDITED")

-- drift + interactive no -> drift, unchanged
cfg.system_prompt = "KEEP"; cfg.host = hostprobe.fingerprint(pr2)
assert(select(1, hostprobe.resolve(cfg, pr, function() return false end)) == "drift")
assert(cfg.system_prompt == "KEEP")

-- drift + non-interactive (ask_fn nil) -> drift, no mutation
assert(select(1, hostprobe.resolve(cfg, pr, nil)) == "drift")
assert(cfg.system_prompt == "KEEP")

-- save_config persists the whitelist, drops runtime flags
local home = os.tmpname(); os.remove(home); os.execute("mkdir -p '"..home.."'")
Store.save_config(home, { model="m", api_key="k", system_prompt="P",
  host={os="Linux"}, quiet=true, sessions_dir="/x", subagent=true })
local raw = io.open(home.."/.cluade/config.json"):read("*a")
local back = require("vendor.json").decode(raw)
assert(back.system_prompt=="P" and back.model=="m" and back.host.os=="Linux")
assert(back.quiet==nil and back.sessions_dir==nil and back.subagent==nil)
```

(Read the file directly — Lua 5.1 has no `os.setenv`, so the test passes `home` explicitly to `save_config` and does not go through `load_config`'s `HOME`-based path.)

- [ ] **Step 2: Run test to verify it fails**

Run: `lua5.1 tests/test_resolve.lua`
Expected: FAIL (`attempt to call ... 'resolve'`/`'save_config'`).

- [ ] **Step 3: Implement `resolve` and `save_config`**

`resolve`: if `not config.system_prompt or not config.host` → set both from `probe`, return `"generated", <os/arch>`. Else if `not differs(config.host, fingerprint(probe))` → `"ok", nil`. Else build `old = cfg.host.os.."/"..cfg.host.arch`, `new = probe.os.."/"..probe.arch`; if `ask_fn` and `ask_fn("host changed ("..old.." -> "..new.."); regenerate system prompt? [y/N]")` → set both, return `"regenerated", old.." -> "..new`; else `"drift", old.." -> "..new`. `save_config`: whitelist = `{base_url, model, api_key, max_steps, max_tokens, request_timeout, context_limit, compact_threshold, permissions, system_prompt, host}`; copy present keys into a fresh table; `mkdir -p` and `json.encode` to `home.."/.cluade/config.json"`.

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.1 tests/test_resolve.lua`
Expected: `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add hostprobe.lua store.lua tests/test_resolve.lua
git commit -m "feat: host-drift resolution and config persistence"
```

---

### Task 3: Agent wiring — consume `config.system_prompt`, drop false claims

**Files:**
- Modify: `agent.lua:123` (replace `SYSTEM_PROMPT` constant), `agent.lua:309`, `agent.lua:448`
- Modify: `tools.lua:148` (bash tool description → host-neutral)
- Test: existing `tests/test_system_message.lua`, `tests/test_compact_context.lua` (must stay green)

**Interfaces:**
- Consumes: `hostprobe.BASE` (Task 1).
- Produces: agent uses `self.config.system_prompt or SYSTEM_PROMPT` for both the initial system message and the compaction rebuild.

- [ ] **Step 1: Make the change**

Replace the `local SYSTEM_PROMPT = [[...]]` block with `local SYSTEM_PROMPT = require("hostprobe").BASE`. At `agent.lua:309` use `self.config.system_prompt or SYSTEM_PROMPT`; at `agent.lua:448` set `local base = self.config.system_prompt or SYSTEM_PROMPT` and build `compact_msg` from `base`. Change `tools.lua:148` description to `"Execute a shell command via the system shell (/bin/sh). Prefer POSIX sh-compatible syntax."`.

- [ ] **Step 2: Run the affected tests**

Run: `lua5.1 tests/test_system_message.lua && lua5.1 tests/test_compact_context.lua`
Expected: both `ALL PASS` (they set no `config.system_prompt`, so they exercise the `SYSTEM_PROMPT` fallback; they assert the CLAUDE.md marker count and summary, not prompt wording).

- [ ] **Step 3: Run the whole suite**

Run: `./run_tests.sh`
Expected: all tests `PASS`.

- [ ] **Step 4: Commit**

```bash
git add agent.lua tools.lua
git commit -m "refactor: agent uses config.system_prompt; remove hardcoded host claims"
```

---

### Task 4: Boot orchestration — first-run create, drift prompt, `--init`

**Files:**
- Modify: `cluade.lua` (add `require("hostprobe")`; resolution block before `Agent:init`; update the `--init` block at `cluade.lua:193-209`)
- Test: `tests/test_resolve.lua` covers the logic; this task adds an end-to-end manual verification.

**Interfaces:**
- Consumes: `hostprobe.probe`/`resolve` (Tasks 1–2), `Store.save_config` (Task 2), `Agent.prompt_yes_no` (existing).

- [ ] **Step 1: Wire resolution into `main`**

After the `--quiet`/`--no-session` flag handling (`cluade.lua:189`) and before `Agent:init`, add: compute `interactive = os.execute("test -t 0 2>/dev/null")==0 and not config.quiet and not config.subagent`; `ask_fn = interactive and function(q) return Agent.prompt_yes_no(Agent, q) end or nil`; `local action, msg = hostprobe.resolve(config, hostprobe.probe(), ask_fn)`; `local emit = config.quiet and function(s) io.stderr:write(s.."\n") end or function(s) print(s) end`. On `"generated"`: `Store.save_config(home, config)` then `emit("created "..home.."/.cluade/config.json (add your api_key)")`. On `"regenerated"`: `Store.save_config(home, config)` then `emit("regenerated system prompt ("..msg..")")`. On `"drift"`: `emit("note: host changed ("..msg.."); run --init to regenerate the system prompt")`. On `"ok"`: nothing.

- [ ] **Step 2: Update `--init`**

In the `args.init` block, compute `local pr = hostprobe.probe()`, set `config.system_prompt = hostprobe.build_prompt(pr)` and `config.host = hostprobe.fingerprint(pr)`, write with `Store.save_config(os.getenv("HOME"), config)`, print the path, `os.exit(0)`.

- [ ] **Step 3: Manual end-to-end verification**

Run (fresh config in a throwaway HOME):
```bash
rm -rf /tmp/ch && HOME=/tmp/ch lua5.1 cluade.lua --init
grep -q '"system_prompt"' /tmp/ch/.cluade/config.json && echo INIT_OK
# drift: hand-change the stored host, then a non-interactive run must warn on stderr only
sed -i 's/"arch":"[^"]*"/"arch":"ARM-FAKE"/' /tmp/ch/.cluade/config.json
echo 'hi' | HOME=/tmp/ch lua5.1 cluade.lua --subagent --no-session "say hi" 2>/tmp/ch/err 1>/tmp/ch/out
grep -q 'host changed' /tmp/ch/err && echo DRIFT_WARNED_STDERR
test -s /tmp/ch/out && echo STDOUT_HAS_ANSWER   # (requires a working api_key; otherwise expect a provider error on stderr)
```
Expected: `INIT_OK`, `DRIFT_WARNED_STDERR`, and the drift notice absent from `/tmp/ch/out`.

- [ ] **Step 4: Run the whole suite**

Run: `./run_tests.sh`
Expected: all `PASS`.

- [ ] **Step 5: Commit**

```bash
git add cluade.lua
git commit -m "feat: first-run config creation and boot-time host-drift prompt"
```

---

## Notes for the implementer

- `home` in `cluade.lua` is already resolved (`cluade.lua:174`); reuse it, don't re-derive.
- `Agent.prompt_yes_no` already handles raw/cooked tty toggling and treats empty/EOF as "no" — don't reimplement the y/N read.
- Do not persist on `"drift"` or `"ok"`; only `"generated"` and `"regenerated"` write the file.
- The DeepSeek-400 work is a separate change; this plan must not touch `provider.lua` or reasoning-content handling.
