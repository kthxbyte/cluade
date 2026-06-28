# cluade Behavior Specification — Tier A: Exact Clone

> **Goal:** A drop-in replacement. Every CLI flag, config key, tool behavior, edge
> case, and output format is preserved. The new implementation must pass the same
> test suite unmodified. This spec describes the system as a black box — no
> implementation language or library is assumed.

---

## 1. System Boundaries

```
                          ┌─────────────────────────┐
  CLI args / stdin ──────>│                         │──────> stdout / stderr
  Config files           │        cluade            │──────> filesystem writes
  Env vars               │                         │──────> shell executions
  Session files ────────>│                         │──────> HTTP to LLM API
                          └─────────────────────────┘
```

**External dependencies assumed present on the host:**
- Lua 5.1 (or compatible runtime)
- `curl` (HTTP client)
- `ssh` (for remote_bash; dropbear `ssh -y` on OpenWRT)
- Standard POSIX: `ls`, `find`, `grep`, `mkdir`, `stty`, `readlink`, `mktemp`
- `/tmp` writable

---

## 2. CLI Contract

### Feature: CLI Argument Parsing

```
Feature: Command-line interface
  As a user
  I want to invoke cluade with standard Unix-style arguments
  So that I can control model, session, and permissions from the command line
```

#### Scenario: One-shot prompt with default model
```
  Given the config file does not set a model
  When the user runs: cluade "write hello world in bash"
  Then the agent runs one turn with the prompt "write hello world in bash"
  And the default model "deepseek-v4-pro" is used
  And after completion a status line is printed:
    "-- deepseek-v4-pro - <N> tokens - <X.X>% context"
```

#### Scenario: One-shot prompt with explicit model
```
  When the user runs: cluade -m gpt-4o "explain this code"
  Then the model "gpt-4o" is used
  And the -m flag overrides any config file model
```

#### Scenario: Multiple words become single prompt
```
  When the user runs: cluade write a hello world script
  Then the prompt is "write a hello world script"
  And each positional arg is joined with a single space
```

#### Scenario: Help flag
```
  When the user runs: cluade -h
  Or: cluade --help
  Then help text is printed to stdout
  And the process exits with code 0
  And no agent is started
```

#### Scenario: Initialize config file
```
  Given ~/.cluade/config.json does not exist
  When the user runs: cluade --init
  Then ~/.cluade/config.json is created with default values:
    | base_url              | https://api.deepseek.com/v1  |
    | model                 | deepseek-v4-pro              |
    | max_steps             | 100                          |
    | max_tokens            | 131072                       |
    | request_timeout       | 600                          |
    | permissions.bash      | allow                        |
    | permissions.remote_bash | ask                        |
    | permissions.write     | allow                        |
  And the process exits with code 0
```

#### Scenario: Continue most recent session
```
  Given a previous session exists with id "20260529-201630-1000"
  And ~/.cluade/last_session contains "20260529-201630-1000"
  When the user runs: cluade -c
  Then the session "20260529-201630-1000" is loaded
  And its message history is restored
  And "continuing session 20260529-201630-1000" is printed
```

#### Scenario: Resume specific session by ID
```
  Given session "20260529-201630-1000" exists
  When the user runs: cluade -r 20260529-201630-1000
  Or: cluade --resume 20260529-201630-1000
  Then that session is loaded
  And "resumed session 20260529-201630-1000" is printed
```

#### Scenario: Resume with .json suffix stripped
```
  When the user runs: cluade -r 20260529-201630-1000.json
  Then the .json suffix is stripped
  And session "20260529-201630-1000" is loaded
```

#### Scenario: List sessions
```
  Given sessions exist in ~/.cluade/sessions/
  When the user runs: cluade --list-sessions
  Then each session is printed in format: "<id>  <created>  <N> msgs  <cwd>"
  And sessions are ordered by modification time (newest first)
  And the process exits with code 0
```

#### Scenario: List sessions when none exist
```
  Given no sessions exist
  When the user runs: cluade --list-sessions
  Then "No sessions found." is printed
  And the process exits with code 0
```

#### Scenario: Auto-approve permissions
```
  When the user runs: cluade -y "rm temp.txt"
  Then bash, remote_bash, and write permissions are all set to "allow"
  And no permission prompts appear during the run
  And -y overrides config file permission settings
```

#### Scenario: Debug tools JSON output
```
  When the user runs: cluade --show-tools-json "test"
  Then for each tool call in the response:
    A "[raw response body]" block shows the literal HTTP response
    A "[tool_calls decoded]" block shows pretty-printed parsed JSON
    A "[tool-call json] <name> <args>" line shows a compact view
```

#### Scenario: API key from command line
```
  When the user runs: cluade --api-key sk-abc123 "prompt"
  Then the API key "sk-abc123" is used for authentication
  And --api-key overrides config file and environment variable
```

#### Scenario: API key from environment variable
```
  Given OPENAI_API_KEY is set to "sk-env-456"
  And no --api-key flag is given
  And config file has no api_key
  When the user runs: cluade "prompt"
  Then "sk-env-456" is used as the API key
```

#### Scenario: Base URL override
```
  When the user runs: cluade --base-url http://localhost:11434/v1 -m llama3 "prompt"
  Then the API endpoint is http://localhost:11434/v1/chat/completions
  And the model "llama3" is requested
```

#### Scenario: Interactive REPL with no prompt
```
  When the user runs: cluade
  Then a new session is created and saved
  And "cluade session <id> -- <model>" is printed
  And "Type /help for commands, Ctrl+D to exit" is printed
  And a cyan "> " prompt appears
  And the terminal is in raw mode (-icanon -echo)
```

#### Scenario: Non-TTY stdin falls back to simple read
```
  Given stdin is not a terminal (e.g., piped input)
  When the user runs: echo "hello" | cluade
  Then line editing is disabled
  And "stdin is not a terminal -- line editing disabled" is printed
  And input is read with basic io.read("*l")
```

#### Scenario: Subagent mode flag (unattended child agent)
```
  When the user runs: cluade --subagent "research X"
  Then the agent runs in unattended mode:
    - Progress chatter goes to stderr, only the final answer to stdout (--quiet)
    - No session file is persisted (--no-session)
    - Any "ask" permission becomes "deny"
    - A dangercheck hit (normally escalated to "ask") becomes a hard "deny"
  And the subagent tool is omitted from the toolset
  And "allow" permissions (bash, write, edit) remain "allow"
```

#### Scenario: Plan mode flag (read-only subagent)
```
  When the user runs: cluade --subagent --plan "audit the repo"
  Then the subagent runs read-only:
    - Toolset limited to: read, grep, glob, web_search, web_fetch
    - No write, edit, bash, remote_bash, compact, skill, or subagent tools
```

#### Scenario: Quiet mode flag (standalone)
```
  When the user runs: cluade --quiet "do something"
  Then progress chatter goes to stderr
  And only the final assistant message appears on stdout
  And no status bar is printed after the run
```

