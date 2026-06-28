# cluade BDD Specifications

Three Behavior-Driven Development specifications for cluade, at different fidelity levels.
Each can be given to an LLM as a black-box contract for re-implementation in any language/stack.

## Directory Index

| Directory | Fidelity | Size | Use case |
|-----------|----------|------|----------|
| `A-exact-clone/` | Drop-in replacement | 1,933 lines | Run the existing test suite unmodified. Every CLI flag, config key, tool behavior, edge case, and output format preserved. |
| `B-faithful-port/` | Same architecture, cleaned up | 1,427 lines | Same 12-tool set and UX. Improved HTTP library, tokenizer, Unicode-aware line editing, SSE streaming, standard argument parsing, persisted history. |
| `C-loose-inspiration/` | Redesigned from essence | 1,029 lines | What you'd build today from the same constraints but with no legacy code. New capabilities: daemon mode, pipe input, multi-provider failover, user-defined tools, persistent history. |

## How to Use These Specs

1. **Pick a tier** based on your goal. Tier A for a literal replacement that passes the existing suite; Tier B for a clean-room port with the same UX but better internals; Tier C for a greenfield redesign.
2. **Hand one spec file to an LLM** along with: "Implement this system in `<language>`."
3. **The spec is the contract.** It defines what the system does (behaviors, boundaries, invariants, edge cases). The LLM chooses how to wire it internally — libraries, data structures, concurrency model, argument parser — as long as every `Given/When/Then` scenario holds.
4. **Treat the spec as a black-box test plan.** Every scenario is a testable assertion. Verify that the implementation satisfies them. If it does, it is a valid cluade.

## Spec Format

Each tier uses **Gherkin** (Given/When/Then) for behavioral scenarios, organized into features:

- **System boundaries** — an ASCII diagram showing what crosses the system boundary (CLI args, stdin, config files, env vars, session files, HTTP to LLM API, stdout/stderr, filesystem writes, shell executions). External dependencies are listed explicitly.
- **Interface contracts** — the CLI contract (all flags including `--subagent`, `--plan`, `--quiet`, `--no-session`), the config schema, the session file JSON schema, the skill SKILL.md format, and all 12 tool parameter schemas.
- **Invariants** — numbered list of what must always be true regardless of implementation language: session atomicity, permission precedence, danger-gate behavior, loop detection rules, augmentation freshness, terminal safety, path safety, subagent recursion cap, quiet-mode output contract, ephemeral-run guarantees.
- **Edge cases** — what happens when things go wrong: malformed JSON from the LLM, corrupt session files, concurrent instances, missing config, API key resolution order, max-tokens truncation, subagent empty output, compact-then-resume, and interactions between the flags (e.g. `--plan` without `--subagent`, `--quiet` standalone, `--no-session` standalone).

### The 12 Tools

Each spec covers the full tool catalog:

| # | Tool | Purpose | Permission default |
|---|------|---------|-------------------|
| 1 | `read` | Read file with line numbers | allow |
| 2 | `write` | Create or overwrite a file | allow |
| 3 | `edit` | Exact string replacement in a file | allow |
| 4 | `bash` | Execute a local shell command | allow |
| 5 | `glob` | Find files matching a glob pattern | allow |
| 6 | `grep` | Search files with a regex | allow |
| 7 | `web_search` | Search the web via DuckDuckGo HTML | allow |
| 8 | `web_fetch` | Fetch URL content as text | allow |
| 9 | `remote_bash` | Execute a command on a remote host via SSH (key-auth only) | ask |
| 10 | `compact` | Free context by summarizing prior conversation | allow |
| 11 | `skill` | Load a skill's full instructions from SKILL.md | allow |
| 12 | `subagent` | Delegate a task to a child cluade with fresh context | allow |

### The CLI Flags

All specs cover the complete flag set:

| Flag | Short | Description |
|------|-------|-------------|
| `--model MODEL` | `-m` | LLM model name |
| `--base-url URL` | — | API base URL |
| `--api-key KEY` | — | API key (or env: `OPENAI_API_KEY`) |
| `--continue` | `-c` | Resume the most recent session |
| `--resume ID` | `-r` | Resume a specific session by ID |
| `--list-sessions` | — | List saved sessions |
| `--yes` | `-y` | Auto-approve all permission prompts |
| `--init` | — | Write a default config to `~/.cluade/config.json` |
| `--show-tools-json` | — | Debug: print raw response body and decoded tool calls |
| `--subagent` | — | Unattended child mode: quiet, ephemeral, ask→deny, dangercheck→deny |
| `--plan` | — | With `--subagent`: restrict toolset to read-only (read/grep/glob/web_search/web_fetch) |
| `--quiet` | — | Only the final answer to stdout; progress to stderr |
| `--no-session` | — | Do not persist a session file |
| `--help` | `-h` | Show help text and exit |

## Validity / Derivation

These specs were derived from a full source read of cluade's modules:

- `cluade.lua` — entry point, CLI parsing, config loading, REPL dispatch
- `agent.lua` — agent loop, system prompt assembly, augmentation management
- `tools.lua` — all 12 tool implementations (read, write, edit, bash, glob, grep, web_search, web_fetch, remote_bash, compact, skill, subagent)
- `provider.lua` — HTTP communication with OpenAI-compatible APIs via curl
- `store.lua` — session persistence (save/load/list), last_session pointer
- `loopdetect.lua` — stuck-agent detection (repeat detection, error cascade)
- `dangercheck.lua` — smart bash gate (catastrophic command escalation)
- `lineedit.lua` — interactive REPL with raw terminal, history, cursor movement
- `colors.lua` — ANSI color scheme for terminal output
- `skillimport.lua` — skill import and compatibility classification
- `marketplace.lua` — Claude Code plugin marketplace browser

Plus:

- `README.md` — the human-readable project specification
- The 18-file test suite — verifying the behaviors captured here

The Gherkin scenarios are not aspirational. Every `Given/When/Then` describes actual behavior observed in the source or explicitly documented in the README. Edge cases cover the interactions the code handles (e.g., the interplay of `--subagent`/`--plan`/`--quiet`/`--no-session` flags, subagent depth-1 recursion cap by construction, and compact-then-resume preservation).
