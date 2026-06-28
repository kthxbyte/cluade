# cluade Behavior Specification — Tier C: Loose Inspiration

> **Goal:** Capture the *essence* of cluade — a minimal, portable coding agent for
> constrained Linux devices — and redesign it from first principles for modern
> hardware and LLM capabilities. No commitment to the original tool set, CLI, or
> architecture. What would you build today if you started from the same constraints
> but with no legacy code?

---

## 1. Core Proposition

> A single-binary coding agent that runs on a router, a Pi, or a 10-year-old box.
> It talks to any LLM, uses the local shell and filesystem, and remembers your
> sessions. It's the smallest thing that's still genuinely useful.

| Constraint | Value |
|-----------|-------|
| Binary size | < 5 MB (statically linked or single script) |
| Runtime deps | None beyond the OS (no Python, no Node, no JVM) |
| Memory floor | Works in 32 MB RAM |
| Disk footprint | < 2 MB for the agent itself |
| Target OS | Linux (musl or glibc), including OpenWRT |
| CPU | Any architecture (ARM, MIPS, x86, RISC-V) |

---

## 2. System Boundaries

```
                           ┌────────────────────────────────────────────┐
  stdin / CLI args ───────▶│                                            │──▶ stdout (text + streaming)
  Config files            │              cluade                        │──▶ filesystem (read/write/edit)
  Env vars                │                                            │──▶ shell (local execution)
  Session DB              │                                            │──▶ shell (remote via SSH)
  Skill files ───────────▶│                                            │──▶ HTTP/HTTPS to LLM APIs
                           │                                            │──▶ HTTP/HTTPS to web (search/fetch)
                           └────────────────────────────────────────────┘
```

---

## 3. CLI Contract

### Feature: Command-line Interface

The CLI is designed for three usage modes: **one-shot** (single prompt, single response),
**interactive** (REPL with history), and **unattended** (child agent with clean stdout).

```
Feature: Command-line interface
  As a user
  I want a simple, memorable CLI
  So that I can get work done without reading docs
```

#### Scenario: One-shot mode

```
  When the user runs: cluade "fix the null pointer in auth.c"
  Then the agent processes the prompt, streams the response, and exits
  And the exit code reflects success (0) or error (non-zero)
```

#### Scenario: Interactive mode

```
  When the user runs: cluade
  Then a REPL starts with a prompt showing the model name
  And the user can enter multiple prompts in sequence
  And Ctrl+D on an empty line exits
  And Ctrl+C returns a fresh prompt
```

#### Scenario: Pipe mode

```
  When the user runs: cat error.log | cluade --pipe "explain these errors"
  Then the piped content is included as context with the prompt
  And the response is written to stdout
```

#### Scenario: File input

```
  When the user runs: cluade -f code.c "add error handling"
  Then code.c is read and included as context
  And multiple -f flags include multiple files
```

#### Scenario: Model selection

```
  When the user runs: cluade -m llama3 "prompt"
  Then the specified model is used
  And -m accepts short names that resolve via a built-in registry
```

#### Scenario: Session management

```
  When the user runs: cluade --resume
  Then the most recent session continues
  When the user runs: cluade --resume <id>
  Then the named session is loaded
  When the user runs: cluade --sessions
  Then all sessions are listed with id, date, message count, and working directory
```

#### Scenario: Config management

```
  When the user runs: cluade --init
  Then a default config is generated at ~/.cluade/config.json
  When the user runs: cluade --config <path>
  Then config is loaded from that path
```

#### Scenario: Help

```
  When the user runs: cluade -h
  Or: cluade --help
  Then help is printed with usage, options, and examples
```

#### Scenario: Version and system info

```
  When the user runs: cluade --version
  Then version, build info, and detected capabilities are printed
```

#### Scenario: Unattended mode

```
  When cluade is invoked with --subagent
  Then the agent runs without a REPL
  And progress chatter goes to stderr
  And only the final assistant message goes to stdout
  And no session file is persisted
  And permissions that would prompt a human become hard denies
```

---

## 4. Agent Loop Contract

### Feature: Agent Execution

The agent loop is the heart of the system. It sends messages to an LLM, receives
responses (text + tool calls), executes tools, and feeds results back.

```
Feature: Agent execution loop
  As a user
  I want an agent that iteratively works on my task
  So that complex multi-step work is automated
```