#### Scenario: No-session flag (standalone)
```
  When the user runs: cluade --no-session "do something"
  Then no session file is persisted to ~/.cluade/sessions/
  And the last_session pointer is not updated
  And the run is ephemeral (leaves no trace on disk)
```

---

## 3. Config Loading Contract

### Feature: Configuration Resolution

```
Feature: Configuration loading
  As a user
  I want config merged from multiple sources
  So that I have global defaults, project overrides, and CLI overrides
```

#### Scenario: Config merge order
```
  Given hardcoded defaults exist:
    | base_url          | https://api.deepseek.com/v1 |
    | model             | deepseek-v4-pro             |
    | max_steps         | 100                         |
    | max_tokens        | 131072                      |
    | request_timeout   | 600                         |
    | context_limit     | 200000                      |
    | compact_threshold | 0.85                        |
  And ~/.cluade/config.json sets model to "global-model"
  And ./.cluade/config.json sets model to "project-model"
  And --model "cli-model" is passed on the command line
  When config is loaded
  Then the effective model is "cli-model"
  And the effective base_url is still "https://api.deepseek.com/v1"
```

#### Scenario: Config file does not exist
```
  Given ~/.cluade/config.json does not exist
  And ./.cluade/config.json does not exist
  When config is loaded
  Then all hardcoded defaults are used
  And no error is raised
```

#### Scenario: Permissions merge via deep merge
```
  Given config.json sets permissions.bash to "deny"
  When config is loaded
  Then bash permission is "deny"
  And read, write, edit, glob, grep, web_search, web_fetch, compact, skill, subagent remain "allow"
  And remote_bash remains "ask"
```

#### Scenario: Corrupt config file is silently ignored
```
  Given ~/.cluade/config.json contains invalid JSON
  When config is loaded
  Then the invalid file is skipped
  And hardcoded defaults are used
  And no error is printed
```

---

## 4. Session Management Contract

### Feature: Session Persistence

```
Feature: Session management
  As a user
  I want sessions persisted to disk
  So that I can resume work across invocations
```

#### Scenario: New session creation
```
  Given no session exists
  When a new session is created
  Then the session id matches pattern "YYYYMMDD-HHMMSS-NNNN"
  And cwd is set to the process working directory
  And messages is an empty array
  And created is a human-readable timestamp like "2026-05-29 20:16:30"
  And the session is saved to ~/.cluade/sessions/<id>.json
  And ~/.cluade/last_session is updated with the session id
```

#### Scenario: Session save after agent run
```
  Given an agent run completes (success, error, or loop-stop)
  When the run finishes
  Then the session is saved to ~/.cluade/sessions/<id>.json
  And the JSON contains: id, cwd, created, messages, steps, total_tokens, context_tokens
```

#### Scenario: Session load
```
  Given a session file exists at ~/.cluade/sessions/20260529-201630-1000.json
  When the session is loaded
  Then the full message history is restored
  And the session id, cwd are restored
```

#### Scenario: Session load — not found
```
  Given no session file exists for id "nonexistent"
  When attempting to load "nonexistent"
  Then an error is returned: "session not found: nonexistent"
```

#### Scenario: Session load — corrupt JSON
```
  Given session file contains invalid JSON
  When attempting to load
  Then an error is returned: "corrupt session: <parse error>"
```

#### Scenario: Session id uniqueness
```
  Given two sessions are created in the same second
  Then they have different random suffixes (the NNNN part)
```

#### Scenario: Ephemeral run leaves no trace
```
  Given --subagent or --no-session mode is active
  When the agent run completes
  Then no session file is saved to ~/.cluade/sessions/
  And the last_session pointer is not updated
```

---

## 5. Interactive REPL Contract

### Feature: Line Editing

```
Feature: Interactive REPL
  As a user
  I want a line editor with history and cursor movement
  So that I can edit multi-word prompts comfortably
```

#### Scenario: Basic input
```
  When the user types "hello world" and presses Enter
  Then "hello world" is returned as the line
  And the line is added to history
```

#### Scenario: Up arrow recalls history
```
  Given history contains ["first command", "second command"]
  When the user presses Up once
  Then the line shows "second command"
  And the cursor is at the end of the line
  When the user presses Up again
  Then the line shows "first command"
```

#### Scenario: Down arrow returns to current draft
```
  Given the user typed "partial" then pressed Up to see history
  When the user presses Down past the most recent entry
  Then the line returns to "partial"
  And the cursor is at the end
```

#### Scenario: Ctrl+D on empty line exits
```
  Given the line is empty
  When the user presses Ctrl+D
  Then nil is returned (EOF)
  And the REPL exits
```

#### Scenario: Ctrl+D on non-empty line does not exit
```
  Given the line contains "some text"
  When the user presses Ctrl+D
  Then the character is not treated as EOF
```

#### Scenario: Ctrl+C clears line
```
  When the user presses Ctrl+C
  Then "^C" is printed
  And an empty string is returned
```

#### Scenario: Left/Right arrow keys move cursor
```
  Given the line is "abcd" and cursor is at position 4
  When the user presses Left
  Then cursor is at position 3
  When the user presses Right
  Then cursor is at position 4
```

#### Scenario: Home key
```
  Given cursor is at position 5
  When the user presses Home
  Then cursor is at position 0
```

#### Scenario: End key
```
  Given cursor is at position 0 and line is "hello"
  When the user presses End
  Then cursor is at position 5
```

#### Scenario: Backspace deletes character before cursor
```
  Given line is "abc" and cursor is at position 2
  When the user presses Backspace
  Then line becomes "ac" and cursor is at position 1
```

#### Scenario: Delete key removes character at cursor
```
  Given line is "abc" and cursor is at position 1
  When the user presses Delete
  Then line becomes "ac" and cursor is at position 1
```

#### Scenario: Bracketed paste
```
  When the user pastes "line1\nline2\nline3"
  Then the newlines are converted to \n
  And the text is inserted at cursor position
```

#### Scenario: History deduplication
```
  Given history already contains "repeat me" as the most recent entry
  When the user enters "repeat me" again
  Then "repeat me" is not duplicated in history
```

#### Scenario: History max 100 entries
```
  Given history has 100 entries
  When a new entry is added
  Then the oldest entry is dropped
  And history still has 100 entries
```

#### Scenario: ANSI codes stripped for visual width
```
  Given the prompt contains ANSI color codes like "\033[36m> \033[0m"
  When calculating cursor position
  Then the ANSI codes are not counted toward visual width
```

### Feature: Slash Commands

```
Feature: Built-in slash commands
  As a user
  I want commands for session management
  So that I can switch contexts without restarting
```

#### Scenario: /help
```
  When the user types /help
  Then available commands are listed: /help /exit /sessions /resume <id> /new /model <name>
  And the REPL continues
```

#### Scenario: /exit
```
  When the user types /exit
  Then "Exiting..." is printed
  And the REPL exits
  And terminal settings are restored
```

#### Scenario: /sessions
```
  Given sessions exist
  When the user types /sessions
  Then a list of sessions is printed with id, created, message count, cwd
```

