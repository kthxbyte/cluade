# Session Titles + Lazy Persistence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give each content-bearing session a human title (model-written via a `set_title` tool, with a first-message snippet fallback), surface it in the session listing, and stop persisting empty sessions.

**Architecture:** `set_title` is a `compact`-shaped tool (returns a status the run loop applies to the live `session`). The system prompt nudges the model to call it; a snippet fallback at the end of the first content run guarantees a title. Sessions persist lazily — the file and `last_session` pointer are written only once a first user message exists.

**Tech Stack:** Lua 5.1.

**Spec:** `docs/superpowers/specs/2026-11-18-session-titles-design.md`

## Global Constraints

- Lua 5.1. `set_title` mirrors the `compact` pattern (`agent.lua:470`) — tool returns a special status; the run loop applies it.
- **Set-once:** a title is only assigned when `session.title` is empty; only `/name` overrides an existing one.
- `set_title` excluded from `--subagent`/`--plan` toolsets (like `ask`); the titling nudge is omitted for subagents and for already-titled sessions.
- Lazy persistence must not break `--continue`/`--resume` (the `last_session` pointer must point at a saved, content-bearing session).
- Nothing persisted in `--subagent`/ephemeral runs (unchanged).
- Existing tests stay green (notably `test_system_message`, `test_compact_context`, `test_ask_tooling`, `test_subagent_tooling`).

## Review Focus

- **Set-once:** a second `set_title`, or the snippet fallback after a model title, does **not** overwrite the first title → Task 2 test.
- **Subagent:** `set_title` absent from the subagent toolset **and** the nudge absent from a subagent's augmentations → Task 2 test.
- **Already-titled / resumed session:** no nudge re-added (gated on untitled) → Task 2 test.
- **Empty session never persisted:** a REPL launched and exited with no input writes no session file, yet `--continue` still finds the prior real session → Task 4 test.
- **Listing:** 0-msg sessions skipped; an untitled-but-content session shows a derived snippet → Task 3 test.

---

### Task 1: `Store.title_snippet` + `set_title` tool

**Files:**
- Modify: `store.lua` (add `Store.title_snippet`)
- Modify: `tools.lua` (add `DEFS.set_title`, `execute_set_title`, `EXECUTORS.set_title`, `DEFAULT_PERMISSIONS.set_title`)
- Test: `tests/test_set_title.lua`

**Interfaces:**
- Produces:
  - `Store.title_snippet(text) -> string|nil` — first line of `text`, trimmed; `nil` if empty; truncated to 50 chars + `"..."` if longer.
  - `Tools.execute_set_title(cwd, params) -> result` — `{status="titled", title=<first line, trimmed, ≤60 chars>}`, or `{status="error", error=...}` on empty/missing title.
  - `DEFS.set_title` registered; `EXECUTORS.set_title`; `DEFAULT_PERMISSIONS.set_title = "allow"`.

- [ ] **Step 1: Write the failing test** `tests/test_set_title.lua`

```lua
local Store = require("store")
local Tools = require("tools")
-- title_snippet
ok(Store.title_snippet("fix the thing\nmore") == "fix the thing", "snippet = first line trimmed")
ok(Store.title_snippet("   ") == nil, "blank -> nil")
ok(#Store.title_snippet(("x"):rep(80)) <= 53, "long snippet truncated (~50 + ...)")
-- execute_set_title
ok(Tools.execute_set_title(".", { title = "Fix DeepSeek 400" }).status == "titled", "titled status")
ok(Tools.execute_set_title(".", { title = "  spaced  " }).title == "spaced", "title trimmed")
ok(Tools.execute_set_title(".", { title = "" }).status == "error", "empty title -> error")
```

- [ ] **Step 2: Run to verify it fails** — `lua5.1 tests/test_set_title.lua` → FAIL (nils).
- [ ] **Step 3: Implement.** `Store.title_snippet`: `text:match("^[^\n]*")`, trim, nil-if-empty, truncate. `DEFS.set_title`: `{ title (string, required) }`, description instructing a concise 3–6 word title once the task is clear. `execute_set_title`: validate non-empty, clean (first line/trim/≤60), return `{status="titled", title=clean}`. Register executor + permission `allow`.
- [ ] **Step 4: Run to verify it passes** — `ALL PASS`.
- [ ] **Step 5: Commit** — `git add store.lua tools.lua tests/test_set_title.lua && git commit -m "feat: add Store.title_snippet and the set_title tool"`

