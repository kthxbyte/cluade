# `ask` tool — design

Status: proposed (awaiting approval)
Date: 2026-11-18

## Intent / why

cluade's model has no structured way to put a question or a set of choices to the
user mid-run and get the answer back — the only in-run interaction is the yes/no
permission prompt, which the model can't invoke or phrase. Other harnesses all
provide this (Claude Code `AskUserQuestion`, opencode's question tool, Gemini's
`ask_user`). We add a single `ask` tool so the agent can ask the user to pick one
of several options, pick several, or answer in free text, and continue with the
answer. Scope decided in brainstorming: one `ask` tool, **one question per call**,
**type inferred** from the arguments, **full set** (single-select, multi-select,
free-text).

## Goals

- A model-callable `ask` tool that, in the interactive REPL, prints the question
  (and numbered options when given), reads the user's answer from the terminal,
  and returns it as the tool result.
- Type inferred: options + no `multiple` ⇒ choose one; options + `multiple` ⇒
  choose one or more; no options ⇒ free text.
- When options are shown, always offer an extra **"Other → free text"** choice so
  the user is never boxed in.

## Non-goals / anti-goals

- No multi-question batching, no rich TUI, no option "preview" panes (one-line
  descriptions only).
- No re-prompt loop on invalid input — one read; unparseable/empty ⇒ `(no answer)`
  and the model may re-ask.
- **Anti-goal:** blocking or hanging when there is no user. In `--subagent`/
  `--plan`/non-tty there is nobody to answer; the tool must never wait on stdin.

## Constraints

- Lua 5.1; terminal only.
- Must work when the REPL has left the terminal in raw mode: cook/restore around
  each read, using the same `stty … </dev/tty` technique as `Agent:prompt_yes_no`.
- No circular module dependency (`agent.lua` requires `tools.lua`, so `tools.lua`
  must not require `agent.lua`).
- `tests/test_prompt.lua` must stay green.

## Approaches considered

- **A — self-contained executor in `tools.lua` (CHOSEN).** `ask` is an ordinary
  executor like every other tool: it owns its cooked-tty read behind test seams,
  returns an answer (or an error when no terminal is available), and flows through
  the loop's normal permission/execute path (permission `allow`). Consistent with
  the codebase; keeps the loop uniform; unit-testable via seams.
- **B — route through an `Agent:ask_user` method**, special-cased in the run loop
  like `compact`. Rejected: splits one tool across two modules and branches the
  loop, and pulling Agent's tty seams into `tools.lua` would be a circular
  dependency. No benefit over A.
- **C — multi-question batch / TUI** (the other harnesses' richer shape). Rejected
  by the brainstorm decisions (single question, no TUI).

## The design (decided)

**Tool definition** (`DEFS.ask` in `tools.lua`):
- `question` (string, required)
- `options` (array, optional): each item `{ label (string), description (string,
  optional) }`; a bare string is accepted and normalized to `{ label = s }`.
- `multiple` (boolean, optional, default false)

**Inferred behavior** in `execute_ask`:
- **options + not multiple** → numbered list `1) label — description`, plus a final
  `N+1) Other`. Read one line; parse the first valid index; `N+1` ⇒ read a
  free-text follow-up. Result = that label (or the Other text).
- **options + multiple** → same list; read one line of comma-separated indices;
  map each valid index to its label; `N+1` included ⇒ append a free-text answer.
  Result = the chosen labels joined by `, `.
- **no options** → print the question, read one line. Result = that text.
- A choice answer that is **not** a pure numbers/commas/spaces line is passed to
  the model **verbatim** (the user steering off-menu — "none of these, do Z"),
  not mined for digits. A pure-but-out-of-range number, or empty input, ⇒
  `(no answer)`. (Refined during implementation: capture the user's steer rather
  than guess or drop it.)
- Result shape: `{ status = "ok", output = <answer string> }` (the model reads the
  tool message content, so a readable string suffices).

**No-user handling (two layers):**
1. `ask` is **excluded from the toolset** in `--subagent` and `--plan` (added to
   the exclusions in `Agent._tool_names`, alongside `subagent`), and **included**
   in the normal toolset.
2. Defensive net: if `execute_ask` is ever reached without a controlling terminal
   (seam reports no tty), it returns `{ status = "error", error = "ask: no
   interactive user available" }` instead of blocking on stdin.

**Terminal I/O & seams:** the cooked-tty read lives behind overridable seams on
`Tools` (e.g. `Tools._ask_available`, `Tools._ask_write`, `Tools._ask_read`) so
tests inject answers with no real terminal, mirroring `test_prompt.lua`'s stubbing
of `Agent._tty_*`. The real implementations use `stty -g/ icanon echo … </dev/tty`
and restore the prior mode after each read.

## Left to the builder

- Whether to factor the shared `stty` cook/restore primitive into a tiny module
  reused by both `prompt_yes_no` and `execute_ask`, or duplicate the few lines in
  `tools.lua` — builder's call, provided there is no circular dependency and
  `test_prompt.lua` stays green.
- Exact wording of the prompt lines and the numbered-list formatting.
- Whether to suppress the green `[using tool: ask …]` label for `ask` (as is done
  for `skill`/`compact` in `Agent._tool_label`) so the question reads cleanly.
