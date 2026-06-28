# cluade Behavior Specification → Tier B: Faithful Port

> **Goal:** Same architecture, same 12-tool set, same user experience. Free to improve
> implementation quality: native HTTP library, model-specific tokenizer, Unicode-aware
> line editing, SSE streaming, standard argument parsing, persisted history. This
> spec describes WHAT the system does, not HOW it is wired internally.

---

## 1. System Boundaries

```
                          ┌──────────────────────────────────────────────────┐
  CLI args / stdin ──────▶│                                                  ├──────▶ stdout / stderr
  Config files           │                                                  │──────▶ filesystem writes
  Env vars               │                    cluade                        │──────▶ shell executions
  Session files ◀───────▶│                                                  │◀─────▶ HTTP to LLM API
                          └──────────────────────────────────────────────────┘
```

**External dependencies:** A language runtime with an HTTP client and a JSON
parser. The system MUST NOT require Python, Node.js, or a heavy runtime — the
core constraint is "runs on OpenWRT / Raspberry Pi class hardware."

The system talks to any OpenAI-compatible chat completions endpoint. It is
model-agnostic: a remote provider (e.g. DeepSeek), a local model server
(Ollama, llama.cpp), or any other compatible API all work.

---

## 2. CLI Contract

### Feature: Command-line Interface

```
Feature: Command-line interface
  As a user
  I want intuitive, well-documented CLI arguments
  So that I can control the agent from the terminal
```

#### Scenario: One-shot prompt
```
  When the user runs: cluade "write hello world in bash"
  Then the agent processes the prompt and exits
  And a status line is printed showing model, tokens, context %, and elapsed time
```

#### Scenario: One-shot with explicit model
```
  When the user runs: cluade -m gpt-4o "explain this"
  Then the model "gpt-4o" is used for this invocation
```

#### Scenario: Multiple positional args joined as prompt
```
  When the user runs: cluade fix the bug in auth.lua
  Then the prompt is "fix the bug in auth.lua"
```

#### Scenario: Help
```
  When the user runs: cluade -h
  Or: cluade --help
  Then help text is printed and the process exits with code 0
```

#### Scenario: Version
```
  When the user runs: cluade --version
  Then the version string is printed
  And the process exits with code 0
```

#### Scenario: Initialize config
```
  When the user runs: cluade --init
  Then a default config file is written to ~/.cluade/config.json
  And the path is printed
  And the process exits with code 0
```

#### Scenario: Continue most recent session
```
  Given a previous session exists
  When the user runs: cluade -c
  Then the most recent session is loaded with all message history
```

#### Scenario: Resume specific session
```
  Given session "20260529-201630-1000" exists
  When the user runs: cluade -r 20260529-201630-1000
  Then that session is loaded with all message history
```

#### Scenario: List sessions
```
  Given sessions exist
  When the user runs: cluade --list-sessions
  Then each session is printed with id, creation time, message count, and working directory
  And sessions are ordered most-recent first
```

#### Scenario: Auto-approve permissions
```
  When the user runs: cluade -y "dangerous operation"
  Then bash, remote_bash, and write tools run without permission prompts
```

#### Scenario: Debug tool JSON dump
```
  When the user runs: cluade --show-tools-json "prompt"
  Then each response's raw wire body, decoded tool calls, and compact one-line
    summaries are printed as the run progresses
```

#### Scenario: Interactive REPL
```
  When the user runs: cluade
  Then a new session is created
  And a prompt appears showing the session id and model name
  And the user can type prompts and slash commands
```

#### Scenario: Non-TTY stdin
```
  Given stdin is not a terminal
  When the user pipes input: echo "prompt" | cluade
  Then line editing is disabled gracefully
  And input is read with basic line reading
```

### Feature: Subagent and Quiet-mode Flags

```
Feature: Unattended subprocess preset
  As a parent process (or a human operator)
  I want to invoke cluade as a one-shot child subagent
  So that the parent can delegate work with a clean output contract
```

#### Scenario: Subagent mode preset
```
  When the user or parent process runs: cluade --subagent "audit the codebase"
  Then the agent runs in unattended mode:
    - Progress output goes to stderr, not stdout
    - Only the final assistant answer is written to stdout
    - No session file is persisted to disk (ephemeral)
    - The `subagent` tool is omitted from the child's toolset
```

#### Scenario: Standalone quiet mode
```
  When the user runs: cluade --quiet "find todos"
  Then progress chatter goes to stderr
  And only the final answer is written to stdout
  But a session is still persisted (unlike --subagent)
```

#### Scenario: Standalone no-session mode
```
  When the user runs: cluade --no-session "one-off refactor"
  Then no session file is written to disk
  But output is normal (progress visible, status bar printed)
```

#### Scenario: Plan subagent (read-only)
```
  When a parent agent spawns a subagent with mode "plan"
  Or the user runs: cluade --subagent --plan "audit the codebase"
  Then the agent's toolset is restricted to:
    read, grep, glob, web_search, web_fetch
  And write, edit, bash, remote_bash, compact, skill, and subagent are unavailable
```

#### Scenario: Build subagent (full toolset minus subagent)
```
  When a parent agent spawns a subagent with mode "build" (the default)
  Then the agent's toolset includes all tools except `subagent`
  And the agent can create, edit, and delete files unattended
  And ordinary bash commands execute without prompts
```

#### Scenario: Recursion is capped by construction at depth 1
```
  Given a subagent is running
  When it receives a task
  Then the `subagent` tool is absent from its toolset
  So it cannot spawn a grandchild subagent
  And no counter or depth tracker is needed to enforce the cap
```