#### Scenario: /resume <id>
```
  Given session "20260529-201630-1000" exists
  When the user types /resume 20260529-201630-1000
  Then the current session is replaced with the loaded session
  And "Resumed session 20260529-201630-1000" is printed
```

#### Scenario: /resume with nonexistent id
```
  When the user types /resume nonexistent
  Then "Session 'nonexistent' not found." is printed in red
  And the current session is unchanged
```

#### Scenario: /new
```
  When the user types /new
  Then a new session is created
  And "New session: <id>" is printed
  And the message history is cleared
```

#### Scenario: /model <name>
```
  When the user types /model gpt-4o
  Then the active model is changed to "gpt-4o"
  And "Model set to: gpt-4o" is printed
  And the change applies to subsequent turns in this session
```

---

## 6. Agent Loop Contract

### Feature: Agent Execution Loop

```
Feature: Agent run loop
  As a user
  I want the agent to process my prompt through the LLM and execute tool calls
  So that coding tasks are automated
```

#### Scenario: First message sets system prompt
```
  Given a new session with empty message history
  When the agent runs with user input "hello"
  Then the first message is a system-role message containing:
    "You are cluade, a coding agent running on OpenWRT (busybox ash, Linux MIPS)."
  And the system message includes environment context (busybox tools, no Python, /tmp)
  And a second user-role message with content "hello" is appended
```

#### Scenario: System prompt includes skill list
```
  Given skills exist in ~/.cluade/skills/ and/or ./.cluade/skills/
  When the agent builds the system prompt
  Then an "Available skills" section lists each skill name and its description
  And the section is rebuilt fresh every turn
  And it never appears twice in a resumed session
```

#### Scenario: System prompt includes project instructions
```
  Given ./AGENTS.md exists in cwd or a parent directory up to git root
  When the agent builds the system prompt
  Then the content of AGENTS.md is appended to the system prompt
  And if AGENTS.md does not exist, CLAUDE.md is tried, then GEMINI.md
  And the nearest ancestor file wins (walk up from cwd, stop at git root)
  And a global ~/.cluade/AGENTS.md is prepended before the local file
```

#### Scenario: Agent sends messages to LLM
```
  Given the agent has a system message and user message
  When the agent calls the LLM
  Then a POST is made to {base_url}/chat/completions
  And the request body contains: model, messages, tools (up to 12 definitions), tool_choice: "auto"
  And thinking: { type: "enabled" } is included unless config.thinking is false
  And reasoning_effort is set from config (default "max")
  And max_tokens is set from config (default 131072)
```

#### Scenario: Toolset for normal (attended) agent
```
  Given config.subagent is nil or false
  When the toolset is assembled
  Then all 12 tools are available: read, write, edit, bash, glob, grep, web_search, web_fetch, remote_bash, compact, skill, subagent
```

#### Scenario: Toolset for subagent (build mode)
```
  Given config.subagent is true and config.plan is nil or false
  When the toolset is assembled
  Then 11 tools are available: read, write, edit, bash, glob, grep, web_search, web_fetch, remote_bash, compact, skill
  And subagent is NOT in the toolset (recursion capped at depth 1 by construction)
```

#### Scenario: Toolset for subagent (plan mode)
```
  Given config.subagent is true and config.plan is true
  When the toolset is assembled
  Then 5 tools are available: read, grep, glob, web_search, web_fetch
  And write, edit, bash, remote_bash, compact, skill, subagent are all excluded
```

#### Scenario: Agent receives text response
```
  Given the LLM returns a response with content but no tool_calls
  And finish_reason is "stop"
  When the agent processes the response
  Then the content is printed to stdout
  And the assistant message is appended to history
  And the loop exits with reason "done"
```

#### Scenario: Agent receives tool calls
```
  Given the LLM returns tool_calls: [{ function: { name: "bash", arguments: '{"command":"ls"}' } }]
  When the agent processes the response
  Then the tool call is printed: "[using tool: bash {"command":"ls"}]"
  And the tool is executed
  And the result is appended as a tool-role message with the tool_call_id
  And the loop continues to the next step
```

#### Scenario: Step counter increments
```
  Given the agent starts at step 1
  When each LLM call is made
  Then "[step N] thinking..." is printed at the start of each step
```

#### Scenario: Reasoning content displayed
```
  Given the LLM response includes reasoning_content
  When the agent processes the response
  Then "[reasoned for <N>s, <M> chars]" is printed in dim/magenta
```

#### Scenario: Max steps safety backstop
```
  Given config.max_steps is 100
  And the agent has run 100 steps without finishing
  When step 101 would begin
  Then "[reached the safety backstop of 100 steps...]" is printed in yellow
  And the loop exits
```

#### Scenario: Context threshold warning
```
  Given context is estimated at 90% of config.context_limit (200000)
  And config.compact_threshold is 0.85
  When the agent estimates context after a step
  Then "[context at 90% (180000/200000). Consider compacting.]" is printed
```

#### Scenario: Status bar after run (non-quiet mode)
```
  Given an agent run completes and config.quiet is not set
  When the loop ends
  Then a status line is printed:
    "-- <model> - <total_tokens> tokens - <X.X>% context - <elapsed>s"
  And total_tokens is the cumulative usage across the run
  And context percentage is estimated context / context_limit * 100
```

#### Scenario: No status bar in quiet mode
```
  Given config.quiet is true (--subagent or --quiet)
  When the agent run completes
  Then no status bar is printed to stdout
  And only the final assistant message is written to stdout
```

#### Scenario: Session saved after run (non-ephemeral)
```
  Given an agent run (any outcome) and config.ephemeral is not set
  When the run method returns
  Then the session is saved to disk
  And the saved data includes: messages, steps, total_tokens, context_tokens
```

#### Scenario: Session NOT saved after ephemeral run
```
  Given an agent run and config.ephemeral is true (--subagent or --no-session)
  When the run method returns
  Then no session file is persisted to disk
```

---

## 7. Tool Execution Contract

### Feature: read tool

```
Feature: File reading
  As an agent
  I want to read files with line numbers
  So that I can reference specific lines for editing
```

#### Scenario: Read existing file
```
  Given a file /tmp/example.txt contains "hello\nworld\n"
  When the agent calls read with filePath="/tmp/example.txt"
  Then the output is:
    1: hello
    2: world
  And status is "ok"
```

#### Scenario: Read non-existent file
```
  Given no file exists at /tmp/nonexistent.txt
  When the agent calls read with filePath="/tmp/nonexistent.txt"
  Then status is "error"
  And the error message contains the system error
```

#### Scenario: Read with relative path
```
  Given cwd is /home/user
  And file ./config.txt exists
  When the agent calls read with filePath="config.txt"
  Then the path resolves to /home/user/config.txt
```

### Feature: write tool

```
Feature: File writing
  As an agent
  I want to create or overwrite files
  So that I can produce code and configuration
```