#### Scenario: Basic loop lifecycle

```
  Given a user prompt
  When the agent runs:
    1. Assemble the system message (persona + environment + skills + instructions)
    2. Append the user message to the conversation
    3. Call the LLM with the conversation and available tools
    4. Stream text output to the user in real-time
    5. If the LLM returns tool calls:
       a. Display each tool call with its name and parameters
       b. Check the permission system for each call
       c. Execute or deny each call
       d. Append the tool results to the conversation
       e. Go to step 3
    6. If the LLM finishes (finish_reason = "stop"), exit the loop
    7. If loop detection trips, halt with a diagnostic message
    8. If max steps reached, halt with a message
  Then save the session
  And print a status summary
```

#### Scenario: System message composition

```
  Given a session starts
  When the system message is assembled
  Then it includes:
    - Agent persona: "You are cluade, a coding agent running on Linux..."
    - Environment context: available tools, shell type, OS details
    - Available skills: scanned from skill directories
    - User instructions: from AGENTS.md / CLAUDE.md / GEMINI.md (nearest ancestor)
    - Global instructions: from ~/.cluade/
  And the augmentations section is marked so it can be rebuilt each turn
  And augmentations never duplicate across resumes or compactions
```

#### Scenario: Streaming output

```
  Given the LLM supports streaming
  When text content arrives
  Then it is written to stdout token-by-token
  And reasoning/thinking content is displayed in a distinct, dimmed style
  And the user sees progressive output, not a spinner
```

#### Scenario: Non-streaming fallback

```
  Given the LLM or provider does not support streaming
  When a response is received
  Then step indicators show progress: "[step N] thinking..."
  And the full response is displayed when it arrives
  And elapsed time is shown for each step
```

#### Scenario: Tool execution display

```
  Given the LLM calls a tool
  When the tool executes
  Then a label shows: "[tool:name] <key parameters>"
  And the result is displayed below
  And long results are truncated with an indicator
```

#### Scenario: Loop detection — repeated calls

```
  Given the agent calls the same tool with identical arguments
  When it does so 3 times in a row
  Then a warning is injected: "You appear to be in a loop..."
  When it does so a 4th time after the warning
  Then the turn halts with a stop message
  And the session can be resumed with "continue"
```

#### Scenario: Loop detection — consecutive errors

```
  Given the agent's tool calls return errors
  When 4 consecutive calls all return errors
  Then a warning is injected: "Reconsider your approach..."
  When a 5th error follows
  Then the turn halts with a stop message
  And a single successful call resets the error count
```

#### Scenario: Conversation compaction

```
  Given the conversation context approaches the model's limit
  When the LLM calls the compact tool with a summary
  Then conversation history is replaced with:
    - The system prompt base
    - A summary of prior work
    - The most recent exchange
  And work continues with freed context
  And the per-turn augmentations (skills, instructions) survive the compaction
```

#### Scenario: Context threshold nudging

```
  Given the estimated context exceeds 85% of the model's limit
  When a step completes
  Then the agent displays a suggestion to compact
  And the user or LLM can choose to compact or continue
```

#### Scenario: Multi-turn persistence

```
  Given an agent run completes
  When the session is saved
  Then all messages, tool calls, and results are preserved
  And resuming the session continues from exactly where it left off
  And the system message augmentations are rebuilt fresh each turn
```

#### Scenario: Crash recovery

```
  Given the agent is processing a session
  When a crash or kill occurs mid-run
  Then at most one turn of work is lost
  And resuming the session restores all prior turns
```

---

## 5. Tool System Contract

### Feature: Extensible Tool Framework

Tools are the agent's hands. The core set covers filesystem, shell, search, and
skill loading. Additional tools can be added via configuration.

```
Feature: Tool execution
  As an agent
  I want a standard interface for all tools
  So that I can interact with the system predictably
```

#### Scenario: Tool contract

```
  Given any tool
  When it is called
  Then it receives: the current working directory, a parameters table
  And it returns: { status: "ok"|"error"|"compacted", output?: string, error?: string }
  And errors are never fatal to the agent loop
```

### Feature: Core Tools

#### Scenario: read — file reading with line numbers