#### Scenario: Subagent unattended permission rule
```
  Given an agent is running in --subagent mode
  When a tool's base permission is "ask"
  Then it becomes "deny" — there is no human to approve
  When a bash command is flagged by the danger check
  Then it is hard-denied rather than prompted
  When a tool's base permission is "allow"
  Then it stays "allow" — the knife still cuts
```

---

## 3. Config Loading Contract

### Feature: Configuration Resolution

```
Feature: Configuration loading
  As a user
  I want configuration merged from global, project, and CLI sources
  So that I have sensible defaults with targeted overrides
```

#### Scenario: Three-tier merge
```
  Given hardcoded defaults exist
  And ~/.cluade/config.json sets global preferences
  And ./.cluade/config.json in the project sets project preferences
  And CLI flags set invocation preferences
  When config is loaded
  Then precedence is: CLI flags > project config > global config > hardcoded defaults
  And sub-tables (like permissions) are deep-merged
  And non-overridden values retain defaults
```

#### Scenario: Config validation
```
  Given config.json contains invalid values (e.g., max_steps: -1)
  When config is loaded
  Then a warning is printed
  And the invalid value falls back to its default
```

#### Scenario: Missing config files
```
  Given no config files exist anywhere
  When config is loaded
  Then all defaults are used with no errors
```

#### Scenario: Permission overrides merge per-tool
```
  Given config sets permissions.bash to "deny"
  When config is loaded
  Then only bash is affected; all other tools keep their default permissions
```

#### Scenario: API key resolution order
```
  Given multiple API key sources exist
  Then precedence is: --api-key flag > config.json api_key > OPENAI_API_KEY env > ANTHROPIC_API_KEY env
```

---

## 4. Session Management Contract

### Feature: Session Persistence

```
Feature: Session management
  As a user
  I want sessions persisted reliably
  So that I never lose work across invocations
```

#### Scenario: New session creation
```
  When a session is created
  Then it receives a unique id in format YYYYMMDD-HHMMSS-NNNN
  And it records the absolute working directory
  And it has an empty message list
  And it is immediately persisted to disk (unless ephemeral)
```

#### Scenario: Session save after every agent run
```
  Given an agent run completes (any outcome)
  When the run finishes
  Then the session is saved to disk including all messages, step count, and token counts
  Unless the run is ephemeral (--subagent or --no-session)
```

#### Scenario: Session resume restores full state
```
  Given a persisted session with message history
  When the session is resumed
  Then the system prompt is rebuilt fresh (augmentations regenerated on each turn)
  And all historical messages are preserved
  And the agent continues from where it left off
```

#### Scenario: Session listing
```
  Given persisted sessions exist
  When sessions are listed
  Then each session shows: id, creation time, message count, working directory
  And the last_session pointer tracks the most recently active session
```

#### Scenario: Session export/import
```
  Given a session file
  When the user exports it
  Then a portable JSON file is produced
  And the same file can be imported on another machine
```

#### Scenario: Session pruning
```
  Given many old sessions exist
  When the user runs: cluade --prune-sessions 30
  Then sessions older than 30 days are removed
  And a summary of pruned sessions is printed
```

#### Scenario: Ephemeral run leaves no trace
```
  Given the agent runs with config.ephemeral = true
  When the run completes
  Then no session file is written to disk
  And the last_session pointer is not updated
```

---

## 5. Interactive REPL Contract

### Feature: Line Editing

```
Feature: Interactive REPL
  As a user
  I want a full-featured line editor
  So that I can compose complex prompts comfortably
```

#### Scenario: Basic input with Unicode
```
  When the user types "hello 🦀" and presses Enter
  Then the full Unicode string is returned
  And cursor positioning accounts for multi-byte characters and wide characters (e.g. CJK)
```

#### Scenario: History navigation
```
  Given history contains previous commands
  When the user presses Up
  Then the most recent command appears
  And pressing Up again shows older commands
  And pressing Down returns toward the current draft
  And the current draft is restored when reaching the newest entry
```

#### Scenario: Cursor movement
```
  Given a line with text
  When the user presses Left/Right arrows
  Then the cursor moves one grapheme cluster at a time
  And Home moves to position 0
  And End moves to the end of the line
```

#### Scenario: Editing operations
```
  When the user presses Backspace
  Then the character before the cursor is deleted
  When the user presses Delete
  Then the character at the cursor is deleted
```

#### Scenario: Bracketed paste
```
  When the user pastes multi-line content
  Then newlines in the paste are converted to \n
  And the full text is inserted at the cursor position
  And the paste is bracketed so the terminal doesn't interpret escape sequences
```

#### Scenario: Ctrl+C clears line
```
  When the user presses Ctrl+C
  Then "^C" is printed and a new empty prompt appears
```

#### Scenario: Ctrl+D on empty line exits
```
  Given the input line is empty
  When the user presses Ctrl+D
  Then the REPL exits gracefully
  And the terminal is restored to cooked mode
```

#### Scenario: History deduplication and cap
```
  Given a command is identical to the most recent history entry
  When the command is entered
  Then it is not duplicated
  And history is capped at a configurable maximum (default 1000)
```

#### Scenario: Persistent history
```
  Given the REPL exits
  When a new cluade session starts
  Then arrow-key history from previous sessions is available
  And history is stored at ~/.cluade/history
```

### Feature: Slash Commands

