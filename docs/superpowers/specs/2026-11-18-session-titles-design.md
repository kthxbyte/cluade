# Session titles + lazy persistence — design

Status: proposed (awaiting approval)
Date: 2026-11-18

## Intent / why

`--list-sessions` shows only timestamp IDs, message counts, and cwd, so sessions
are hard to tell apart — and startup persists a session file immediately, so
launching the REPL and exiting without typing litters `0-msg` sessions. We give
each real session a human title (model-written when possible, with a
deterministic fallback), and stop creating empty sessions at the source.

## Goals

- Every content-bearing session gets a short title, shown in `--list-sessions`
  and `/sessions`.
- The title is model-written when the model names it, with a first-message
  snippet as a guaranteed fallback so no real session is nameless.
- `/name <title>` lets the user set/override it.
- A session is persisted only once it has a first user message — no empty
  session files.

## Non-goals / anti-goals

- No dedicated extra LLM request for titling — it rides the normal agent loop.
- No re-titling: the first title sticks (`set-once`); only `/name` overrides.
- No migration of existing session files; old untitled-but-content sessions get
  a display-only snippet in the listing.
- Empty sessions are never titled (they're never persisted).
- Anti-goal: breaking `--continue`/`--resume`, or persisting anything in
  `--subagent`/ephemeral runs.

## Constraints

- Lua 5.1. `set_title` follows the existing `compact` pattern (tool returns a
  special status; the run loop applies it to the live `session`).
- Lazy persistence must keep `-c`/`-r` working (the `last_session` pointer must
  still point at a real, saved session).
- `set_title` is excluded from the `--subagent`/`--plan` toolsets (ephemeral, no
  session to title), like `ask`.

## Approaches considered

- **Snippet-only** (title = first user message, trimmed). Trivial, free,
  deterministic, but crude titles.
- **Dedicated LLM title call** after the first turn. Nicer titles, but a separate
  request — cost + latency against the minimal grain.
- **Model-driven `set_title` + snippet fallback (CHOSEN).** The model names the
  session via a tool call *inside* the normal loop (no extra round-trip,
  full-context titles), and if it never does, the harness backfills a snippet so
  a name is guaranteed. Pairs with **lazy persistence** as the root-cause fix for
  empty sessions (create in memory, write on first content) rather than pruning
  empties after the fact.

## The design (decided)

### 1. Lazy session persistence
- `cluade.lua` new-session branch: build the session **in memory only** — no
  `Store.save_session`, no `Store.set_last_session_id` at startup.
- `agent:run` already saves at end (non-ephemeral); after it returns, `cluade.lua`
  sets `last_session` **only when** `#session.messages > 0` and not ephemeral.
- `/new` resets the in-memory session without saving (persists when first used).
- Net: a session file is born with content; `--continue`/`--resume` still load
  real saved sessions.

### 2. `set_title` tool (tools.lua)
- `DEFS.set_title`: `{ title (string, required) }`; description tells the model to
  set a concise 3–6 word title once the session's purpose is clear.
- `execute_set_title` returns `{ status = "titled", title = <trimmed, one line,
  capped ~60 chars> }` (error on empty). Registered in `EXECUTORS`;
  `DEFAULT_PERMISSIONS.set_title = "allow"`.
- Run loop (`agent:run`) special-cases it like `compact`: on
  `result.status == "titled"`, set `session.title = session.title or result.title`
  (**set-once** — only fills when empty).

### 3. Prompt nudge (agent.lua `_augmentations`)
- Add a titling instruction to the per-turn augmentations (so it applies even to
  sessions whose `system_prompt` was generated before this feature), gated on
  **not subagent** and **session not yet titled** (skip the nudge once named).
  Wording left to the builder.

### 4. Snippet fallback (agent.lua, end of `run`)
- After the loop, if not ephemeral and `session.title` is empty and a first user
  message exists → `session.title = snippet(first user message)` (first line,
  trimmed, ~50 chars). Runs before the final save so it persists. Set-once.

### 5. `/name` command (cluade.lua `handle_command`)
- `/name <title>` sets `session.title` (overriding any prior), and saves
  immediately when the session is already persisted (`#messages > 0`).

### 6. Toolset wiring (agent.lua `_tool_names`)
- Add `set_title` to the normal toolset; exclude it from `--subagent`/`--plan`
  (join `subagent`/`ask` in the exclusion).

### 7. Listing + display (store.lua + cluade.lua)
- `list_sessions` returns `title` too (`parsed.title`, else a snippet derived from
  the first user message, else nil) and **skips 0-msg sessions** (legacy empties
  fall off the list).
- Display (both `--list-sessions` and `/sessions`):
  `id · <title | (untitled)> · N msgs · cwd` — cwd kept as the context anchor.

## Left to the builder

- Exact nudge wording; the snippet length cap and title length cap; the display
  column spacing.
- Whether `/name` on a not-yet-persisted (0-msg) session writes a file
  immediately or waits for first content (lean: wait — stay consistent with lazy
  persistence).
- Snippet helper location (shared by the fallback and `list_sessions`).