#### Scenario: Write new file
```
  Given /tmp/newfile.lua does not exist
  When the agent calls write with filePath="/tmp/newfile.lua", content="print('hi')"
  Then the file is created with content "print('hi')"
  And output is "wrote /tmp/newfile.lua"
  And status is "ok"
```

#### Scenario: Write creates parent directories
```
  Given /tmp/deep/nested/ does not exist
  When the agent calls write with filePath="/tmp/deep/nested/file.txt", content="data"
  Then directories /tmp/deep/nested/ are created
  And the file is written
```

#### Scenario: Write overwrites existing file
```
  Given /tmp/existing.txt contains "old content"
  When the agent calls write with filePath="/tmp/existing.txt", content="new content"
  Then the file now contains "new content"
```

### Feature: edit tool

```
Feature: Exact string replacement in files
  As an agent
  I want to perform surgical edits
  So that I can modify code without rewriting entire files
```

#### Scenario: Edit single occurrence
```
  Given /tmp/code.lua contains "local x = 1"
  When the agent calls edit with filePath="/tmp/code.lua", oldString="local x = 1", newString="local x = 2"
  Then the file now contains "local x = 2"
  And output is "replaced 1 occurrence(s) in /tmp/code.lua"
```

#### Scenario: Edit with replaceAll
```
  Given /tmp/code.lua contains "foo\nbar\nfoo\n"
  When the agent calls edit with filePath="/tmp/code.lua", oldString="foo", newString="baz", replaceAll=true
  Then the file contains "baz\nbar\nbaz\n"
  And output is "replaced 2 occurrence(s) in /tmp/code.lua"
```

#### Scenario: Edit with oldString not found
```
  Given /tmp/code.lua contains "hello"
  When the agent calls edit with filePath="/tmp/code.lua", oldString="nonexistent", newString="x"
  Then status is "error"
  And error message is "oldString not found in content"
  And the file is unchanged
```

#### Scenario: Edit with multiple matches and no replaceAll
```
  Given /tmp/code.lua contains "dup\ndup\n"
  When the agent calls edit with filePath="/tmp/code.lua", oldString="dup", newString="fixed"
  Then status is "error"
  And error message is "Found multiple matches for oldString"
```

### Feature: bash tool

```
Feature: Shell command execution
  As an agent
  I want to run shell commands in the user's environment
  So that I can build, test, and inspect the system
```

#### Scenario: Execute simple command
```
  When the agent calls bash with command="echo hello"
  Then the output is "hello\n"
  And status is "ok"
```

#### Scenario: Execute with working directory
```
  When the agent calls bash with command="pwd", workdir="/tmp"
  Then the command runs in /tmp
  And output contains "/tmp"
```

#### Scenario: Command with non-zero exit
```
  When the agent calls bash with command="false"
  Then output includes "[exit code: 1]"
  And status is still "ok" (the tool succeeded; the command failed)
```

#### Scenario: Command with stderr
```
  When the agent calls bash with command="echo err >&2"
  Then both stdout and stderr are captured (via 2>&1)
  And output contains "err"
```

#### Scenario: Pipe and redirect work
```
  When the agent calls bash with command="echo hello | tr 'a-z' 'A-Z'"
  Then output is "HELLO\n"
```

### Feature: glob tool

```
Feature: File globbing
  As an agent
  I want to find files by pattern
  So that I can discover project structure
```

#### Scenario: Simple glob
```
  Given /tmp/test/ contains a.lua, b.lua, c.txt
  When the agent calls glob with pattern="/tmp/test/*.lua"
  Then output lists a.lua and b.lua
  And c.txt is not listed
```

#### Scenario: Recursive glob with **
```
  Given /tmp/proj/ contains src/main.lua and src/sub/util.lua
  When the agent calls glob with pattern="/tmp/proj/**/*.lua"
  Then both main.lua and util.lua are listed
  And the search uses find -name with head -100 cap
```

#### Scenario: Relative pattern resolves against path
```
  Given cwd is /home/user and path param is "src"
  When the agent calls glob with pattern="*.lua", path="src"
  Then pattern resolves to /home/user/src/*.lua
```

#### Scenario: No matches
```
  Given no files match pattern "/tmp/nonexistent-*.xyz"
  When the agent calls glob
  Then output is "(no matches)"
  And status is "ok"
```

#### Scenario: Results capped at 100
```
  Given a directory contains 200 matching files
  When the agent calls glob
  Then at most 100 results are returned
```

### Feature: grep tool

```
Feature: Pattern search in files
  As an agent
  I want to search codebases with regex
  So that I can find definitions, usages, and patterns
```

#### Scenario: Basic grep
```
  Given /tmp/code/a.lua contains "function hello()"
  When the agent calls grep with pattern="function hello", path="/tmp/code"
  Then output shows a.lua:<line>:function hello()
```

#### Scenario: Grep with include filter
```
  Given /tmp/code/ contains a.lua and b.txt, both containing "TODO"
  When the agent calls grep with pattern="TODO", path="/tmp/code", include="*.lua"
  Then only a.lua matches are shown
```

#### Scenario: No matches
```
  Given no files contain "xyznonexistent"
  When the agent calls grep
  Then output is "(no matches)"
```

#### Scenario: Results capped at 100 lines
```
  Given grep would produce 200 matching lines
  When the agent calls grep
  Then at most 100 lines are returned (head -100)
```

### Feature: web_search tool

```
Feature: Web search
  As an agent
  I want to search the web
  So that I can find documentation and solutions
```

#### Scenario: Basic web search
```
  When the agent calls web_search with query="lua string manipulation"
  Then the query is URL-encoded and sent to https://html.duckduckgo.com/html/?q=lua+string+manipulation
  And results are parsed from the HTML
  And each result includes title, snippet, and link
  And a Chrome 147 user-agent is used
  And timeout is 15 seconds
  And TLS 1.2 is enforced
```

#### Scenario: No results
```
  Given the search returns no result links
  When the agent calls web_search
  Then output is "(no results)"
  And status is "ok"
```

#### Scenario: Search failure
```
  Given the HTTP request fails (network error)
  When the agent calls web_search
  Then status is "error"
  And error message is "search failed: <details>"
```

### Feature: web_fetch tool

```
Feature: URL fetching
  As an agent
  I want to fetch web page content
  So that I can read documentation and API responses
```

#### Scenario: Fetch URL
```
  When the agent calls web_fetch with url="https://example.com"
  Then the content is fetched and returned
  And status is "ok"
  And response is capped at 32000 bytes
  And if truncated: "[... truncated at 32000 bytes]" is appended
```

#### Scenario: Fetch failure
```
  Given the URL is unreachable
  When the agent calls web_fetch
  Then status is "error"
  And error message is "fetch failed: <details>"
```

### Feature: remote_bash tool

```
Feature: Remote command execution via SSH
  As an agent
  I want to execute commands on remote hosts
  So that I can manage multiple machines
```

#### Scenario: Execute remote command
```
  When the agent calls remote_bash with host="192.168.1.1", command="uptime"
  Then "ssh -y -p 22 root@192.168.1.1 'uptime'" is executed
  And output is captured
```