```
  Given a file exists at <path>
  When the agent calls read(filePath=<path>)
  Then the file content is returned with each line prefixed "N: "
  And the output is capped at a configurable maximum size
  When the file does not exist
  Then an error is returned
```

#### Scenario: write — file creation and overwrite

```
  When the agent calls write(filePath=<path>, content=<text>)
  Then the file is created (with parent directories if needed)
  And existing files are overwritten
  And the operation result is returned
```

#### Scenario: edit — surgical string replacement

```
  Given a file contains specific text
  When the agent calls edit(filePath=<path>, oldString=<old>, newString=<new>)
  Then exactly one occurrence of oldString is replaced with newString
  And if oldString appears multiple times and replaceAll is not set, an error is returned
  When replaceAll is true
  Then all occurrences are replaced
  When oldString is not found
  Then an error is returned
```

#### Scenario: bash — shell command execution

```
  When the agent calls bash(command=<cmd>, workdir?=<dir>)
  Then the command executes in the specified working directory
  And stdout and stderr are captured and returned
  And the exit code is appended for non-zero exits
  And a configurable timeout applies (default 120s)
  And the command runs in a subshell with resource limits
```

#### Scenario: glob — file pattern matching

```
  When the agent calls glob(pattern=<glob>, path?=<dir>)
  Then files matching the pattern are returned
  And ** enables recursive directory search
  And results are capped at a configurable maximum
  And the pattern supports standard glob syntax (*, ?, **, [abc], {a,b})
  And a relative pattern resolves against path (or cwd)
  And an absolute pattern is used as-is
```

#### Scenario: grep — pattern search in files

```
  When the agent calls grep(pattern=<regex>, path?=<dir>, include?=<fileglob>)
  Then matching lines with file paths and line numbers are returned
  And the include parameter filters by filename pattern
  And results are capped at a configurable maximum
```

#### Scenario: web_search — internet search

```
  When the agent calls web_search(query=<text>)
  Then search results with titles, snippets, and URLs are returned
  And the search uses a privacy-respecting engine
  And results are capped at a reasonable number
```

#### Scenario: web_fetch — URL content retrieval

```
  When the agent calls web_fetch(url=<url>)
  Then the URL content is fetched and returned as text
  And response size is capped (configurable, default 32KB)
  And redirects are followed
  And TLS is enforced for HTTPS URLs
```

#### Scenario: remote_bash — SSH command execution

```
  When the agent calls remote_bash(host=<host>, command=<cmd>, username?=<user>, port?=<port>)
  Then the command is executed on the remote host via SSH
  And key-based authentication is used (no password support)
  And output and exit code are returned
```

#### Scenario: skill — on-demand instruction loading

```
  When the agent calls skill(name=<skillname>)
  Then the skill's instruction content is returned
  And the skill must exist in the scanned skill directories
  When the skill does not exist
  Then an error is returned listing available skills
```

#### Scenario: compact — conversation summarization

```
  When the agent calls compact(summary=<text>)
  Then the conversation history is compacted around the summary
  And the compacted state includes the system prompt base + summary + most recent exchange
  And context is freed for further work
```

### Feature: Tool Extensions

#### Scenario: User-defined tools

```
  Given a YAML/JSON file defining a new tool (schema + command to run)
  When cluade loads the tool definition
  Then the tool appears in the LLM's available tools list
  And calling the tool executes the defined command
  And the tool respects the permission system
```

#### Scenario: Tool permission defaults

```
  When a new tool is defined
  And no explicit permission is set
  Then the tool defaults to "ask" (safe default)
```

---

## 6. Permission System Contract

### Feature: Three-Level Safety

```
Feature: Permission model
  As a user
  I want fine-grained control over what the agent can do
  So that I can trust it with my system
```

#### Scenario: Allow mode

```
  Given a tool is set to "allow"
  When the agent calls it
  Then it executes without user confirmation
```

#### Scenario: Ask mode

```
  Given a tool is set to "ask"
  When the agent calls it
  Then the user is prompted with the tool name, key parameters, and a [y/N] choice
  And "y" or "yes" approves execution
  And any other response denies it
  And the terminal is temporarily set to cooked mode for the prompt
  And the prior terminal mode is restored after the prompt
```

#### Scenario: Deny mode

```
  Given a tool is set to "deny"
  When the agent calls it
  Then execution is refused with an error message
```

