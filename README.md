# cluade — Software Specification

## 1. Project Overview

> **cluade** — **C**ompact **Lua** **De**veloper.

**cluade** is a minimal coding agent written in Lua 5.1. Its focus is bringing the
power of LLMs to **basic, constrained Linux devices** — OpenWRT routers, a Raspberry
Pi, and similar hardware that may not be able to run a full-fledged Node.js or Python
software stack. The guiding observation: *all you really need to reach an LLM is HTTP
and a JSON parser* — so cluade leans on `curl` and a single vendored `json.lua`
instead of a heavy runtime or dependency tree.

It provides an interactive or one-shot CLI that connects to **any OpenAI-compatible
LLM API** — whether a remote provider (e.g. DeepSeek) or a local model server running
on the device itself (e.g. a quantized Gemma) — executes tool calls (filesystem,
shell, web, SSH), and maintains session history.

| Property | Value |
|----------|-------|
| Language | Lua 5.1 |
| Entry point | `cluade.lua` (e.g. `/root/cluade/` on OpenWRT, `~/cluade/` on a Pi) |
| Runtime target | Constrained Linux — OpenWRT (BusyBox ash), Raspberry Pi, etc. |
| Backends | Any OpenAI-compatible endpoint: remote (e.g. DeepSeek) or a local LLM server |
| Dependencies | `curl` + Lua 5.1 + vendored `json.lua` — no Node.js, Python, or LuaSocket |
| License | Not specified |

### 1.1 cluade vs. the Bigger Tools