```
Feature: Built-in slash commands
  As a user
  I want commands for session and model management
  So that I can control the agent from within the REPL
```

#### Scenario: /help
```
  When the user types /help
  Then all available slash commands are listed with brief descriptions
```

#### Scenario: /exit
```
  When the user types /exit
  Then the REPL exits and terminal settings are restored
```

#### Scenario: /sessions
```
  When the user types /sessions
  Then saved sessions are listed with id, creation time, message count, and cwd
```

#### Scenario: /resume <id>
```
  When the user types /resume 20260529-201630-1000
  Then the current session is replaced with the named session
  And "Resumed session <id>" is printed
```

#### Scenario: /new
```
  When the user types /new
  Then a fresh session is started with a new id
```

#### Scenario: /model <name>
```
  When the user types /model gpt-4o
  Then the active model changes to "gpt-4o" for the remainder of this session
```

#### Scenario: /config <key> <value>
```
  When the user types /config max_steps 50
  Then the runtime config is updated for this session
  And "max_steps = 50" is printed
```

---

## 6. Agent Loop Contract

### Feature: Agent Execution Loop

```
Feature: Agent run loop
  As a user
  I want the agent to process prompts through an LLM with tool calling
  So that coding tasks are automated iteratively
```

#### Scenario: System prompt assembly
```
  Given a session starts
  When the agent builds the system prompt
  Then it includes:
    - The agent persona and environment description
    - The list of available skills (scanned from ~/.cluade/skills/ and ./.cluade/skills/)
    - Project instructions from AGENTS.md / CLAUDE.md / GEMINI.md (walked up from cwd)
    - Global user instructions from ~/.cluade/
  And these augmentations are rebuilt fresh every turn
  And they never duplicate across resumes or compactions
```

#### Scenario: Agent loop lifecycle
```
  Given a user prompt is received
  When the agent runs:
    1. Messages are sent to the LLM with tool definitions for the current toolset
    2. The LLM responds with text and/or tool calls
    3. Text is streamed to the user token-by-token in real-time
    4. Reasoning content (thinking) is displayed in a dimmed style with elapsed time
    5. Tool calls are displayed with green execution labels
    6. Each tool call is checked against permissions; the user is prompted for "ask" tools
    7. Tool results are appended to the conversation as JSON
    8. The loop detector evaluates the step's calls for stuck patterns
    9. If context is above the compaction threshold, a nudge is displayed
    10. Steps repeat until: model finish_reason is "stop", loop detection halts, or
        the max_steps safety backstop is reached
  Then the session is saved
  And a status line is printed showing model, tokens, context %, and elapsed time
```

#### Scenario: Streaming output
```
  Given the LLM supports streaming
  When the agent receives a response
  Then text content is displayed token-by-token as it arrives
  And reasoning content is displayed in a dimmed style before text
  And tool calls are displayed after the stream completes
```

#### Scenario: Non-streaming fallback
```
  Given the LLM does not support streaming (or streaming is disabled)
  When the agent receives a response
  Then the full response is displayed at once
```

#### Scenario: Step counter
```
  Given the agent loop is running
  When each LLM call begins
  Then "[step N] thinking..." is displayed in cyan
```

#### Scenario: Max steps safety backstop
```
  Given config.max_steps is reached
  When the agent would take another step
  Then the loop stops with a message: "[reached the safety backstop of N steps. Task
    may be incomplete — send 'continue' to resume.]"
```

#### Scenario: Context threshold warning
```
  Given estimated context exceeds config.compact_threshold × config.context_limit
  When the step completes
  Then a warning is shown: "[context at X% (N/M). Consider compacting.]"
  So the LLM is nudged to call the compact tool
```

#### Scenario: Status bar
```
  Given an agent run completes
  When the loop exits
  Then a status line in dim/magenta shows:
    -- <model> - <total tokens> tokens - <X.X%> context - <elapsed>s
  But in quiet/subagent mode the status bar is suppressed (only the final answer goes to stdout)
```

---

## 7. Tool Execution Contract

The system exposes 12 tools via OpenAI-compatible function calling. Each tool
returns a JSON object: `{ status: "ok"|"error"|"compacted", output?, error? }`.

### Feature: Tool Catalog

| # | Tool | Purpose | Required Params | Optional Params | Default Permission |
|---|------|---------|-----------------|-----------------|-------------------|
| 1 | read | Read file, return with line numbers | filePath | — | allow |
| 2 | write | Create or overwrite a file | filePath, content | — | allow |
| 3 | edit | Exact string replacement in a file | filePath, oldString, newString | replaceAll | allow |
| 4 | bash | Execute a shell command | command | workdir | allow |
| 5 | glob | Find files matching a glob pattern | pattern | path | allow |
| 6 | grep | Search files with a regex | pattern | path, include | allow |
| 7 | web_search | Search the web via DuckDuckGo HTML | query | — | allow |
| 8 | web_fetch | Fetch URL content as text | url | — | allow |
| 9 | remote_bash | Execute a shell command on a remote host via SSH (key-only) | host, command | username, port | ask |
| 10 | compact | Free context by summarizing prior conversation | summary | — | allow |
| 11 | skill | Load a skill's full instructions from SKILL.md | name | — | allow |
| 12 | subagent | Delegate a task to a child cluade with fresh context | prompt | mode | allow |

### Feature: File Tools

#### Scenario: read returns file content with line numbers
```
  Given a file exists at filePath
  When the agent calls read
  Then the file content is returned with each line prefixed "N: "
  And line numbers enable precise edit targets
  When the file does not exist
  Then an error is returned with the OS error message
```