#### Scenario: Permission precedence

```
  Given permissions are set in multiple places
  Then CLI flags (--yes) override config files
  And config files override built-in defaults
  And only the tools named in config change; others keep their defaults
```

#### Scenario: Dangerous command detection — smart bash gate

```
  Given bash is set to "allow"
  When the agent calls a catastrophic command:
    - Recursive force-remove of a system/home/root path (rm -rf /, rm -rf ~, rm -rf *)
    - Writing to a raw block device (dd of=/dev/sda, > /dev/mmcblk0)
    - Filesystem formatting (mkfs, mkfs.ext4)
    - Power state changes (shutdown, reboot, halt, poweroff)
    - Fork bombs (:(){ :|:& };:)
    - Network downloads piped into a shell (curl ... | sh, wget ... | bash)
    - Command substitution executing a download (sh -c "$(curl ...)")
  Then the permission is temporarily escalated to "ask"
  And the prompt explains why the command was flagged
  And safe variants (rm -rf ./build, dd to a file, curl -o file) are not escalated
  And the detector prefers false negatives to false positives
```

#### Scenario: Unattended permission rules

```
  Given the agent is running in unattended (--subagent) mode
  When a tool's base permission is "ask"
  Then it becomes "deny" — there is no human to approve it
  When a dangerous command is detected
  Then it becomes a hard "deny" — no prompt, no bypass
  And "allow" stays "allow" — the knife still cuts
  And "deny" stays "deny"
```

---

## 7. Provider Abstraction Contract

### Feature: LLM Backend Abstraction

The agent works with multiple LLM backends through a uniform interface.

```
Feature: Provider abstraction
  As the system
  I want to support multiple LLM backends
  So that users can choose their preferred provider
```

#### Scenario: Provider interface

```
  Given any LLM provider
  When the agent needs a completion
  Then it calls: provider.chat(messages, tools, options) → response
  And the response contains: content, reasoning_content?, tool_calls?, finish_reason, usage?
  And the provider handles authentication, timeouts, and error translation
```

#### Scenario: OpenAI-compatible provider

```
  Given a base_url pointing to an OpenAI-compatible API
  When the agent makes a request
  Then the standard /chat/completions endpoint is used
  And authentication is via Bearer token
  And the request format follows the OpenAI chat completions schema
  And thinking/reasoning mode is enabled by default
  And transport errors surface the HTTP status and underlying error
```

#### Scenario: Local model provider

```
  Given a local model server (e.g., Ollama, llama.cpp)
  When the agent makes a request
  Then the provider adapts to the local API conventions
  And no authentication is required
```

#### Scenario: Provider fallback

```
  Given multiple providers are configured
  When the primary provider fails
  Then the agent falls back to a secondary provider
  And the user is informed of the fallback
```

#### Scenario: Transport

```
  Given the runtime has no HTTP library
  When making API requests
  Then the provider uses the system's HTTP client (curl or built-in)
  And request bodies are constructed from the conversation
  And response bodies are parsed as JSON
  And the provider handles HTTP/2 incompatibility gracefully
```

---

## 8. Session Management Contract

### Feature: Persistent Sessions

```
Feature: Session management
  As a user
  I want my work saved across invocations
  So that I never lose context
```

#### Scenario: Session lifecycle

```
  When a session is created:
    - A unique ID is generated (timestamp + random)
    - The working directory is recorded
    - The session is saved to ~/.cluade/sessions/<id>.json
    - The last_session pointer is updated
  When the agent runs:
    - The session is saved after every agent turn
    - Crash recovery: at most one turn of work is lost
  When a session is resumed:
    - Full message history is restored
    - System augmentations are rebuilt fresh
    - The agent continues from where it left off
```

#### Scenario: Session format

```
  Given a persisted session
  Then it is stored as JSON:
  {
    "id": "20260529-201630-1000",
    "cwd": "/home/user/project",
    "created": "2026-05-29 20:16:30",
    "messages": [
      {"role": "system", "content": "You are cluade..."},
      {"role": "user", "content": "fix the bug"},
      {"role": "assistant", "content": "...", "tool_calls": [...]},
      {"role": "tool", "tool_call_id": "...", "content": "{...}"}
    ],
    "steps": 5,
    "total_tokens": 12345,
    "context_tokens": 8200
  }
```