---

### Task 2: Agent wiring — apply, fallback, nudge, toolset

**Files:**
- Modify: `agent.lua` — run-loop `set_title` apply (near `:470`), end-of-run snippet fallback (near `:549`), `Agent:_augmentations(want_title)` (`:212`) + both call sites (`:335`, `:477`), `Agent._tool_names` (`:95`).
- Test: `tests/test_session_title.lua`, `tests/test_ask_tooling.lua` (extend for `set_title` membership)

**Interfaces:**
- Consumes: `execute_set_title`/`Store.title_snippet` (Task 1).
- Produces: after a run, `session.title` is set from a model `set_title` (set-once) or the first-user-message snippet; `set_title` in the normal toolset, excluded when `subagent`; `_augmentations(want_title)` appends the nudge only when `want_title`.

- [ ] **Step 1: Write the failing test** `tests/test_session_title.lua` (stub `provider` as in `test_compact_context.lua`)

```lua
-- (a) model set_title wins, set-once
--   step 1: assistant emits a set_title tool call {title="Model Title"}; step 2: stop
--   after run: session.title == "Model Title"
-- (b) set-once: pre-set session.title="Kept"; a set_title call does NOT overwrite
-- (c) snippet fallback: provider never titles; first user msg "do the thing"
--   after run: session.title == "do the thing"
-- (d) nudge gating (call the method directly):
local a = Agent:init({ model="t", base_url="x", max_steps=3, sessions_dir=tmp.."/s" }, tmp)
ok(a:_augmentations(true):find("set_title", 1, true), "nudge present when want_title")
ok(a:_augmentations(false):find("set_title", 1, true) == nil, "nudge absent when not want_title")
-- (e) toolset
ok(has(Agent._tool_names({}), "set_title"), "set_title in normal toolset")
ok(not has(Agent._tool_names({subagent=true}), "set_title"), "set_title excluded for subagent")
```

- [ ] **Step 2: Run to verify it fails** — FAIL.
- [ ] **Step 3: Implement.**
  - Loop apply (after the `compact` block): `if name == "set_title" and result.status == "titled" then if not session.title or session.title == "" then session.title = result.title end end`.
  - Fallback (before the end-of-run save at `:551`): `if not self.config.ephemeral and (not session.title or session.title == "") then for _, m in ipairs(session.messages) do if m.role == "user" then session.title = Store.title_snippet(m.content); break end end end`.
  - `_augmentations(want_title)`: append the nudge line (wording: instruct one `set_title` call with a concise 3–6 word title, "don't ask, just set it") when `want_title`.
  - In `run`, compute `local want_title = (not self.config.subagent) and (not session.title or session.title == "")` and pass to both `self:_augmentations(want_title)` calls.
  - `_tool_names`: add `"set_title"` to `names`; extend the subagent exclusion to `n ~= "subagent" and n ~= "ask" and n ~= "set_title"`.
- [ ] **Step 4: Run to verify it passes** — both `tests/test_session_title.lua` and `tests/test_ask_tooling.lua` pass.
- [ ] **Step 5: Run the whole suite** — `./run_tests.sh` all PASS.
- [ ] **Step 6: Commit** — `git add agent.lua tests/test_session_title.lua tests/test_ask_tooling.lua && git commit -m "feat: model-driven session titling with snippet fallback"`

---

### Task 3: Listing — title column + skip empties

**Files:**
- Modify: `store.lua` `Store.list_sessions` (`:112`)
- Modify: `cluade.lua` display lines (`:58` `/sessions`, `:213` `--list-sessions`)
- Test: `tests/test_list_sessions.lua`

**Interfaces:**
- Consumes: `Store.title_snippet` (Task 1).
- Produces: `list_sessions` rows gain `title` (`parsed.title`, else first-user-message snippet, else nil) and 0-msg sessions are omitted.

- [ ] **Step 1: Write the failing test** `tests/test_list_sessions.lua`