#### Scenario: write creates or overwrites a file
```
  When the agent calls write with filePath and content
  Then parent directories are created if needed
  And the file is written atomically (write to temp → rename)
  And returns "wrote <absolute path>"
```

#### Scenario: edit performs exact string replacement
```
  Given a file exists at filePath
  When the agent calls edit with oldString and newString
  Then the first (and only) exact match of oldString is replaced with newString
  And returns "replaced 1 occurrence(s) in <path>"
  When oldString matches multiple locations and replaceAll is not set
  Then an error is returned: "Found multiple matches for oldString"
  When replaceAll is true
  Then all occurrences are replaced
  And returns the count of replacements
```

### Feature: Shell Tools

#### Scenario: bash executes a local shell command
```
  When the agent calls bash with a command
  Then the command runs as: cd <workdir> && <command>
  And stdout and stderr are captured and returned
  And on non-zero exit the output ends with "[exit code: N]"
  And execution has a configurable timeout (default 120s)
```

#### Scenario: remote_bash executes a command over SSH
```
  When the agent calls remote_bash with host and command
  Then the command runs via SSH key authentication
  And default username is "root" and default port is 22
  And no password authentication is supported (key-only for security)
  And on non-zero exit the output ends with "[exit code: N]"
```

### Feature: Search Tools

#### Scenario: glob finds files by pattern
```
  When the agent calls glob with a pattern
  Then files matching the pattern are listed
  And ** triggers recursive find from the directory before the first wildcard
  And a relative pattern resolves against path (default cwd)
  And an absolute pattern is used as-is
  And results are capped at 100 entries
```

#### Scenario: grep searches file contents with a regex
```
  When the agent calls grep with a pattern
  Then the regex is searched recursively from the search path
  And an optional include filter restricts to matching filenames
  And results show file:line:content
  And results are capped at 100 lines
```

### Feature: Web Tools

#### Scenario: web_search queries DuckDuckGo HTML
```
  When the agent calls web_search with a query
  Then results are fetched from DuckDuckGo's HTML interface
  And each result includes title, snippet, and link
  And a Chrome user-agent is used to avoid bot blocking
```

#### Scenario: web_fetch retrieves a URL as text
```
  When the agent calls web_fetch with a URL
  Then the URL content is fetched with a 15-second timeout
  And responses larger than 32 KB are truncated with a note
  And a Chrome user-agent is used
```

### Feature: Context Management Tool

#### Scenario: compact condenses the conversation
```
  Given the agent has done significant work
  When the agent calls compact with a summary paragraph
  Then the system message is replaced with:
    - The agent persona
    - "[Session compressed. Summary of prior work: <summary>]"
    - The per-turn augmentations (skills list + project instructions) re-added
    - The user-assistant pair that triggered the compact
  And the compact tool's result is the last assistant message before compaction
  And the new context is much smaller but preserves current state, decisions, and next steps
```

### Feature: Skill Tool

#### Scenario: skill loads a SKILL.md on demand
```
  Given a skill exists in ~/.cluade/skills/<name>/SKILL.md
  When the agent calls skill("brainstorming")
  Then the SKILL.md body (minus YAML frontmatter) is returned
  And the agent now follows the skill's workflow instructions
  When the skill does not exist
  Then an error is returned listing all available skill names
```

### Feature: Subagent Tool

#### Scenario: subagent delegates a task to a child cluade
```
  When the parent agent calls subagent with a prompt
  Then a child cluade process is spawned with --subagent mode
  And the child runs the prompt to completion
  And the child's final answer is captured and returned to the parent
  And the child's progress chatter passes to stderr, never polluting the captured answer
  And the child runs ephemerally — no session trace is left on disk
```

#### Scenario: subagent mode determines toolset
```
  When subagent mode is "build" (default)
  Then the child has full tools minus subagent: read, write, edit, bash, glob,
    grep, web_search, web_fetch, remote_bash, compact, skill
  When subagent mode is "plan"
  Then the child is read-only: read, grep, glob, web_search, web_fetch
```

#### Scenario: subagent prompt is shell-escaped
```
  Given the subagent prompt contains shell metacharacters (e.g. single quotes)
  When the child command is constructed
  Then the prompt is escaped so it cannot break out of the shell invocation
```

### Feature: Token Counting and Path Resolution

#### Scenario: Token estimation uses a proper tokenizer
```
  Given text is passed to the token counter
  Then the count approximates the model's native tokenization
  And is accurate enough for context-threshold warnings (not the rough #text/3.5 heuristic)
```

#### Scenario: Path resolution is absolute and safe
```
  Given a relative filePath is provided
  When the tool executes
  Then the path is resolved against the process cwd at invocation time
  And the absolute path is used for the actual filesystem operation
```

---

## 8. Permission System Contract

### Feature: Three-Level Tool Permissions

```
Feature: Permission model
  As a user
  I want control over which tools auto-execute vs. require approval
  So that I maintain safety without friction
```

#### Scenario: Allow — auto-execute
```
  Given a tool is set to "allow"
  When the agent calls it
  Then it executes without prompting
  And a green label shows the tool name and parameters
```

#### Scenario: Ask — prompt user
```
  Given a tool is set to "ask"
  When the agent calls it
  Then the user is prompted with the tool name and key parameters
  And the prompt uses "[y/N]" format
  And "y" or "yes" (case-insensitive) approves; anything else denies
  And the terminal temporarily switches to cooked mode for the read
  And restores the prior mode afterward
```

