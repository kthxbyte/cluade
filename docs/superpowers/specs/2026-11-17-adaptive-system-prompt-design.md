# Adaptive system prompt — design

Status: proposed (awaiting approval)
Date: 2026-11-17

## Intent / why

The `SYSTEM_PROMPT` constant in `agent.lua` hardcodes environment claims —
"running on OpenWRT", "shell is ash (busybox)", "Python is NOT available",
"use /tmp". On any host that isn't that specific OpenWRT target (including the
dev machine and the advertised generic/ollama use) these are **false
affirmations** that misdirect the model. We want the prompt to describe the
host cluade is actually running on, stored where the user can see and edit it,
and to notice when a stored prompt no longer matches the current host (e.g. the
config was generated on one box and `~/.cluade` copied to a router).

## Goals

- The system prompt states what the host actually provides (OS, arch, shell,
  Python), not fixed assumptions.
- The prompt lives in `config.json` — visible and hand-editable.
- Each boot detects host drift and, when it finds any, offers to regenerate
  rather than silently lying or silently overwriting.
- The user's DeepSeek API key gets a home: `config.json` reliably exists.

## Non-goals / anti-goals

- Not a general capability-detection framework — just enough facts to stop the
  prompt lying (OS, arch, shell flavor, Python presence).
- Regeneration does **not** preserve hand-edits to the prompt body; a user who
  says "yes, regenerate" accepts a rewrite. (Known tradeoff; template-merge is
  out of scope.)
- Anti-goal: writing files or prompting in `--subagent`/`--quiet`/non-tty runs,
  or emitting anything to stdout in quiet mode (the clean-stdout contract for
  subagents must hold — all notices go to stderr).

## Constraints

- Lua 5.1; probe commands must be busybox/ash-safe (`uname`, `command -v`,
  `readlink` are all in busybox).
- Degrade gracefully: a missing probe command yields a sensible "unknown"
  fallback, never an error.
- Keep it small and in the existing single-purpose-module style.

## Approaches considered

- **A — bake at `--init` only.** Static string in config; no boot check. Rejected:
  goes stale silently when the host changes or config is copied.
- **B — probe every boot, never persist.** Always correct but not visible/editable
  and no stored prompt. Rejected: loses the "in config.json, user-owned" goal.
- **C — hybrid (runtime env section + optional override).** Correct by default but
  the prompt isn't fully user-owned in config. Rejected in favor of D.
- **D — bake into config + boot-time drift check (CHOSEN).** Prompt is owned in
  config.json; a stored host fingerprint is compared against a cheap boot probe;
  drift triggers a consent prompt to regenerate. Keeps A's visibility/editability
  while neutralizing its staleness con.

## The design (decided)

**New module `hostprobe.lua`** (small, pure, testable like `loopdetect`/`dangercheck`):
- `probe()` → `{ os, arch, shell, python }`
  - `os` = `uname -s`, `arch` = `uname -m`
  - `shell` = flavor of `/bin/sh` via `readlink -f /bin/sh` basename
    (busybox / dash / bash / ...), plus whether `bash` is on PATH
  - `python` = `command -v python3 || command -v python` → the interpreter or nil
- `build_prompt(probe)` → full system-prompt string: a static base (role +
  communication guidance, unchanged) followed by an **Environment** section
  generated from the probe (names the real OS/arch/shell, states Python
  available-at-PATH or not, temp dir).
- `fingerprint(probe)` / `differs(a, b)` → the comparable subset
  (`os`, `arch`, `shell`, `python` present/absent) and a drift test.
- Command execution behind a seam so tests can inject fake `uname`/`command -v`
  output (mirrors the tty seams already in `agent.lua`).

**Config schema (additions to `config.json`):**
- `system_prompt`: string — the baked prompt used verbatim by the agent.
- `host`: `{ os, arch, shell, python }` — fingerprint the prompt was built for.

**First run (no `config.json` found):** run the init routine — probe,
`build_prompt`, write `~/.cluade/config.json` with `system_prompt`, `host`, and
the existing default fields; print a one-line notice ("created … — add your
api_key"). This is the agreed replacement for "default to `--init`". `--init`
stays available to force a regenerate.

**Every boot (config present):**
1. If `system_prompt`/`host` are absent (old config), treat as first-run:
   generate and persist.
2. Else `probe()` and compare to `config.host`.
3. Match → silent, use the stored prompt.
4. Drift + interactive tty → ask
   `host changed (<old> → <new>); regenerate system prompt? [y/N]`.
   Yes → `build_prompt` + persist (overwrites `system_prompt`, updates `host`).
   No → keep the stored prompt for this run.
5. Drift + non-interactive (`--subagent`/`--quiet`/no tty) → one-line warning to
   **stderr**, keep the stored prompt, write nothing.

**Agent wiring:** `agent.lua` uses `self.config.system_prompt or SYSTEM_PROMPT`
in both places the prompt is referenced (initial system message and the
`compact` rebuild). The existing `SYSTEM_PROMPT` constant stays as the
fallback/base template; its hardcoded Environment assertions move into
`hostprobe.build_prompt` so the generated section is the only place that
describes the host.

**Orchestration:** the first-run/drift logic runs in `cluade.lua` main after
`Store.load_config`, before `Agent:init`, reusing the tty-aware yes/no prompt.

## Left to the builder

- Exact wording of the generated Environment section and the drift notice.
- Whether `hostprobe` holds the base-prompt template text or `agent.lua` passes
  it in (builder's call; keep one source of truth).
- Test layout under `tests/` following existing seam-based patterns; cover:
  probe parsing, fingerprint/drift, prompt generation (python present/absent,
  shell flavor), regenerate-on-yes vs keep-on-no, and the non-interactive
  warn-only / clean-stdout path.