#### Scenario: Remote with custom user and port
```
  When the agent calls remote_bash with host="server.com", command="ls", username="admin", port="2222"
  Then "ssh -y -p 2222 admin@server.com 'ls'" is executed
```

#### Scenario: Remote command with non-zero exit
```
  Given the remote command fails
  When the agent calls remote_bash
  Then output includes "[exit code: <N>]"
```

### Feature: compact tool

```
Feature: Context compaction
  As an agent
  I want to summarize conversation history to free context
  So that I can work on long tasks without hitting context limits
```

#### Scenario: Compact conversation
```
  Given the agent has a long message history
  When the agent calls compact with summary="Fixed the login bug by updating auth.lua"
  Then a new system message is created combining the base system prompt with the summary
  And the message history is pruned to:
    - The new system message
    - The last user message (the one that triggered compaction)
    - The compact tool result message
  And "[Compacted: context freed for next task]" is printed
  And skills list and project instructions are re-added to the new system message
```

#### Scenario: Compaction triggered by nudge
```
  Given context is over 85% of limit (config.compact_threshold = 0.85)
  When the agent estimates context after a step
  Then a message suggests compacting
  But compaction only happens when the LLM chooses to call the compact tool
```

### Feature: skill tool

```
Feature: Skill loading
  As an agent
  I want to load skill instructions on demand
  So that I can follow specialized workflows
```

#### Scenario: Load existing skill
```
  Given a skill "brainstorming" exists at ~/.cluade/skills/brainstorming/SKILL.md
  When the agent calls skill with name="brainstorming"
  Then the SKILL.md content is returned (without YAML frontmatter)
  And status is "ok"
```

#### Scenario: Load non-existent skill
```
  Given no skill "nonexistent" exists
  When the agent calls skill with name="nonexistent"
  Then status is "error"
  And error message lists available skill names
```

#### Scenario: Skill discovery at startup
```
  Given skills exist in ~/.cluade/skills/ and ./.cluade/skills/
  When the agent initializes
  Then both directories are scanned for SKILL.md files
  And skills with disable-model-invocation: true in frontmatter are excluded
  And skill name defaults to the directory name if not set in frontmatter
  And the available skills list is added to the system prompt
```

### Feature: subagent tool

```
Feature: Child agent delegation
  As an agent
  I want to delegate tasks to a child cluade with fresh context
  So that my own context stays clean for the main task
```

#### Scenario: Spawn a build subagent
```
  Given self_cmd is set (cluade can re-invoke itself)
  When the agent calls subagent with prompt="find all TODOs in src/", mode="build"
  Then a child process is spawned: <cluade_cmd> --subagent '<prompt>'
  And the child's stderr passes through (progress chatter)
  And the child's stdout is captured as the tool result
  And the result status is "ok"
  And the parent's context is not consumed by the child's work
```

#### Scenario: Spawn a plan subagent (read-only)
```
  When the agent calls subagent with prompt="audit config.lua", mode="plan"
  Then the child is spawned with: <cluade_cmd> --subagent --plan '<prompt>'
  And the child has only read/grep/glob/web_search/web_fetch tools
```

#### Scenario: Subagent tool unavailable when self_cmd not set
```
  Given self_cmd is nil (bootstrap not complete)
  When the agent calls subagent
  Then status is "error"
  And error message is "subagent unavailable: cluade self-command not set"
```

#### Scenario: Subagent requires non-empty prompt
```
  Given self_cmd is set
  When the agent calls subagent with an empty or missing prompt
  Then status is "error"
  And error message is "subagent requires a non-empty 'prompt'"
```

#### Scenario: Subagent prompt is shell-escaped
```
  Given the prompt contains a single quote: "it's broken"
  When the child command is constructed
  Then the single quote is escaped as '\'' (shell-safe)
```

#### Scenario: Subagent returns empty output
```
  Given the child process produces no output
  When the result is assembled
  Then output is "(subagent returned no text)"
  And status is "ok"
```

#### Scenario: Subagent not offered to subagents (recursion capped at depth 1)
```
  Given a cluade is running in --subagent mode
  When its toolset is assembled
  Then the "subagent" tool is NOT in the toolset
  And it cannot spawn further subagents
  And recursion depth is structurally limited to 1
```

---

## 8. Permission System Contract

### Feature: Tool Permissions

```
Feature: Permission model
  As a system
  I want to control which tools run automatically vs. require user approval
  So that the user maintains control over dangerous operations
```

#### Scenario: Default permissions
```
  When no config overrides are set
  Then these tools are "allow": read, write, edit, bash, glob, grep, web_search, web_fetch, compact, skill, subagent
  And remote_bash is "ask"
  And any unknown tool defaults to "ask"
```

#### Scenario: Allow permission — auto-execute
```
  Given bash is "allow"
  When the agent calls bash with command="ls"
  Then the command executes without prompting
  And the green tool label is printed: "[using tool: bash ...]"
```

#### Scenario: Ask permission — prompt user
```
  Given remote_bash is "ask"
  When the agent calls remote_bash with host="server.com", command="ls"
  Then "Allow remote_bash: root@server.com: ls?" is printed
  And the user is prompted "[y/N]"
  And terminal mode is temporarily switched to cooked for the prompt
  When the user answers "y"
  Then the command executes
  When the user answers "n" (or anything not starting with "y")
  Then status is "error" with message "user denied remote_bash"
```

#### Scenario: Deny permission — refuse
```
  Given bash is "deny"
  When the agent calls bash
  Then "[denied: bash]" is printed in red
  And status is "error" with message "tool 'bash' is denied"
  And the command is never executed
```

#### Scenario: Config file overrides defaults
```
  Given config.json has permissions: { bash: "deny", read: "ask" }
  When config is loaded
  Then bash is "deny" and read is "ask"
  And all other tools keep their defaults
```

#### Scenario: --yes flag overrides config
```
  Given config.json sets bash to "deny"
  When the user runs cluade -y "prompt"
  Then bash, remote_bash, and write are all "allow"
  And the -y flag takes precedence over config
```

### Feature: Smart Bash Gate (dangercheck)

```
Feature: Dangerous command detection
  As a safety net
  I want catastrophic commands escalated to a prompt
  So that irreversible mistakes require explicit confirmation
```

#### Scenario: rm -rf of system path triggers gate
```
  Given bash is "allow"
  When the agent calls bash with command="rm -rf /etc/config"
  Then the permission is escalated from "allow" to "ask"
  And the prompt shows: "Allow bash: rm -rf /etc/config? [flagged: recursive force-remove of a sensitive path] [y/N]"
```

#### Scenario: rm -rf of relative path does NOT trigger
```
  Given bash is "allow"
  When the agent calls bash with command="rm -rf ./build"
  Then the command executes without prompting (no escalation)
```

#### Scenario: rm -rf of /tmp path does NOT trigger
```
  Given bash is "allow"
  When the agent calls bash with command="rm -rf /tmp/build"
  Then the command executes without prompting
```