#### Scenario: Deny — refuse with error
```
  Given a tool is set to "deny"
  When the agent calls it
  Then execution is refused
  And "[denied: <tool>]" is printed in red
  And the agent receives an error result
```

#### Scenario: Default permissions
```
  Given no config overrides
  Then bash, read, write, edit, glob, grep, web_search, web_fetch, compact, skill,
    and subagent are "allow"
  And remote_bash is "ask"
```

#### Scenario: Config file overrides defaults per-tool
```
  Given config.json sets permissions: { bash: "deny", write: "ask" }
  When config is loaded and applied by Agent:init
  Then bash is "deny" and write is "ask"
  And all other tools keep their defaults
```

#### Scenario: --yes overrides to allow-all
```
  When the user passes --yes
  Then bash, remote_bash, and write are set to "allow"
  And this takes precedence over config file permissions
```

### Feature: Smart Bash Gate (dangercheck)

```
Feature: Dangerous command escalation
  As a safety system
  I want catastrophic commands escalated to confirmation prompts
  So that one bad model suggestion doesn't cause irreversible damage
```

#### Scenario: The gate is conservative — it only flags truly catastrophic commands
```
  Given the bash tool is set to "allow"
  When the model calls bash with a catastrophic command
  Then the effective permission is escalated to "ask" (with a reason shown)
  And the user sees "[flagged: <reason>]" in the prompt
  When the model calls bash with a routine destructive-but-scoped command
    (e.g. rm -rf ./build, dd to a file, > /dev/null)
  Then the command runs without prompting
```

#### Scenario: The gate never downgrades deny or ask
```
  Given the bash tool is set to "deny"
  When the model calls bash with any command
  Then it stays denied — the gate never makes a deny into anything less restrictive
  Given the bash tool is set to "ask"
  Then it stays ask regardless of whether the command is flagged
```

#### Scenario: The gate only applies to bash
```
  Given a non-bash tool is set to "allow"
  When the model calls it with parameters that look like a dangerous command
  Then it executes without the danger gate — only bash is gated
```

#### Scenario: Flagged patterns — what the gate catches
```
  The danger check flags the following categories:
    - Recursive force-remove (rm -rf) targeting /, /etc, /usr, ~, $HOME,
      /dev, /sys, /proc, or a bare wildcard (*, ., ..)
      But NOT rm -rf of a relative path (./build, ./dist) or /tmp location
    - dd writing to a block device (/dev/sd*, /dev/mmcblk*, /dev/nvme*, …)
    - Shell redirects onto a raw block device
    - Filesystem formatting (mkfs and mkfs.<type>)
    - Power-state commands: shutdown, reboot, halt, poweroff
    - Fork bombs: :(){ :|:& };:
    - Network downloads piped straight into a shell: curl/wget … | sh/bash/ash/…
      including sudo sh, but NOT curl|grep, curl|tar, or curl -o file
    - Command substitution containing a download under an exec trigger:
      sh -c "$(curl …)", eval "$(curl …)", backticks
    - Process substitution fed to a shell: bash <(curl …), sh <(wget …)
      but NOT process-sub into a non-shell: diff <(curl a) <(curl b)
```

#### Scenario: False negatives are preferred over false positives
```
  Given an obfuscated destructive command
  When the danger check evaluates it
  Then it may not be caught — the gate protects against model error, not adversarial evasion
  And the model is an occasional bungler, not an adversary trying to evade the check
```

#### Scenario: Configurable danger patterns
```
  Given a danger_patterns array in config.json
  When the danger check runs
  Then user-defined patterns are evaluated in addition to the built-in defaults
```

---

## 9. Subagent Architecture

### Feature: Process-based Subagent Spawning

```
Feature: Child process subagents
  As the agent loop
  I want to delegate self-contained tasks to child claade processes
  So that the parent's context is preserved and work can be parallelized externally
```

#### Scenario: Subagent is a one-shot child process
```
  Given the parent agent calls the subagent tool
  When the child cluade is spawned
  Then it runs independently in a new process
  And the parent blocks until the child exits
  And the child's final answer is captured from its stdout
  And the child's progress chatter passes through its stderr (visible but not captured)
```

#### Scenario: Subagent toolset omits subagent — recursion capped at depth 1
```
  Given any subagent (build or plan)
  When its toolset is assembled
  Then the `subagent` tool is never included
  And the subagent cannot spawn a grandchild — this is enforced by construction, not by a counter
```

#### Scenario: Subagent unattended permission rule
```
  Given a subagent is running (unattended; no human)
  When it encounters a tool with base permission "ask"
  Then it becomes "deny" — there is no human to approve
  When the danger check flags a bash command
  Then it becomes a hard "deny" instead of a prompt
  When a tool is "allow"
  Then it stays "allow" — write, edit, and ordinary bash run freely
```

#### Scenario: Plan subagent is read-only by toolset
```
  When a subagent is spawned in "plan" mode
  Then its toolset is: read, grep, glob, web_search, web_fetch
  And its permissions are set by the same unattended rule
```

#### Scenario: Build subagent keeps the full toolset (minus subagent)
```
  When a subagent is spawned in "build" mode (default)
  Then its toolset includes: read, write, edit, bash, glob, grep, web_search,
    web_fetch, remote_bash, compact, skill
  And those set to "allow" execute freely; those set to "ask" become "deny"
```