#### Scenario: Session listing

```
  When the user runs: cluade --sessions
  Then all sessions are listed with id, created date, message count, and cwd
  And sessions are sorted by modification time (newest first)
```

#### Scenario: Ephemeral sessions

```
  Given the agent is invoked with --no-session or --subagent
  When the run completes
  Then no session file is written
  And the last_session pointer is not updated
  And no trace remains on disk
```

#### Scenario: Session cleanup

```
  When the user runs: cluade --prune-sessions 30
  Then sessions older than 30 days are deleted
  And a summary of pruned sessions is printed
```

---

## 9. Skill System Contract

### Feature: Pluggable Skills

Skills are on-demand instruction sets that extend the agent's capabilities.
They follow the [Agent Skills](https://agentskills.io) open standard.

```
Feature: Skill system
  As a user
  I want to extend the agent with specialized workflows
  So that it can handle domain-specific tasks
```

#### Scenario: Skill discovery

```
  Given SKILL.md files in ~/.cluade/skills/ or ./.cluade/skills/
  When the agent starts
  Then all skills are scanned and their names + descriptions listed in the system prompt
  And skills with disable-model-invocation: true are excluded from automatic discovery
  And local project skills override global skills of the same name
```

#### Scenario: Skill loading

```
  Given a discovered skill "brainstorming"
  When the agent calls skill("brainstorming")
  Then the SKILL.md body (after frontmatter) is loaded and returned
  And the agent can follow the skill's instructions
```

#### Scenario: Skill installation

```
  When the user runs: cluade --install-skill <url-or-path>
  Then the skill is copied to ~/.cluade/skills/
  And a compatibility report is printed showing:
    - [OK  ] full — declared tools all supported
    - [OK* ] portable — no tools declared, no runtime deps
    - [PART] partial — some unsupported tools listed
    - [LTD ] limited — bundles Python/Node scripts or plugin.json
  And skills requiring unavailable runtimes are flagged
```

#### Scenario: Skill marketplace browsing

```
  When the user runs: cluade --browse-skills <marketplace-url>
  Then all plugins in the marketplace are listed with compatibility ratings
  And per-plugin counts of usable skills, commands, agents are shown
  And hooks, MCP servers, and LSP servers are flagged as unconsumed
  And the user can install compatible skills
```

---

## 10. Subagent & Parallelism Contract

### Feature: First-Class Subagents

Subagents are a first-class mechanism for task isolation and parallelism.
A parent agent delegates self-contained tasks to child agents that run as
separate processes with their own context windows.

```
Feature: Subagent delegation
  As an agent
  I want to delegate independent work to child agents
  So that my context stays clean and parallel work is possible
```

#### Scenario: Spawning a subagent

```
  Given the parent agent has the subagent tool available
  When the agent calls subagent(prompt=<task>, mode=<"build"|"plan">)
  Then a child cluade process is spawned in unattended mode
  And the child's progress chatter goes to stderr (passthrough)
  And only the child's final answer is captured and returned to the parent
  And the child runs with a fresh context window
```

#### Scenario: Build mode (default)

```
  Given a subagent is spawned with mode="build"
  Then the child has the full toolset:
    read, write, edit, bash, glob, grep, web_search, web_fetch, remote_bash, compact, skill
  And the child can create, edit, and delete files unattended
  And dangerous commands are hard-denied (no human to approve)
```

#### Scenario: Plan mode (read-only)

```
  Given a subagent is spawned with mode="plan"
  Then the child has a read-only toolset:
    read, glob, grep, web_search, web_fetch
  And the child cannot write files, edit files, or execute shell commands
  And the child can research, review, and report without side effects
```

#### Scenario: Recursion cap

```
  Given a subagent's toolset
  Then the subagent tool is NOT included in the child's available tools
  And therefore a subagent cannot spawn another subagent
  And recursion depth is capped at 1 by construction — no counter needed
```

#### Scenario: Unattended safety

```
  Given a subagent runs without a human
  Then any tool whose permission is "ask" becomes "deny"
  And dangerous bash commands are hard-denied (not prompted)
  And remote_bash is denied (no human to approve SSH access)
  And write, edit, and ordinary bash are still allowed (the knife still cuts)
```

### Feature: Parallelism

```
Feature: Shell-driven parallelism
  As a user
  I want to run multiple subagents in parallel
  So that independent work completes faster
```

#### Scenario: Parallel dispatch from the shell

```
  Given the user wants parallel work
  When they run multiple cluade instances with shell job control:
    cluade "audit auth.c" &
    cluade "audit db.c" &
    cluade "audit api.c" &
    wait
  Then each agent runs independently in its own process
  And results are collected when all complete
```

#### Scenario: Parallel dispatch via xargs

```
  Given a list of independent tasks
  When the user runs: echo "task1\ntask2\ntask3" | xargs -P3 -I{} cluade "{}"
  Then tasks run in parallel with the specified concurrency
  And each result goes to its own output file or stdout
```

#### Scenario: Resource awareness

```
  Given a constrained device with limited RAM
  When parallel subagents are spawned
  Then the user controls parallelism explicitly via shell primitives (& and wait)
  And the system does not automatically spawn more agents than the device can handle
  And the resource cost is always visible and operator-controlled
```

---

## 11. Output and UX Contract

### Feature: Terminal User Experience

```
Feature: Terminal output
  As a user
  I want clear, color-coded, structured output
  So that I can understand what the agent is doing at a glance
```

#### Scenario: Color system

```
  When output is displayed:
  Then step progress is shown in cyan
  And tool executions are shown in green
  And errors are shown in red
  And warnings are shown in yellow
  And informational messages are dimmed
  And the REPL prompt is in a distinct color
  And all color is optional (--no-color flag disables it)
  And output uses clean UTF-8 (arrows, em-dashes, box-drawing characters)
```

#### Scenario: Progress indication

```
  Given the agent is processing
  When a step begins
  Then "[step N] thinking..." is displayed in cyan
  And if streaming, the text appears progressively below
  And if the LLM is thinking/reasoning, a dimmed indicator shows elapsed time
  And if non-streaming, "[took Xs]" is shown when the response arrives
```

#### Scenario: Tool execution display

```
  When a tool executes:
  Then "[tool:<name>] <key params>" is displayed in green
  And the tool's output appears below
  And skill calls show "using skill: <name>"
  And compact calls omit their (long) summary from the label
  And long arguments are truncated with "..." for readability
```

#### Scenario: Permission prompt

```
  When a tool requires user confirmation
  Then the prompt shows: "Allow <tool>: <key params>? [y/N]"
  And dangerous commands include the flag reason: "Allow bash: <cmd> [flagged: <reason>]? [y/N]"
  And the terminal is in cooked mode so the answer is visible and editable
```

#### Scenario: Status bar

```
  Given an agent run completes
  When the loop exits
  Then a status line shows:
    "-- <model> — <tokens> tokens — <X%> context — <time>s"
  And the context percentage warns in yellow above 80%, red above 95%
```

#### Scenario: Loop detection messages

```
  When loop detection warns the model:
  Then the message is displayed in yellow
  And the message tells the model to change approach or stop
  When loop detection stops the turn:
  Then a message says the model appears stuck
  And suggests sending "continue" to resume
```

#### Scenario: Interactive REPL line editing

```
  Given the user is in the interactive REPL
  Then up/down arrows recall previous commands from history
  And left/right/home/end move the cursor for inline editing
  And backspace and Delete remove characters
  And bracketed paste inserts multi-line blocks correctly
  And the display survives terminal scrolling (no duplicated lines)
  And history is in-memory only (100 entries, no consecutive duplicates)
```

#### Scenario: Slash commands

```
  Given the user is in the interactive REPL
  When they type /help
  Then available commands are listed
  When they type /exit
  Then the REPL exits
  When they type /sessions
  Then saved sessions are listed
  When they type /resume <id>
  Then the named session is loaded
  When they type /new
  Then a fresh session is created
  When they type /model <name>
  Then the active model is changed
```

---

## 12. Invariants

These hold regardless of implementation:

1. **No data loss:** Session is saved after every agent turn. A crash loses at most one turn.

2. **Permission safety:** The permission system gates all tool execution. Defaults are safe (remote_bash requires confirmation). --yes is an explicit opt-out. Unattended mode hard-denies anything that would prompt.

3. **Terminal safety:** Raw terminal mode is always restored on exit, even on crash or signal. Permission prompts temporarily switch to cooked mode for canonical, echoed input.

4. **Provider independence:** The agent works with any OpenAI-compatible API. No provider-specific code in the core loop.

5. **Resource awareness:** The agent estimates context usage and suggests compaction before hitting limits. It never silently exceeds context windows.

6. **Idempotent augmentations:** The skills list and user instructions are rebuilt each turn and never duplicate, even across resumes and compactions.

7. **Progressive output:** The user sees something happening immediately (streaming text or step indicators). No long silent waits.

8. **Graceful degradation:** On low-resource systems, features degrade (no streaming, simpler token estimation) but the core loop still works.

9. **Recursion safety:** Subagents cannot spawn subagents. Depth is capped at 1 by construction — the subagent tool is omitted from a subagent's toolset.

10. **UTF-8 clean:** All output uses real Unicode characters (arrows →, em-dashes —, box-drawing ─). No "?" substitutions. JSON encoding preserves UTF-8 losslessly.

11. **Deterministic loop detection:** Loop detection uses consecutive counts, not confidence scores. Any behavior change resets the streak. Reaction is warn-once-then-stop.

12. **Conservative danger detection:** The smart bash gate prefers false negatives to false positives. It protects against irreversible mistakes without babysitting routine work.

---

## 13. What Tier C Drops from the Original

These are deliberate omissions — things the original cluade does that a clean-slate
design would handle differently or not at all:

| Original Feature | Tier C Approach |
|-----------------|-----------------|
| curl-based HTTP via io.popen | Native HTTP client in the implementation language |
| Hardcoded tool list in agent.lua | Tool registry with user-extensible definitions |
| `#text / 3.5` token estimation | Model-specific tokenizer or tiktoken port |
| Byte-based line editing | Unicode grapheme-cluster-aware editing |
| No streaming support | Streaming is the default; non-streaming is the fallback |
| Shell-based glob (`ls`, `find`) | Native glob implementation |
| DuckDuckGo HTML scraping for search | Configurable search backend with proper API |
| Hardcoded danger patterns | Configurable danger pattern file with regex rules |
| In-memory-only REPL history | Persistent history file |
| Lua-specific module system | Single binary, no runtime dependency |
| Session format without version | Versioned session format for forward compatibility |
| No daemon mode | Optional daemon mode for IDE integrations |
| One LLM provider at a time | Multi-provider with fallback chain |
| Marketplace as separate script | Built-in marketplace browsing and skill installation |
| Manual slash commands only | Extensible command system with user-defined commands |
| No signal handling | Graceful shutdown on SIGINT/SIGTERM, save session before exit |
| No logging | Structured log output (JSON lines) for debugging and auditing |

---

## 14. What Tier C Adds

| New Capability | Description |
|---------------|-------------|
| **Daemon mode** | Listen on a Unix socket for IDE/editor integration |
| **Multi-provider** | Configure primary + fallback LLM providers with automatic failover |
| **Streaming** | Real-time token-by-token output from the LLM |
| **Diff display** | Show unified diffs for file edits (additions in green, deletions in red) |
| **Tool extensions** | User-defined tools via config files (YAML/JSON schema + command) |
| **Pipe mode** | Accept stdin as context: `cmd | cluade --pipe "explain"` |
| **File context** | Include files as context: `cluade -f code.c -f header.h "refactor"` |
| **Session search** | Find sessions by content: `cluade --sessions --filter "keyword"` |
| **Session pruning** | Remove old sessions: `cluade --prune-sessions 30` |
| **Config profiles** | Named config presets: `cluade --profile openai` vs `--profile local` |
| **Model registry** | Short names resolve to full model IDs: `-m haiku` → `claude-3-5-haiku-latest` |
| **Signal handling** | Graceful shutdown on SIGINT/SIGTERM, save session before exit |
| **Persistent history** | REPL history saved to ~/.cluade/history across sessions |
| **Logging** | Structured JSON-lines log output for debugging and auditing |
| **Unicode-aware editing** | Grapheme-cluster-aware cursor movement and rendering |
| **Versioned sessions** | Session format includes version for forward/backward compatibility |
| **Built-in marketplace** | `cluade --browse-skills` and `cluade --install-skill` as built-in commands |
| **Extensible commands** | User-defined slash commands in the REPL |