cluade is a **lighter alternative** to full agents like [opencode](https://opencode.ai)
and [Claude Code](https://claude.com/claude-code) — not a replacement on a dev laptop,
but a real coding agent for hardware where neither of those can even start. The
trade-off is deliberate: cluade keeps the parts that fit a router or a Pi and drops the
machinery that needs a heavier runtime.

✅ full · ⚠️ partial/indirect · ❌ none

| | **cluade** | **opencode** | **Claude Code** |
|---|---|---|---|
| Runtime | ~2.3k LOC Lua 5.1 | Go/TS binary | Node.js app |
| Hard dependencies | `lua5.1` + `curl` | prebuilt binary | Node 18+ |
| Runs on OpenWRT/MIPS/Pi | ✅ | ❌ | ❌ |
| Bring-your-own provider | ✅ any OpenAI-compatible | ✅ 75+ | ⚠️ Anthropic/Bedrock/Vertex |
| Local models (Ollama/llama.cpp) | ✅ | ✅ | ❌ |
| Interface | line REPL + one-shot | full TUI + IDE/desktop | terminal + IDE/desktop/web |
| read/write/edit/bash/glob/grep | ✅ | ✅ | ✅ |
| Web search + fetch | ✅ | ✅ | ✅ |
| Remote shell over SSH | ✅ `remote_bash` | ❌ built-in | ❌ built-in |
| Project instructions (`AGENTS.md`…) | ✅ tree-walk + global | ✅ tree-walk + global | ✅ `CLAUDE.md` hierarchy |
| Compaction | ✅ | ✅ | ✅ |
| Skills (on-demand markdown) | ✅ | ✅ | ✅ |
| Per-tool allow/ask/deny + danger gate | ✅ | ⚠️ | ✅ |
| Explicit loop detection | ✅ warn-then-stop | ⚠️ internal | ⚠️ internal |
| Save/resume/list sessions | ✅ | ✅ | ✅ |
| Auto-memory (self-written notes) | ❌ | ❌ | ✅ |
| Subagents / parallelism | ❌ | ✅ | ✅ |
| MCP servers | ❌ | ✅ | ✅ |
| Hooks / plugins | ❌ | ✅ | ✅ |
| LSP diagnostics | ❌ | ✅ | ⚠️ via IDE |
| Plan mode | ❌ | ✅ | ✅ |
| Custom slash commands | ❌ (built-ins only) | ✅ | ✅ |
| Image / multimodal input | ❌ text-only | ⚠️ | ✅ |

**Where cluade wins:** it runs where the others structurally can't — busybox, MIPS, a
Pi with no Node and little disk. It is genuinely model-agnostic (a remote provider *or*
a local model on the LAN), and it ships one thing the big tools don't: **`remote_bash`**,
so a cluade on one box can drive another over SSH.

**What you give up:** the heavyweight agent machinery — MCP, subagents, hooks, LSP,
IDE/desktop/web surfaces, auto-memory, multimodal. Those need a richer runtime than the
target hardware has, which is exactly why cluade omits them.

> **In one line:** not a replacement for Claude Code or opencode on a dev laptop — but on
> hardware where neither can even start, cluade gives you a real, safe, session-aware
> coding agent with files, shell, search, web, skills, and project instructions.

---

## 2. File Structure

```
/root/cluade/
├── cluade.lua       # Entry point, CLI parsing, REPL loop
├── agent.lua        # Agent loop: LLM interaction, tool orchestration
├── loopdetect.lua   # Loop detection (warn-then-stop) for the agent loop
├── dangercheck.lua  # Detects catastrophic bash commands (smart permission gate)
├── provider.lua     # HTTP provider for OpenAI-compatible chat API
├── store.lua        # Config loading, session persistence
├── tools.lua        # Tool definitions, permissions, executors, skill scanner
├── colors.lua       # ANSI color output helpers
├── lineedit.lua     # Raw-terminal line editor with history
├── skillimport.lua  # Import Agent Skills from a git repo / path (tool-support report)
├── run_tests.sh     # Test runner (cd's to repo root, runs tests/test_*.lua)
├── tests/           # Test suite (test_*.lua); run from the repo root
├── vendor/
│   ├── json.lua          # Third-party JSON encode/decode (lua-users wiki)
│   └── LICENSE-json.txt  # MIT license for json.lua
└── .cluade/skills/  # Installed skill files (SKILL.md format)
```

Run the tests with `./run_tests.sh` (or `lua5.1 tests/test_<name>.lua` from the
repo root — the tests resolve modules via cwd-relative paths).

---

## 3. Entry Point: `cluade.lua`

### 3.1 Bootstrap

1. Determines `script_dir` from the script's own path. The path is first resolved
   with `readlink -f`, so cluade works when invoked through a **symlink** (e.g.
   `/usr/local/bin/cluade -> /opt/cluade/cluade.lua`) — `script_dir` points at the
   real file's directory, not the symlink's. Falls back to the as-invoked path,
   then `pwd`, if `readlink` is unavailable.
2. Prepends `script_dir` to `package.path` so all modules resolve locally.

Note: the working directory for tool/file operations is the **process cwd** (where
you ran the command, via `$PWD`) — independent of where cluade itself is installed.

### 3.2 CLI Interface

```
cluade [options] [prompt...]

Options:
  -m, --model MODEL       LLM model name         (default: deepseek-v4-pro)
  --base-url URL           API base URL            (default: https://api.deepseek.com/v1)
  --api-key KEY            API key                 (or env: OPENAI_API_KEY)
  -c, --continue           Resume the most recent session
  -r, --resume ID          Resume a specific session by ID
  --list-sessions          List saved sessions
  -y, --yes                Auto-approve all permission prompts
  --init                   Write a default config to ~/.cluade/config.json
  --show-tools-json        Debug: print raw response body + decoded tool_calls + compact view
  -h, --help               Show help
```

### 3.3 Main Flow

1. Parse CLI args.
2. Load merged config via `Store.load_config(cwd)`. CLI overrides (`--model`, `--base-url`, `--api-key`) take precedence.
3. If `--init`: write default config to `~/.cluade/config.json` and exit.
4. If `--list-sessions`: print sessions from `~/.cluade/sessions/` and exit.
5. Determine session: `--continue`, `--resume ID`, or new session.
6. Update `last_session` pointer.
7. Create `Agent` with merged config and cwd.
8. If `--yes`: set permissions for `bash`, `remote_bash`, `write` to `"allow"`.
9. If a prompt was given: run agent once and exit.
10. Otherwise: enter interactive REPL with line editing (arrow-key history, bracketed paste, inline cursor movement).

### 3.4 Interactive REPL

The REPL uses `lineedit.lua` for raw-terminal input:
- **History**: up/down arrows recall previous commands (100-entry ring, in-memory only).
- **Cursor**: left/right/home/end for inline editing, backspace and Delete key.
- **Bracketed paste**: multi-line blocks pasted in one go (newlines converted to `\n`).
- **Ctrl+C**: prints `^C` and re-prompts; terminal restored on errors.
- **Ctrl+D**: on empty line exits the REPL.
- **Slash commands**: `/help`, `/exit`, `/sessions`, `/resume <id>`, `/new`, `/model <name>`.

### 3.5 Status Bar

After each agent turn, a status line shows:
```
-- <model> - <tokens> - <X.X% context> - <elapsed time>
```

### 3.6 Tool Output

Tools report execution with green labels:
```
[using tool: read...]
[using tool: bash...]
[using tool: web_search...]
[using skill: brainstorming...]
[using tool: compact...]
```

---

## 4. Agent Module: `agent.lua`

### 4.1 Role

Drives the LLM conversation loop: sends messages, receives responses, processes tool calls, handles permission checks, and persists session state after each run.

### 4.2 System Prompt

Hardcoded string defining the agent persona:
- Coding agent on OpenWRT (busybox ash, Linux MIPS).
- Communication: concise, GitHub-flavored markdown, no unnecessary explanation.
- Environment: standard Linux/ash, BusyBox tooling (`grep`, `sed`, `awk`, `find`, `head`, `tail`, `cut`, `sort`), no Python, `/tmp` for temp files.

### 4.3 Skill Discovery

At startup, `Agent:init()` scans `~/.cluade/skills/` and `./.cluade/skills/` for `SKILL.md` files and lists available skills in the system prompt. Loaded via the `skill()` tool.

cluade reads the [Agent Skills](https://agentskills.io) open-standard `SKILL.md`
format, so skills published for Claude Code / Codex / opencode are largely
reusable. `skillimport.lua` pulls them in from a git repo or a local path:

```sh
lua5.1 skillimport.lua <git-url|local-path> [--dry-run] [--force] [--link] [--dest DIR]
```

It reports, per skill, whether cluade can run it — derived from the skill's
`allowed-tools` frontmatter mapped onto cluade's tool set:

- `[OK  ]` **full** — every declared tool has a cluade equivalent.
- `[PART]` **partial** — some declared tools are unsupported (listed); the skill
  still loads but may reach for a tool cluade lacks (e.g. `Task`, an MCP tool).
- `[? ]` **unknown** — no `allowed-tools` declared, so support can't be verified.

It also flags skills that bundle `python`/`node` scripts or a `.claude-plugin/`
(agents/hooks/MCP), since those parts don't cross over to a constrained device.
Use `--dry-run` to preview the report before installing.

### 4.4 Agent:run(session, input)

Before the first step, the agent reads project instructions (see §4.6) and lists
discovered skills (§4.3) into the system prompt.

Each step (the on-screen counter is a plain `[step N]`, not `N/M`):
1. Call `llm:chat(messages, tool_defs)` — captures `reasoning_content` (thinking mode output).
2. If tool_calls: for each, check permission, prompt user if `ask`, execute, append result, and feed the call's normalized signature + error status to the loop detector (§4.5).
3. After the step's tool calls, consult the loop detector — it may inject a warning to the model or stop the turn.
4. If `finish_reason == "stop"` — break.
5. At 85% context threshold: nudge LLM to call `compact(summary)` to free context.
6. Persist session after each run.

The loop runs until the model finishes (`stop`), the loop detector halts it, or
the `config.max_steps` **safety backstop** is reached (default 100 — a defense-in-depth
ceiling, not the primary guard). Each terminal condition prints a distinct message.

### 4.5 Loop Detection (`loopdetect.lua`)

Replaces the old hard step cap. A deterministic, boolean detector (no confidence
scores) that watches two runaway patterns using **consecutive** counts, so any
change in behavior resets the streak and keeps false positives near zero:

- **Repeat loop** — the same tool with identical arguments called `repeat_threshold` (3) times in a row.
- **Error loop** — tool results erroring `error_threshold` (4) times in a row; any success resets the count.

Signatures are normalized via `LoopDetect.signature(name, args)`: object keys are
sorted (order-independent), array order preserved (it's meaningful), and raw
unparsed arg strings pass through unchanged (so a parse-failed call keeps its own
identity). Comparison is literal string equality.

Reaction is **warn-once-then-stop**: the first trip injects a user-role message
telling the model it looks stuck (change approach or stop); if it's still tripped
on the next check, the turn halts with a "send 'continue' to resume" message. If
the model changes behavior after the warning, the trip disarms.

### 4.6 Project Instructions

Before the first step, `Agent:run` reads project instruction files, opencode-style,
and appends them to the system prompt:

- **Per-file precedence:** `AGENTS.md` (the cross-tool standard) is preferred, with
  `CLAUDE.md` as the Claude-Code-compatible fallback and `GEMINI.md` last. First
  match wins; the others are ignored (they're usually symlinks to the same file).
- **Directory-tree walk:** the search walks *up* from `cwd`, and the nearest
  ancestor's instruction file wins -- so running cluade from a subdirectory still
  picks up the project root's `AGENTS.md`. The walk stops at the git root (a `.git`
  dir/file), so unrelated files above the repo are never read.
- **Global file:** an instruction file in `~/.cluade/` applies across all projects.
  It is concatenated *ahead* of the local file, so a project file overrides personal
  defaults.

The augmentations (this file plus the available-skills list) are rebuilt fresh
on every turn -- and re-applied after a `compact` -- so they appear exactly once
no matter how long the session runs, and survive compaction within a run.

### 4.7 Permission Model

Three levels: `allow` (auto-execute), `ask` (prompt user `[y/N]`), `deny` (refuse with error).

Effective defaults come from `DEFAULT_PERMISSIONS` in `tools.lua`:
- `allow`: `read`, `write`, `edit`, `bash`, `glob`, `grep`, `web_search`, `web_fetch`, `compact`, `skill`
- `ask`: `remote_bash`

A `permissions` block in `config.json` overrides these per-tool (applied in
`Agent:init`); only the tools you name change. `--yes` overrides `bash`,
`remote_bash`, `write` to `allow` and takes precedence over both, since it runs
after `Agent:init`. Effective precedence: `tools.lua` defaults < config < `--yes`.

`ask` prompts go through `Agent:prompt_yes_no`, which saves the terminal mode,
switches to cooked (canonical + echo) for the read, then restores the prior mode.
This keeps the answer visible and line-editable even when the interactive REPL
has left the terminal in raw (`-icanon -echo`) mode.

**Smart bash gate (`dangercheck.lua`).** Even when `bash` is `allow`, a
catastrophic command is escalated to a one-time `[y/N]` prompt (the prompt shows
the flag reason). Only an *allowed* bash call is gated — `deny` is never
downgraded, an already-`ask` tool is unchanged, and non-bash tools are untouched.
The detector is deliberately conservative (it protects against an irreversible
model mistake without babysitting): it flags only

- `rm -rf` (recursive + force) targeting a system/root/home path (`/`, `~`,
  `$HOME`, `/etc`, …) or a bare `*`/`.`/`..` — but **not** a relative or `/tmp`
  path, so `rm -rf ./build` runs silently;
- `dd ... of=/dev/…` and shell redirects onto a raw block device
  (`/dev/sd*`, `/dev/mmcblk*`, `/dev/nvme*`, …) — but **not** `dd` to a file or
  `> /dev/null`;
- `mkfs[.fs]`, power-state commands (`shutdown`/`reboot`/`halt`/`poweroff`), and
  the classic fork bomb;
- a network download executed by a shell, in any common disguise: a pipe
  (`curl … | sh`, `wget -qO- … | bash`, incl. a `sudo` in between), command
  substitution under an exec trigger (`sh -c "$(curl …)"`, `eval "$(curl …)"`,
  backticks), or process substitution (`bash <(curl …)`) — but **not** a download
  to a file, a pipe into a non-shell like `grep`/`tar`, a capture to a variable
  (`v=$(curl …)`), or a process-sub into a non-shell (`diff <(curl a) <(curl b)`).

It prefers false negatives to false positives: an obfuscated destructive command
can slip through, which is acceptable because the model is an occasional bungler,
not an adversary trying to evade the check.

---

## 5. Provider Module: `provider.lua`

- Endpoint: `{base_url}/chat/completions`.
- Transport: **curl** via `io.popen` (no Lua HTTP library dependency). Invoked with
  `--http1.1` (avoids curl exit 92 / HTTP/2 `PROTOCOL_ERROR`) and `--max-time`
  set from `config.request_timeout` (default 600s).
- Response: parses JSON, extracts `content`, `reasoning_content`, `tool_calls`, `finish_reason`, `usage`.
- Transport failures surface the curl exit code and stderr (e.g. `request failed
  (HTTP <code>, curl exit <n>: <stderr>)`) instead of being masked as JSON parse errors.

### 5.1 Request body — the exact fields cluade sends

The body is built from a **fixed** set of fields (`provider.lua:16–29`). There is
**no** `extra_body` / passthrough mechanism — any config key not listed below is
ignored. This is the source of truth for "how do I tune the API call":

| Body field | Source | Notes |
|---|---|---|
| `model` | `config.model` | |
| `messages` | conversation | |
| `tools`, `tool_choice` | tool defs | only when tools are present; `tool_choice` is `"auto"` |
| `thinking` | gated by `config.thinking` | **Boolean gate, not a passthrough.** If `config.thinking ~= false`, cluade sends the hardcoded `{type="enabled"}`. Set `"thinking": false` to turn reasoning **off**; any truthy value (or omitting it) leaves it **on**. The value itself is never forwarded. |
| `reasoning_effort` | `config.reasoning_effort` | Sent only when thinking is on. **Defaults to `"max"`** — so you already get maximum reasoning effort with no config at all. DeepSeek accepts `"high"` or `"max"`. |
| `max_tokens` | `config.max_tokens` | Forwarded as-is (default 131072). The model's real output cap is server-side; an over-large value yields a clear `HTTP 4xx`, not a silent failure. |
| `temperature` | per-call options only | **Not read from config.** The agent never sets it, so it is effectively never sent (and is ignored by the API in thinking mode anyway). |

**"Maximum effort" config:** none needed — `reasoning_effort` already defaults to
`"max"`. To be explicit, set it top-level: `"reasoning_effort": "max"`. Do **not**
wrap it in `extra_body` (that key does nothing).

---

## 6. Tools Module: `tools.lua`

### 6.1 Architecture

1. **Definitions** — OpenAI function-calling schemas.
2. **Permissions** — mutable per-tool level (`allow`/`ask`/`deny`).
3. **Executors** — actual tool implementations.

### 6.2 Tool Catalog (11 tools)

| Tool | Description | Required Params | Optional Params |
|------|-------------|-----------------|-----------------|
| `read` | Read file, return with line numbers | `filePath` | — |
| `write` | Create/overwrite file | `filePath`, `content` | — |
| `edit` | Exact string replacement in file | `filePath`, `oldString`, `newString` | `replaceAll` (bool) |
| `bash` | Execute shell command | `command` | `workdir` |
| `glob` | Find files by glob pattern | `pattern` | `path` |
| `grep` | Search files with regex | `pattern` | `path`, `include` |
| `web_search` | DuckDuckGo HTML search | `query` | — |
| `web_fetch` | Fetch URL content | `url` | — |
| `remote_bash` | Execute command on remote host via SSH key | `host`, `command` | `username`, `port` |
| `compact` | Free context by summarizing conversation | `summary` | — |
| `skill` | Load SKILL.md instructions for a skill | `name` | — |

### 6.3 Executor Details

**`read`**: Opens file, prefixes each line with `N: `, returns as string. Includes line numbers for precise `edit` targets.

**`write`**: Creates parent directories, writes content. Returns `"wrote <path>"`.

**`edit`**: Reads file, finds `oldString` (plain match). If `replaceAll=true`, does `gsub` with pattern-escaped old string. Otherwise requires exactly one match. Overwrites file.

**`bash`**: `cd <workdir> && <command>`, captures stdout+stderr, appends `[exit code: N]` on non-zero exit. 30-second timeout.

**`glob`**: A relative `pattern` resolves against `path` (default cwd); an absolute pattern is used as-is. Detects `**` for recursive mode — searches from the directory before the first wildcard with `find -name <trailing glob>` (matching at any depth). Otherwise uses `ls -d`. Capped at 100 results.

**`grep`**: Runs `grep -rn` with optional `--include` filter, capped at 100 lines.

**`web_search`**: Fetches DuckDuckGo HTML with Chrome 147 user-agent, parses result links and snippets.

**`web_fetch`**: Fetches URL with Chrome 147 user-agent, 15s timeout, caps response at 32KB.

**`remote_bash`**: Uses `ssh -y` (dropbear host key acceptance) with SSH key authentication. Default user `root`, port `22`. No password support (key-only, for security).

**`compact`**: LLM-driven context compaction. When called with a `summary`, the agent prunes conversation history after the system prompt, replacing it with the summary. LLM decides when to call it (nudged at 85% context threshold).

**`skill`**: Scans `~/.cluade/skills/` and `./.cluade/skills/` for `SKILL.md` files. Parses YAML frontmatter (name, description) via Lua patterns. Returns the full skill body for injection into the conversation.

### 6.4 Token Estimation

`_token_estimate(text) = floor(#text / 3.5)` — crude heuristic for context tracking.

### 6.5 Path Resolution

All file-based tools resolve relative paths against `cwd`. Absolute paths pass through unchanged.

---

## 7. Store Module: `store.lua`

### 7.1 Config Loading

Merge order: hardcoded defaults → `~/.cluade/config.json` → `./.cluade/config.json` → environment variables. Deep merge for nested tables (handles `permissions`).

### 7.2 Session Persistence

- Sessions stored at `~/.cluade/sessions/<id>.json`.
- ID format: `YYYYMMDD-HHMMSS-NNNN`.
- Saved after every `agent:run()` call (crash recovery).
- `list_sessions()` parses `ls -t *.json` for summary views.
- `last_session` pointer at `~/.cluade/last_session`.

---

## 8. Dependencies

| Dependency | Required For | Notes |
|------------|-------------|-------|
| **Lua** 5.1 | Everything | Core runtime |
| **curl** | provider.lua | HTTP transport to LLM API |
| **Dropbear SSH** | remote_bash tool | `ssh -y` command (built into OpenWRT) |
| **vendor/json.lua** | All JSON operations | Bundled, MIT-licensed, no C deps |

No Python, no Node.js, no LuaSocket, no systemd — intentionally minimal.

---

## 9. Configuration File Format

`~/.cluade/config.json` or `./.cluade/config.json`:

```json
{
  "base_url": "https://api.deepseek.com/v1",
  "model": "deepseek-v4-pro",
  "api_key": "sk-...",
  "max_steps": 100,
  "max_tokens": 131072,
  "request_timeout": 600,
  "thinking": true,
  "reasoning_effort": "max",
  "context_limit": 200000,
  "compact_threshold": 0.85,
  "permissions": {
    "bash": "allow",
    "remote_bash": "ask",
    "write": "allow"
  }
}
```

`max_steps` is a safety backstop only; loop detection (§4.5) is the real guard.
The `permissions` block overrides the per-tool defaults from `tools.lua` (§4.7);
list only the tools you want to change. The values shown above are the defaults.

For how `thinking` / `reasoning_effort` / `max_tokens` actually reach the API
(and why there is no `extra_body`), see §5.1. Unrecognized config keys are loaded
but never used — they do not reach the request.

---

## 10. Session File Format

`~/.cluade/sessions/YYYYMMDD-HHMMSS-NNNN.json`:

```json
{
  "id": "20260529-201630-1000",
  "cwd": "/root",
  "created": "2026-05-29 20:16:30",
  "messages": [
    {"role": "system", "content": "You are cluade..."},
    {"role": "user", "content": "fix the bug in foo.lua"},
    {"role": "assistant", "content": "...", "tool_calls": [...]},
    {"role": "tool", "tool_call_id": "...", "content": "{...}"}
  ],
  "steps": 5,
  "total_tokens": 12345,
  "context_tokens": 8200
}
```

`total_tokens` is the cumulative usage across the run; `context_tokens` is the
estimated current context size (drives the status-bar `% context`). The two
differ — using the cumulative total for the percentage previously reported
bogus values like 288%.

---

## 11. Key Design Decisions

1. **curl-based HTTP** — avoids need for LuaSocket at provider level. Temp files via `os.tmpname()` for request bodies.
2. **LLM-driven compaction** — agent calls `compact(summary)` at milestones; nudged at 85% context threshold.
3. **Skill system** — SKILL.md with YAML frontmatter (Claude Code compatible). Discovered at startup, loaded on demand.
4. **Line editing** — pure Lua raw-terminal module: history ring, cursor keys, backspace, Delete, bracketed paste, Ctrl+C graceful.
5. **SSH key-only** — remote_bash uses dropbear `ssh -y` with `~/.ssh/id_dropbear`. No sshpass, no passwords.
6. **Chrome 147 UA** — web_search and web_fetch spoof a Chrome user-agent to avoid bot blocking.
7. **ANSI colors** — cyan prompt, green tool labels, magenta status bar, red errors.
8. **Loop detection** — deterministic warn-then-stop guard (`loopdetect.lua`, §4.5) replaces the old hard step cap: the model runs as long as it makes progress and is stopped only when it's actually stuck (identical calls or repeated errors). `config.max_steps` (default 100) remains as a high safety backstop.
9. **Smart bash gate** — `bash` stays `allow` for flow, but a conservative detector (`dangercheck.lua`, §4.7) escalates only catastrophic, irreversible commands to a confirmation prompt. Protects against model error without babysitting; prefers false negatives to false positives.

---

## 12. Extension Points

To add a **new tool**:
1. Add `DEFS.<name>` in `tools.lua` with OpenAI function schema.
2. Add `Tools.execute_<name>(cwd, params)` executor.
3. Register in `EXECUTORS` table and `DEFAULT_PERMISSIONS`.
4. Add to `tool_names` list in `agent.lua`.

To add a **new skill**:
1. Create `~/.cluade/skills/<name>/SKILL.md` with YAML frontmatter (`name`, `description`, `allow`).
2. Restart cluade or start a new session; skill auto-discovered.

---

## 13. Error Handling

| Pattern | Usage |
|---------|-------|
| `pcall(json.decode, ...)` | All JSON parsing is pcall-protected |
| `pcall(executor, ...)` | Tool executors wrapped in `Tools.execute` |
| Provider error bubbling | Non-200 or curl failure → `[provider error: ...]`, including curl exit code + stderr |
| Session load failures | `pcall` around `Store.load_session` |
| cbreak terminal cleanup | `pcall` wrap in REPL loop restores `stty icanon echo` on error |

---

## 14. Known Limitations

1. **thinking mode** — sent when `config.thinking ~= false` (default: enabled). Standard OpenAI models ignore unknown fields.
2. **web_search parsing** — scrapes DuckDuckGo HTML; brittle against markup changes.
3. **No streaming** — responses received in full; no progressive output.
4. **Token estimation** — `#text / 3.5` is inaccurate for non-English or code-heavy content.
5. **glob with `**`** — collapses the trailing segment to a `find -name` glob; intermediate path structure in the pattern (e.g. `a/**/b/*.lua`) is not enforced, only the final name and the search root.
6. **No multi-modal** — text-only; no image/file upload.
7. **Session-only history** — arrow-key history is not persisted across sessions.
8. **ASCII cursor positioning** — byte-based, not Unicode-aware; acceptable for CLI environment.