#### Scenario: Parallelism is delegated to the shell
```
  Given the user wants parallel subagent execution
  When they write: cluade "task a" & cluade "task b" & wait
  Then both run concurrently as separate processes
  And the operator controls concurrency explicitly through the shell
```

---

## 10. Loop Detection Contract

### Feature: Stuck-Agent Detection

```
Feature: Loop detection
  As a safety mechanism
  I want the agent stopped when it's clearly stuck
  So that tokens are not wasted on infinite loops
```

#### Scenario: Repeat detection — warn then stop
```
  Given the agent calls the same tool with identical, canonicalized arguments
  When this happens 3 times consecutively
  Then a warning message is injected into the conversation:
    "[cluade] You have called the same tool with identical arguments 3 times
     in a row. This looks like a loop. Change your approach, or stop if the
     task is already complete."
  When it happens a 4th time consecutively
  Then the agent loop is halted
  And the user sees: "[stopped: the model appears stuck … send 'continue' to resume.]"
```

#### Scenario: Error cascade detection — warn then stop
```
  Given the agent's tool calls consistently return errors
  When 4 consecutive calls error (regardless of which tool)
  Then a warning is injected:
    "[cluade] The last 4 tool calls all returned errors.
     Reconsider your approach, or stop if you cannot proceed."
  When a 5th consecutive error occurs
  Then the loop halts
```

#### Scenario: Behavior change resets counters
```
  Given a warning was issued for repeats
  When the agent makes a different tool call (or same tool with different canonical arguments)
  Then the repeat counter resets
  And the warning state clears
  Given a warning was issued for errors
  When any call succeeds
  Then the error counter resets
  And the warning state clears
```

#### Scenario: Argument order independence
```
  Given the agent calls bash with {command: "ls", workdir: "/tmp"}
  When the agent calls bash with {workdir: "/tmp", command: "ls"}
  Then these are treated as identical — object keys are sorted for comparison
  And array order is preserved (it is semantically meaningful)
```

#### Scenario: Thresholds are configurable
```
  Given config sets repeat_threshold: 5 and error_threshold: 6
  When the loop detector runs
  Then it uses those thresholds instead of the defaults (3 and 4)
```

#### Scenario: Loop detection is passive
```
  Given the detector fires
  Then it never prevents a tool from executing
  And it only reacts by injecting a conversation message or stopping the loop at step boundaries
```

---

## 11. Provider Contract

### Feature: LLM API Communication

```
Feature: API provider abstraction
  As the agent
  I want to communicate with multiple LLM backends via HTTP
  So that the user can choose any OpenAI-compatible provider
```

#### Scenario: OpenAI-compatible chat completion
```
  Given a base_url, model, and api_key are configured
  When the agent calls the LLM
  Then a POST is made to {base_url}/chat/completions
  And the request body includes: model, messages, tools (when tools are present),
    tool_choice: "auto", and max_tokens
  And Authorization: Bearer <api_key> header is set
  And Content-Type: application/json is set
  And the response is parsed for content, reasoning_content, tool_calls,
    finish_reason, and usage
```

#### Scenario: Thinking/reasoning mode
```
  Given the provider supports extended thinking
  When config.thinking is not explicitly false
  Then the request includes: "thinking": { "type": "enabled" }
  And "reasoning_effort" is sent from config (default "max")
  And reasoning content is displayed separately from the main response content
  When config.thinking is explicitly false
  Then no thinking fields are sent
```

#### Scenario: Request body — exact fields sent
```
  The request body consists of a fixed set of fields:
    model         — from config.model
    messages      — the conversation
    tools         — only when tools are present (with tool_choice: "auto")
    thinking      — sent when config.thinking ~= false (hardcoded {type: "enabled"})
    reasoning_effort — from config, only when thinking is on (default "max")
    max_tokens    — from config.max_tokens (default 131072)
  There is no extra_body or passthrough mechanism.
  temperature is not read from config and is never sent by the agent.
```

#### Scenario: Provider error handling
```
  Given the API returns an HTTP error status
  When the agent processes the response
  Then a clear error is printed: "[provider error: HTTP <code>: <message>]"
  And curl exit codes and transport errors are surfaced (not masked as JSON parse errors)
  And the agent loop stops
  And the session is saved so work is not lost
```

#### Scenario: Network failure
```
  Given the API is unreachable
  When the agent attempts a call
  Then the error includes the connection failure reason and curl exit code
  And the agent loop stops gracefully
```

#### Scenario: Retry on transient failure
```
  Given the API returns a 429 (rate limit) or 5xx (server error)
  When the agent processes the response
  Then it retries up to 3 times with exponential backoff
  And if all retries fail, it stops with an error
```

#### Scenario: Streaming support
```
  Given the provider supports SSE streaming
  When streaming is enabled (config.stream defaults to true)
  Then text tokens are yielded and displayed as they arrive
  And reasoning content is accumulated and displayed in dimmed style
  And tool calls are accumulated and emitted at stream end
  When streaming is disabled (config.stream = false)
  Then the full response is fetched and displayed at once
```

#### Scenario: Model list discovery
```
  When the user runs: cluade --list-models
  Then available models from the configured provider are listed
```

---

## 12. Skill System Contract

### Feature: On-Demand Skill Loading

```
Feature: Skills
  As an agent
  I want to load specialized instructions on demand
  So that I can follow workflows for specific tasks
```