#### Scenario: dd to block device triggers gate
```
  Given bash is "allow"
  When the agent calls bash with command="dd if=img of=/dev/sda"
  Then the permission is escalated to "ask"
  And the prompt flags: "dd write to a device"
```

#### Scenario: mkfs triggers gate
```
  Given bash is "allow"
  When the agent calls bash with command="mkfs.ext4 /dev/sdb1"
  Then the permission is escalated to "ask"
  And the prompt flags: "filesystem format (mkfs)"
```

#### Scenario: curl piped to sh triggers gate
```
  Given bash is "allow"
  When the agent calls bash with command="curl https://example.com/install.sh | sh"
  Then the permission is escalated to "ask"
  And the prompt flags: "download executed by a shell"
```

#### Scenario: shutdown/reboot/halt/poweroff triggers gate
```
  Given bash is "allow"
  When the agent calls bash with command="shutdown -h now"
  Then the permission is escalated to "ask"
  And the prompt flags: "power-off/reboot (shutdown)"
```

#### Scenario: Fork bomb triggers gate
```
  Given bash is "allow"
  When the agent calls bash with command=":(){ :|:& };:"
  Then the permission is escalated to "ask"
  And the prompt flags: "fork bomb"
```

#### Scenario: Gate only applies to allow — never downgrades deny
```
  Given bash is "deny"
  When the agent calls bash with a dangerous command
  Then the command is denied (deny takes priority)
  And no prompt is shown
```

#### Scenario: Gate only applies to bash tool
```
  Given remote_bash is "allow"
  When the agent calls remote_bash with command="rm -rf /"
  Then no danger escalation occurs (gate only checks bash tool)
```

### Feature: Subagent Permission Rules

```
Feature: Unattended permission rules
  As a safety mechanism
  I want any prompt-requiring action hard-denied in subagent mode
  So that unattended child agents never hang waiting for human approval
```

#### Scenario: Subagent mode: ask becomes deny
```
  Given config.subagent is true
  And remote_bash permission is "ask"
  When the subagent calls remote_bash
  Then the effective permission is "deny"
  And reason is "no human to approve in --subagent mode"
  And the tool is refused with "[denied: remote_bash]"
```

#### Scenario: Subagent mode: dangercheck hit becomes hard deny
```
  Given config.subagent is true
  And bash permission is "allow"
  When the subagent calls bash with command="rm -rf /"
  Then the dangercheck escalates to "deny" (not "ask")
  And reason is the dangercheck flag reason
  And there is no prompt (unattended)
```

#### Scenario: Subagent mode: allow stays allow
```
  Given config.subagent is true
  And write permission is "allow"
  When the subagent calls write with filePath="/tmp/x", content="data"
  Then the write executes without prompting
  And the knife still cuts — ordinary file/shell operations run unattended
```

#### Scenario: Normal (attended) mode: dangercheck escalates to ask
```
  Given config.subagent is nil or false
  And bash permission is "allow"
  When the agent calls bash with command="rm -rf /"
  Then the effective permission is "ask" (not "deny")
  And a [y/N] prompt is shown to the user
```

---

## 9. Loop Detection Contract

### Feature: Loop Detection

```
Feature: Agent loop detection
  As a safety mechanism
  I want the agent stopped when it's stuck in a loop
  So that tokens and time are not wasted
```

#### Scenario: Identical tool calls trigger warn-then-stop
```
  Given the agent calls bash with command="ls" three times consecutively
  When the third identical call is recorded
  Then a warning message is injected into the conversation:
    "[cluade] You have called the same tool with identical arguments 3 times in a row..."
  And the loop continues
  When a fourth identical call would be made
  Then the loop stops with reason "loop"
  And "[stopped: the model appears stuck...]" is printed in yellow
```

#### Scenario: Different tool call resets repeat counter
```
  Given the agent calls bash with "ls" twice
  When the agent calls read with "/tmp/file.txt"
  Then the repeat counter resets
  And no warning is triggered
```

#### Scenario: Same tool, different arguments resets counter
```
  Given the agent calls bash with "ls" twice
  When the agent calls bash with "ls -la"
  Then the repeat counter resets
```

#### Scenario: Consecutive errors trigger warn-then-stop
```
  Given the agent's last 3 tool calls all returned errors
  When the 4th tool call also returns an error
  Then a warning is injected: "...The last 4 tool calls all returned errors..."
  And the loop continues
  When a 5th error would occur
  Then the loop stops
```

#### Scenario: Success resets error counter
```
  Given the agent had 3 errors in a row
  When the next tool call succeeds
  Then the error counter resets to 0
  And no warning is triggered
```

#### Scenario: Signature order independence
```
  Given the agent calls bash with {"command": "ls", "workdir": "/tmp"}
  When the agent calls bash with {"workdir": "/tmp", "command": "ls"}
  Then these are treated as identical (key order normalized)
```

#### Scenario: Warning disarms on behavior change
```
  Given a repeat warning was issued
  When the agent makes a different tool call
  Then the warning state is cleared
  And if the agent later repeats again, a new warning is issued (not an instant stop)
```

---

## 10. Provider Contract

### Feature: LLM API Communication

```
Feature: HTTP provider
  As the agent
  I want to communicate with OpenAI-compatible APIs via curl
  So that I work on systems without Lua HTTP libraries
```

#### Scenario: Successful API call
```
  Given base_url is "https://api.deepseek.com/v1"
  And api_key is "sk-abc"
  When the agent calls the LLM
  Then a POST is made to "https://api.deepseek.com/v1/chat/completions"
  And the request body is written to a temp file, sent via curl -d @<tmpfile>
  And headers include Content-Type: application/json and Authorization: Bearer sk-abc
  And --http1.1 is used (via curl flag)
  And --max-time matches config.request_timeout (default 600)
  And the response is parsed as JSON
```

#### Scenario: HTTP error response
```
  Given the API returns HTTP 401
  When the agent processes the response
  Then "[provider error: HTTP 401: <error message from body>]" is printed
  And the agent loop stops with reason "error"
```

#### Scenario: Curl transport failure
```
  Given curl exits with code 7 (connection refused)
  When the agent processes the response
  Then "[provider error: request failed (HTTP <code>, curl exit 7: <stderr>)]" is printed
  And the agent loop stops with reason "error"
```

#### Scenario: Timeout
```
  Given curl exits with code 28 (timeout)
  When the agent processes the response
  Then the error includes "curl exit 28"
```

#### Scenario: Empty response
```
  Given the API returns an empty body
  When the agent processes the response
  Then "[provider error: empty response from API (curl exit <n>)]" is printed
```

#### Scenario: Malformed JSON response
```
  Given the API returns invalid JSON
  When the agent processes the response
  Then the error includes "failed to parse response" and first 300 chars of body
```

#### Scenario: No choices in response
```
  Given the API returns valid JSON but no choices array
  When the agent processes the response
  Then "[provider error: no choices in response]" is printed
```

#### Scenario: Thinking mode control
```
  Given config.thinking is explicitly set to false
  When the request body is built
  Then no "thinking" field is sent
  And no "reasoning_effort" field is sent
```