```lua
-- Write three session files into a temp sessions dir:
--   titled (title="Saved Title", 2 msgs), untitled (2 msgs, first user "hello world"), empty (0 msgs)
local rows = Store.list_sessions(dir)
-- empty is skipped; titled shows its title; untitled shows the snippet
ok(#rows == 2, "0-msg session skipped")
ok(find_row(rows, "Saved Title"), "stored title surfaced")
ok(find_row(rows, "hello world"), "untitled-with-content gets a snippet title")
```

- [ ] **Step 2: Run to verify it fails** — FAIL (no `title`, empty not skipped).
- [ ] **Step 3: Implement.** In `list_sessions`, compute `nmsg = #(parsed.messages or {})`; only append a row when `nmsg > 0`; `title = parsed.title or (first user message via Store.title_snippet)`. Add `title` to the row. In `cluade.lua`, change both display `string.format` lines to `"%s  %s  %d msgs  %s"` with `(s.id, s.title or "(untitled)", s.messages, s.cwd)` (title replaces the redundant `created` — the id already carries the timestamp).
- [ ] **Step 4: Run to verify it passes** — `ALL PASS`.
- [ ] **Step 5: Commit** — `git add store.lua cluade.lua tests/test_list_sessions.lua && git commit -m "feat: show session titles in the listing, skip empty sessions"`

---

### Task 4: Lazy persistence + `/name` + `/new` defer

**Files:**
- Modify: `cluade.lua` — new-session branch (`:240-245`), `last_session` set (`:249-251`), post-run `last_session` set (after `:289` and `:327`), `handle_command` `/new` (`:74-80`) and a new `/name`, `/help` text (`:47`).
- Test: `tests/test_lazy_session.lua`

**Interfaces:**
- Consumes: nothing new.
- Produces: a session file is written only once it has a user message; `last_session` points only at persisted sessions; `/name <title>` sets `session.title`; `/new` resets in memory without persisting.

- [ ] **Step 1: Write the failing test** `tests/test_lazy_session.lua` (subprocess, offline base_url that refuses instantly)

```lua
-- (a) REPL with immediate EOF (no input) persists nothing
--   echo -n "" | HOME=tmp lua5.1 cluade.lua --base-url http://127.0.0.1:1/v1 -m x
--   -> no *.json under tmp/.cluade/sessions (other than none)
-- (b) one-shot persists a session with the user message
--   HOME=tmp lua5.1 cluade.lua --base-url http://127.0.0.1:1/v1 -m x "hello"
--   -> exactly one session file exists, and Store.list_sessions(tmp sessions) has 1 row
```

- [ ] **Step 2: Run to verify it fails** — FAIL (empty REPL currently writes a session file at startup).
- [ ] **Step 3: Implement.**
  - New-session branch: `session = Store.new_session_data(args.cwd)` only — remove the `Store.save_session` at `:242-244`.
  - `last_session` block (`:249-251`): gate on content — `if not config.ephemeral and #(session.messages or {}) > 0 then Store.set_last_session_id(home, session.id) end` (so `--continue`/`--resume`, which load content-bearing sessions, still set it; a fresh 0-msg session does not).
  - After each `agent:run` (one-shot at `:289`, REPL at `:327`): `if not config.ephemeral then Store.set_last_session_id(home, session.id) end` (the session now has content; `agent:run` already wrote the file).
  - `/new`: reset `session.id/messages/cwd/title` in place, **no** `Store.save_session`.
  - Add `/name <title>`: set `session.title`, and `Store.save_session(sessions_dir, session.id, session)` only when `#(session.messages or {}) > 0` and not ephemeral; print confirmation. Add `/name` to the `/help` list.
- [ ] **Step 4: Run to verify it passes** — `ALL PASS`.
- [ ] **Step 5: Run the whole suite** — `./run_tests.sh` all PASS.
- [ ] **Step 6: Commit** — `git add cluade.lua tests/test_lazy_session.lua && git commit -m "feat: lazy session persistence; /name; /new defers save"`

---

## Notes for the implementer

- `agent.lua` already `require`s `Store` (top of file), so the snippet fallback can call `Store.title_snippet` directly.
- `set_title`, like `compact`, has an executor in `tools.lua` AND loop handling in `agent.lua`; the executor's result (`status="titled"`) is what the loop keys on.
- `home` is in scope at both post-run sites (an upvalue of the REPL closure); reuse it, don't re-derive.
- The offline test base_url `http://127.0.0.1:1/v1` makes the single provider call fail instantly (connection refused) — no network, fast.