#### Scenario: Skill discovery at startup
```
  Given SKILL.md files exist in ~/.cluade/skills/ or ./.cluade/skills/
  When skills are scanned
  Then each skill's name and description are extracted from YAML frontmatter
  And skills with disable-model-invocation: true in frontmatter are hidden
  And the skill list is added to the system prompt's per-turn augmentations
```

#### Scenario: Skill loading
```
  Given a skill exists at ~/.cluade/skills/<name>/SKILL.md
  When the agent calls skill("brainstorming")
  Then the SKILL.md body (everything after the --- frontmatter) is returned
  And the green execution label shows: "[using skill: brainstorming]"
  And the agent now follows the skill's instructions in subsequent turns
```

#### Scenario: Skill missing
```
  Given a skill does not exist
  When the agent calls skill("nonexistent")
  Then an error is returned listing all available skill names
```

#### Scenario: Skill import from git or local path
```
  When the user runs: cluade --import-skill <git-url|local-path>
  Then the skill repository is cloned (or copied for local paths)
  And each SKILL.md is inspected and classified
  And a compatibility report is printed per skill:
    [OK  ] full      — declared tools all have cluade equivalents, no runtime deps
    [OK* ] portable  — no tools declared, but no script/plugin deps (pure instructions)
    [PART] partial   — declares an unsupported tool (e.g. Task, MCP tool)
    [LTD ] limited   — bundles python/node scripts or .claude-plugin/ (hard blocker on constrained device)
  And skills are installed to the skills directory
```

#### Scenario: Skill marketplace browsing
```
  When the user runs: cluade --browse-marketplace <git-url|owner/repo|local-path>
  Then the marketplace's .claude-plugin/marketplace.json is parsed
  And each plugin is listed with a compatibility verdict:
    [OK  ] compatible    — usable skills/commands, no blockers
    [PART] partial       — some usable, some runtime-bound or blocked
    [LTD ] limited       — only python/node-bound skills
    [ X  ] incompatible  — only hooks/MCP/LSP, nothing cluade can consume
  And per-plugin component counts (skills, commands, agents, hooks, MCP, LSP) are shown
```

---

## 13. Output Formatting

### Feature: Terminal Output

```
Feature: Formatted terminal output
  As a user
  I want color-coded, structured output
  So that I can quickly parse agent activity
```

#### Scenario: Color scheme
```
  When output is displayed:
  Then step labels ("[step N] thinking...") are in cyan
  And tool execution labels ("[using tool: …]") are in green
  And the REPL prompt ("> ") is in cyan
  And status information and the status bar are in dim/magenta
  And errors and denials are in red
  And warnings and loop-guard messages are in yellow
  And the "Exiting..." message is in cyan
```

#### Scenario: Tool execution display
```
  When a tool executes:
  Then a label shows: "[using tool: <name> <params>]"
  And the skill tool shows: "[using skill: <skill-name>]"
  And the compact tool shows: "[using tool: compact]" (no summary in the label)
  And parameters longer than 200 characters are truncated with "..."
  And the tool's output is printed below the label
```

#### Scenario: Progress indication
```
  Given a long-running operation
  When the agent is processing
  Then elapsed time is shown for each LLM call: "[took <N>s]" or
    "[reasoned for <N>s, <M> chars]" for thinking responses
  And the user knows the system is not hung
```

#### Scenario: Debug output (--show-tools-json)
```
  When --show-tools-json is active
  Then each LLM response prints:
    1. [raw response body] — the literal wire bytes
    2. [tool_calls decoded] — the full decoded structure, pretty-printed with indentation
    3. [tool-call json] <name> <args> — one compact line per call
```

---

## 14. Configuration Schema

### Feature: Configuration File

```
Feature: config.json format
  As a user
  I want a documented configuration format
  So that I can customize cluade for my environment
```

#### Scenario: Complete config schema
```
  Given a config.json file
  Then recognized keys are:
    base_url:          string   (default: "https://api.deepseek.com/v1")
    model:             string   (default: "deepseek-v4-pro")
    api_key:           string   (default: "")
    max_steps:         integer  (default: 100, min: 1)
    max_tokens:        integer  (default: 131072, min: 1)
    request_timeout:   integer  (default: 600, min: 1)
    thinking:          boolean  (default: true)
    reasoning_effort:  string   (default: "max", values: "low"|"medium"|"high"|"max")
    context_limit:     integer  (default: 200000)
    compact_threshold: float    (default: 0.85, min: 0.1, max: 0.95)
    permissions:       object   (keys: tool names, values: "allow"|"ask"|"deny")
    danger_patterns:   array    (optional custom danger patterns)
    stream:            boolean  (default: true)
    history_max:       integer  (default: 1000)
    repeat_threshold:  integer  (default: 3, loop detection repeat count)
    error_threshold:   integer  (default: 4, loop detection error count)
  And unknown keys produce a warning but are otherwise ignored
```

#### Scenario: Config file location precedence
```
  When config is loaded:
  Then ~/.cluade/config.json is the global config
  And ./.cluade/config.json in the project working directory is the project config
  And --config <path> overrides both
  And CLI flags like --model override config values
  And precedence is: CLI > project config > global config > hardcoded defaults
```

---

## 15. Session File Format

### Feature: Session Persistence Format

```
Feature: Session JSON schema
  As the system
  I want sessions in a well-defined, portable format
  So that they can be backed up, shared, and debugged
```