#### Scenario: Default reasoning effort
```
  Given config does not set reasoning_effort
  When the request body is built
  Then reasoning_effort is "max"
```

---

## 11. Output Formatting Contract

### Feature: ANSI Color Output

```
Feature: Terminal output formatting
  As a user
  I want color-coded output
  So that I can quickly distinguish different types of information
```

#### Scenario: Color assignments
```
  When text is output:
  Then step labels ([step N] thinking...) are cyan (\033[36m)
  And tool execution labels ([using tool: ...]) are green (\033[92m)
  And the REPL prompt ("> ") is cyan (\033[96m)
  And status bar (-- model - tokens...) is magenta/dim (\033[35m)
  And errors and denials are red (\033[91m)
  And warnings and loop messages are yellow (\033[33m)
  And provider errors are red (\033[31m)
  And info/dim messages are magenta (\033[35m)
```

#### Scenario: ANSI reset after each colored segment
```
  When a colored string is emitted
  Then it is always terminated with \033[0m
```

#### Scenario: Tool labels are context-aware
```
  When a skill tool executes
  Then the label is "using skill: <skill_name>" (not the raw JSON args)
  When a compact tool executes
  Then the label is "using tool: compact" (summary omitted to keep the line tidy)
  When any other tool executes
  Then the label is "using tool: <name> <args_json>" (truncated to 200 chars if longer)
```

---

## 12. Session File Format Contract

### Feature: Session JSON Schema

```
Feature: Session file format
  As the system
  I want sessions stored in a well-defined JSON format
  So that they are portable and debuggable
```

#### Scenario: Session file structure
```
  Given a session is saved
  Then the JSON file at ~/.cluade/sessions/<id>.json contains:
  {
    "id": "20260529-201630-1000",
    "cwd": "/home/user/project",
    "created": "2026-05-29 20:16:30",
    "messages": [
      { "role": "system", "content": "..." },
      { "role": "user", "content": "..." },
      { "role": "assistant", "content": "...", "tool_calls": [...] },
      { "role": "tool", "tool_call_id": "...", "content": "..." }
    ],
    "steps": 5,
    "total_tokens": 12345,
    "context_tokens": 8200
  }
```

#### Scenario: Last session pointer
```
  Given a session was created or resumed
  When the session is set as active
  Then ~/.cluade/last_session contains only the session id
```

---

## 13. Config File Format Contract

### Feature: Config JSON Schema

```
Feature: Configuration file format
  As a user
  I want a JSON config file with documented keys
  So that I can customize cluade behavior
```

#### Scenario: Config keys
```
  Given a config.json file
  Then these keys are recognized:
    | base_url          | string  | API base URL (default: https://api.deepseek.com/v1) |
    | model             | string  | Model name (default: deepseek-v4-pro)               |
    | api_key           | string  | API key (default: "")                                |
    | max_steps         | number  | Safety backstop step limit (default: 100)            |
    | max_tokens        | number  | Max tokens per request (default: 131072)             |
    | request_timeout   | number  | HTTP request timeout in seconds (default: 600)       |
    | thinking          | boolean | Enable thinking/reasoning (default: true)             |
    | reasoning_effort  | string  | Reasoning effort level (default: "max")              |
    | context_limit     | number  | Context window size for % calculation (default: 200000) |
    | compact_threshold | number  | Fraction of context_limit to nudge compaction (default: 0.85) |
    | permissions       | object  | Per-tool permission overrides                        |
  And unrecognized keys are loaded but never sent to the API
```

---

## 14. Skills Format Contract

### Feature: SKILL.md Format

```
Feature: Skill file format
  As a skill author
  I want to write SKILL.md files with YAML frontmatter
  So that skills are discoverable and self-describing
```

#### Scenario: SKILL.md structure
```
  Given a SKILL.md file
  Then it begins with YAML frontmatter delimited by ---
  And frontmatter keys include: name, description, disable-model-invocation
  And the body after the second --- delimiter contains the skill instructions
  And the skill tool returns only the body (frontmatter stripped)
```

#### Scenario: Frontmatter parsing
```
  Given a SKILL.md with frontmatter:
    ---
    name: brainstorming
    description: Use before creative work
    ---
    # Brainstorming instructions...
  When the skill is scanned
  Then name is "brainstorming"
  And description is "Use before creative work"
  And the skill appears in the available skills list
```

#### Scenario: Missing frontmatter
```
  Given a SKILL.md with no frontmatter
  When the skill is scanned
  Then the directory name is used as the skill name
  And description is "(no description)"
```

#### Scenario: disable-model-invocation
```
  Given a SKILL.md with frontmatter: disable-model-invocation: true
  When skills are scanned
  Then this skill is excluded from the available skills list
  And cannot be loaded via the skill() tool
```

---

## 15. Invariants

These must hold true regardless of implementation language:

1. **Session atomicity:** A session is saved to disk after every `agent:run()` call. Crash at any point loses at most one turn of work. Exception: ephemeral runs (--subagent, --no-session) leave no trace on disk.

2. **Permission precedence:** tools.lua defaults < config.json < --yes flag. Later always wins. CLI --yes sets bash, remote_bash, write to "allow" and runs after config merge.

3. **Danger gate is additive only:** It can escalate `allow` → `ask` but never escalates `deny` or `ask`, and never applies to non-bash tools.

4. **Loop detection is append-only:** It observes calls and results; it never modifies tool behavior. It warns via injected user messages, then stops the loop. It never prevents a tool from executing.

5. **Augmentation freshness:** The skills list and project instructions are rebuilt every turn and never duplicated, even across session resumes or compactions.

6. **Terminal safety:** If the REPL starts in raw mode, it always restores cooked mode on exit (even on error), via `pcall` wrapper and explicit `stty icanon echo`.

7. **Path safety:** All relative file paths resolve against the process cwd (the working directory at invocation time), not the script directory.

8. **No config validation:** Invalid config values are silently ignored or cause runtime errors; there is no config schema validation.

9. **Tool results always return JSON:** Every tool result is `{ status: "ok"|"error"|"compacted", ... }` encoded as a JSON string in the tool-role message content.

10. **Session history is append-only:** Messages are never mutated in place. Compaction replaces the entire messages array with a pruned one.

11. **Subagent recursion is capped at depth 1 by construction:** A subagent's toolset omits the `subagent` tool, so it physically cannot spawn further subagents. No runtime counter is needed.

12. **Subagent unattended rule:** When `config.subagent` is true, any base `ask` permission becomes `deny`, and any dangercheck escalation (which produces `ask` in normal mode) becomes `deny`. `allow` stays `allow`. This applies at the effective-permission level in the agent loop.

13. **Quiet mode output contract:** When `config.quiet` is true, `io.write`/`io.flush` are redirected to `io.stderr` for the duration of the run. Only the final assistant message is emitted to the real stdout before returning. No status bar is printed.

---

## 16. Edge Cases and Error Handling

### Scenario: Provider returns tool_calls with malformed arguments JSON
```
  Given the LLM returns tool_calls with arguments: "{invalid json"
  When the agent tries to parse
  Then "[tool param parse error: ...]" is printed
  And the raw arguments string is used as-is for the tool call
```

### Scenario: Session resume after compaction
```
  Given a session that was compacted mid-run
  When the session is resumed
  Then the system message is the compaction summary (not the original SYSTEM_PROMPT)
  And new turns continue from the compacted state
  And augmentations are rebuilt fresh (no duplication)
```

### Scenario: Non-absolute cwd in session
```
  Given a session was saved with a relative cwd
  When cluade is invoked from a different directory
  Then the relative cwd is used as-is (may cause "file not found" for relative paths)
  This is accepted behavior
```

### Scenario: Concurrent cluade instances
```
  Given two cluade processes run simultaneously
  When both save to the same session id
  Then last writer wins
  And no locking is performed
```

### Scenario: API key in multiple sources
```
  Given config.json has api_key: "sk-config"
  And OPENAI_API_KEY is "sk-env"
  And --api-key "sk-cli" is passed
  When the request is made
  Then "sk-cli" is used (CLI wins)
  If --api-key is not passed:
  Then "sk-config" is used (config wins over env)
  If neither config nor CLI provide a key:
  Then OPENAI_API_KEY (or ANTHROPIC_API_KEY) is used
```

### Scenario: Maximum response tokens exceeded at server side
```
  Given the LLM response is truncated due to max_tokens
  Then finish_reason is "length" (not "stop")
  And the agent does NOT break the loop
  And the truncated content is still processed
```

### Scenario: Subagent output is whitespace-trimmed
```
  Given a subagent returns text with trailing whitespace
  When the parent captures the output
  Then trailing whitespace is stripped before returning as the tool result
```

### Scenario: --show-tools-json includes reasoning_content
```
  Given config.show_tools_json is true
  And the LLM response includes reasoning_content
  When the debug block is printed
  Then the "[tool_calls decoded]" header includes: 'reasoning: "<content>"'
```

### Scenario: Skill execution returns only the body (no frontmatter)
```
  Given a SKILL.md with YAML frontmatter and instructional body
  When the skill tool executes
  Then the returned output is only the body content (after the second ---)
  And the frontmatter is stripped
```

### Scenario: --subagent flag sets all three config flags
```
  When cluade is invoked with --subagent
  Then config.subagent = true
  And config.quiet = true
  And config.ephemeral = true
  And all three are set simultaneously (not just one or two)
```

### Scenario: --plan without --subagent has no effect
```
  When cluade is invoked with --plan but without --subagent
  Then config.plan = true
  But the toolset is NOT restricted (plan flag only matters inside --subagent mode)
```

### Scenario: --quiet without --subagent is standalone
```
  When cluade is invoked with --quiet but without --subagent
  Then progress goes to stderr, final answer to stdout
  But sessions are still persisted (config.ephemeral is not set)
  And permissions still prompt (config.subagent is not set)
```

### Scenario: --no-session without --subagent is standalone
```
  When cluade is invoked with --no-session but without --subagent
  Then no session file is persisted
  But output is normal (config.quiet is not set)
  And permissions still prompt (config.subagent is not set)
```

---

## 17. Tool Catalog (Quick Reference)

| # | Tool | Params (required) | Params (optional) | Permission default |
|---|------|-------------------|-------------------|-------------------|
| 1 | read | filePath | — | allow |
| 2 | write | filePath, content | — | allow |
| 3 | edit | filePath, oldString, newString | replaceAll | allow |
| 4 | bash | command | workdir | allow |
| 5 | glob | pattern | path | allow |
| 6 | grep | pattern | path, include | allow |
| 7 | web_search | query | — | allow |
| 8 | web_fetch | url | — | allow |
| 9 | remote_bash | host, command | username, port | ask |
| 10 | compact | summary | — | allow |
| 11 | skill | name | — | allow |
| 12 | subagent | prompt | mode ("build" or "plan") | allow |

---

## 18. Complete CLI Flag Reference

| Flag | Short | Description |
|------|-------|-------------|
| --model MODEL | -m | LLM model name (default: deepseek-v4-pro) |
| --base-url URL | — | API base URL (default: https://api.deepseek.com/v1) |
| --api-key KEY | — | API key (or env: OPENAI_API_KEY) |
| --continue | -c | Resume the most recent session |
| --resume ID | -r | Resume a specific session by ID |
| --list-sessions | — | List saved sessions |
| --yes | -y | Auto-approve all permission prompts (bash, remote_bash, write → allow) |
| --init | — | Write a default config to ~/.cluade/config.json |
| --show-tools-json | — | Debug: print raw response body + decoded tool_calls + compact view |
| --subagent | — | Unattended child mode: quiet, no-session, ask→deny, dangercheck→deny |
| --plan | — | With --subagent: read-only toolset (read/grep/glob/web_search/web_fetch) |
| --quiet | — | Only the final answer to stdout; progress to stderr |
| --no-session | — | Do not persist a session file |
| --help | -h | Show help text and exit |

---

## 19. Skill Import and Marketplace

### Feature: Skill Import

```
Feature: Import and classify Agent Skills
  As a user
  I want to preview and import skill files from a git repo or local path
  So that I know which skills cluade can fully run before installing
```

#### Scenario: Import from GitHub shorthand
```
  When the user runs: lua5.1 skillimport.lua anthropics/skills --dry-run
  Then the repo is cloned to a temp directory
  And each SKILL.md is inspected for tool and runtime compatibility
  And skills are classified as full, portable, partial, or limited
  And nothing is written to disk (--dry-run)
```

#### Scenario: Import from local path
```
  Given a local directory ./my-skills/ contains SKILL.md files
  When the user runs: lua5.1 skillimport.lua ./my-skills
  Then each skill is copied into ~/.cluade/skills/<name>/
  And a summary shows how many were imported and skipped
```

#### Scenario: Skill verdict tiers
```
  When a skill is classified:
    - "full" means all declared tools are supported and no runtime deps
    - "portable" means no tools declared and no runtime deps (pure instructions)
    - "partial" means some declared tools are unsupported
    - "limited" means it bundles python/node scripts or plugin.json (hard blocker for constrained devices)
```

### Feature: Marketplace Browser

```
Feature: Plugin marketplace compatibility report
  As a user
  I want to browse a Claude Code plugin marketplace
  So that I know which plugins cluade can actually use
```

#### Scenario: Browse a marketplace
```
  When the user runs: lua5.1 marketplace.lua anthropics/skills
  Then the .claude-plugin/marketplace.json is parsed
  And each plugin is listed with a compatibility badge:
    - [OK  ] compatible: usable skills/commands, no blockers
    - [PART] partial: some usable, some blocked
    - [LTD ] limited: only python/node-bound skills
    - [ X  ] incompatible: only hooks/MCP/LSP (nothing cluade can consume)
  And component counts (skills, commands, agents, hooks, mcp, lsp) are shown
```