#### Scenario: Session structure
```
  Given a session is saved
  Then it contains:
    id:              string    # YYYYMMDD-HHMMSS-NNNN
    cwd:             string    # absolute path
    created:         string    # human-readable timestamp (YYYY-MM-DD HH:MM:SS)
    messages:        array     # OpenAI-format message objects [{role, content, …}]
    steps:           integer   # steps taken in the last run
    total_tokens:    integer   # cumulative tokens used across the session
    context_tokens:  integer   # estimated current context size (not cumulative)
    version:         string    # cluade version that wrote this session
```

#### Scenario: Message format
```
  Each message object follows the OpenAI chat format:
    { role: "system"|"user"|"assistant"|"tool", content: string }
  Assistant messages may also contain:
    reasoning_content: string   # thinking/reasoning output
    tool_calls: array           # [{ id, type, function: { name, arguments } }]
  Tool messages contain:
    tool_call_id: string        # matching the assistant's tool call id
    content: string             # JSON-encoded tool result { status, output?, error? }
```

---

## 16. Project Instructions Discovery

### Feature: OpenCode-Style Instruction File Resolution

```
Feature: Project instructions
  As the agent
  I want to discover and load project-specific instructions
  So that I follow the user's conventions and constraints
```

#### Scenario: Per-file precedence
```
  Given a directory contains AGENTS.md, CLAUDE.md, and GEMINI.md
  When the agent scans for instructions
  Then AGENTS.md wins (the cross-tool standard)
  And CLAUDE.md is used only when AGENTS.md is absent
  And GEMINI.md is the last resort
  And only the first match is read — the others are ignored
```

#### Scenario: Directory-tree walk upward from cwd
```
  Given the user runs cluade from a deep subdirectory
  When the agent searches for instructions
  Then it walks up from cwd toward the filesystem root
  And the nearest ancestor's instruction file wins
  And the walk stops at the git root (.git directory or file)
  And files above the git root are never read
```

#### Scenario: Global user instructions
```
  Given ~/.cluade/AGENTS.md (or CLAUDE.md, GEMINI.md) exists
  When the agent assembles the system prompt
  Then those global instructions are included
  And they appear before the project-local instructions
  And are labelled "Global user instructions (from ~/.cluade/<file>)"
```

#### Scenario: Instructions are rebuilt every turn
```
  Given a long-running session across multiple agent runs
  When the system prompt is assembled each turn
  Then the per-turn augmentations (skills + project instructions) are rebuilt fresh
  And the persistent base of the system message is separated by a marker
  And augmentations never duplicate or accumulate
  Even after a compact tool call mid-run
```

---

## 17. Invariants

1. **Session safety:** Session is saved after every agent run. Crashing after N
   steps preserves the first N−1 steps' work. (Ephemeral runs are the exception.)

2. **Permission precedence:** Defaults < config < --yes. Later always wins for
   the same tool.

3. **Danger gate is additive only:** It can escalate allow→ask (attended) or
   allow→deny (unattended) but never otherwise changes permissions. It never
   downgrades deny, never touches a tool already set to "ask", and never gates
   non-bash tools.

4. **Subagent cap is structural:** A subagent's toolset omits the `subagent`
   tool, capping recursion at depth 1 by construction. No depth counter is needed.

5. **Subagent unattended rule:** In --subagent mode, any "ask" becomes "deny"
   and any dangercheck hit becomes "deny" (not a prompt). "allow" stays "allow".

6. **Loop detection is passive:** It observes, warns via conversation messages,
   then stops the loop at step boundaries. It never prevents a tool from executing.

7. **Augmentation freshness:** Skills list and project instructions are rebuilt
   every turn and after every compaction, never duplicated.

8. **Terminal safety:** Raw terminal mode is always restored to cooked on exit,
   even on crash (via pcall guard in the REPL loop). Permission prompts
   temporarily switch to cooked mode and restore afterward.

9. **Path resolution:** All relative paths in tools resolve against the process
   cwd at invocation time. Absolute paths pass through unchanged.

10. **No data loss:** Errors during tool execution are reported to the LLM as
    structured results, not swallowed. The agent can see and recover from them.

11. **Quiet output contract:** In --subagent/--quiet mode, stdout carries only
    the final assistant answer (exactly one line). All progress chatter goes to
    stderr.

12. **Ephemeral runs:** In --subagent/--no-session mode, no session file is
    written and no last_session pointer is updated.

---

## 18. Key Differences from Tier A (Exact Clone)

| Aspect | Tier A (Exact Clone) | Tier B (Faithful Port) |
|--------|---------------------|------------------------|
| HTTP transport | curl via io.popen | Native HTTP library |
| Token counting | `#text / 3.5` rough heuristic | Model-specific tokenizer or tiktoken-equivalent |
| Line editing | Byte-based cursor positioning | Unicode grapheme-aware cursor |
| Streaming | None — full response at once | SSE streaming with real-time token display |
| History persistence | In-memory only (lost on exit) | Persisted to ~/.cluade/history |
| Config validation | None — invalid values used as-is | Schema validation with warnings and fallback |
| Globbing | Simplified ** handling (final segment only) | Full recursive glob with intermediate ** segments |
| Error retry | None — first failure stops the run | Retry with exponential backoff on 429/5xx |
| Danger patterns | Hardcoded in dangercheck.lua | Configurable via danger_patterns in config.json |
| Session export | Not supported | Export/import commands for portability |
| Model discovery | Not supported | --list-models flag queries the provider |
| Progress indication | Static "[step N] thinking..." | Spinner or live elapsed-time updates |
| Version tracking | Not in session data | version field in session JSON |
| Subagent | Process-based, depth 1 by construction | Same architecture, same 12-tool set, same UX |
