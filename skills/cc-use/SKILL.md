---
name: cc-use
description: >
  Supervise and manage an inner Claude Code instance running in tmux.
  Use this skill when you need to delegate implementation work to an inner Claude
  while focusing on task planning, progress monitoring, and end-to-end acceptance testing.
  Ideal for long-running tasks that would otherwise exhaust a single Claude's context window.
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
  - Agent
---

# cc-use: Claude Code Supervisor Skill

You are an **outer Claude** acting as a supervisor. You delegate implementation work to an **inner Claude** running inside a tmux session, while you focus on planning, monitoring, and verification.

## Why This Exists

A single Claude session accumulates all file reads, edits, command outputs, and debugging iterations in its context window. This skill offloads that work to an inner Claude, so:

- **Inner Claude**: handles implementation details (reads files, writes code, runs tests). Its context fills up with code-level details, and can be restarted fresh when needed.
- **Outer Claude (you)**: only sees high-level status summaries. Your context grows slowly, enabling you to manage much longer workflows.

## Directory Structure

You operate from the `.cc-use/` directory inside the user's project:

```
my-project/
├── .cc-use/                          # Your working directory
│   ├── state/
│   │   ├── session-info.json         # tmux session config and permission mode
│   │   └── env-changes.md           # Track environment modifications for rollback
│   └── logs/
│       └── inner-output.log          # Full output captured via pipe-pane
├── CLAUDE.md                         # Project's own instructions (for inner Claude)
└── (project files...)
```

## Workflow

### Phase 1: Initialize

1. **First-time setup**: Ask the user which permission mode to use for the inner Claude:
   - `--dangerously-skip-permissions` (fully autonomous, only in isolated environments)
   - Default mode (inner Claude will pause for permission prompts; user must approve in tmux)
   - `--allowedTools "Tool1" "Tool2"` (whitelist specific tools)

2. **Create state directory and session config**:
   ```bash
   mkdir -p .cc-use/state .cc-use/logs
   ```

   **Derive the tmux session name from the project directory name** to avoid conflicts:
   ```bash
   # Example: /data2/workspace/my-project → cc-use-my-project
   project_dir="$(cd .. && pwd)"
   session_name="cc-use-$(basename "$project_dir")"
   ```

   Write `session-info.json`:
   ```json
   {
     "tmux_session": "cc-use-<project-dir-name>",
     "permission_mode": "<user's choice>",
     "started_at": "<ISO timestamp>",
     "project_dir": "<absolute path to project root>"
   }
   ```

3. **Understand the project**: Read `../CLAUDE.md` if it exists, but remember — that file contains instructions for the inner Claude's development work, not directives for you.

### Phase 2: Launch Inner Claude

**NOTE**: All examples below use `"cc-use-inner"` as the tmux session name. In practice, always use the session name from `session-info.json` (e.g., `cc-use-my-project`).

```bash
# Create tmux session pointing to the project root
tmux new-session -d -s "cc-use-inner" -c "<project_dir>" -x 220 -y 50

# Increase scrollback buffer
tmux set-option -t "cc-use-inner" history-limit 50000

# Start logging all output
tmux pipe-pane -t "cc-use-inner" -o 'cat >> <.cc-use/logs/inner-output.log>'

# Launch claude with the chosen permission mode
# Example for dangerous mode:
tmux send-keys -t "cc-use-inner" "claude --dangerously-skip-permissions" Enter
# Example for allowedTools mode:
tmux send-keys -t "cc-use-inner" 'claude --allowedTools "Bash(npm *)" "Read" "Edit" "Write" "Glob" "Grep"' Enter
# Example for default mode:
tmux send-keys -t "cc-use-inner" "claude" Enter
```

Wait a few seconds for Claude to initialize, then send the task prompt.

**IMPORTANT — Sending multi-line prompts**: Terminals use paste bracketing which can cause multi-line text to be pasted but NOT submitted. To reliably send prompts:

```bash
# Option 1 (RECOMMENDED): Write prompt to a temp file, then use a single-line command
cat > /tmp/cc-use-prompt.txt <<'PROMPT'
Your multi-line task prompt here...
Line 2...
Line 3...
PROMPT
sleep 5
# Send the prompt as a single-line read command
tmux send-keys -t "cc-use-inner" "$(cat /tmp/cc-use-prompt.txt | tr '\n' ' ')" Enter
```

```bash
# Option 2: For short prompts (single line), send directly
sleep 5
tmux send-keys -t "cc-use-inner" "Fix the bug in auth.ts where the token is not validated" Enter
```

**Never send raw multi-line heredocs via `tmux send-keys`** — paste bracketing will eat the Enter key and the prompt won't be submitted.

### Phase 3: Monitor and Steer (Core Loop)

Repeat this cycle until the goal is achieved:

#### Step 1: Quick glance (like looking at one terminal screen)

```bash
tmux capture-pane -t "cc-use-inner" -p -S -40
```

Read the last ~40 lines. Determine the inner Claude's state:
- **Still running**: output is actively changing, tool calls in progress → wait and check again
- **Waiting for input**: you see the `❯` prompt at the bottom → inner Claude finished a round, read its response
- **Waiting for permission**: you see a permission dialog → either the user handles it in tmux, or you note it
- **Error/stuck**: repeated errors or no progress → intervene

**Polling strategy**: Do NOT use long `sleep` calls (sleep 30, sleep 40, etc.) blindly. Instead:
```bash
# Poll with short intervals until state changes
for i in $(seq 1 30); do
  output=$(tmux capture-pane -t "cc-use-inner" -p -S -5)
  if echo "$output" | grep -qE '^❯|^\$'; then
    break  # Inner Claude is idle, ready for input
  fi
  sleep 5
done
```
This checks every 5 seconds for up to 2.5 minutes, and stops as soon as the inner Claude is idle.

#### Step 2: Read the response (incremental capture)

When the inner Claude has finished a round, read only the **new** output since your last check:

```bash
# Track byte offset for incremental reads
if [ -f .cc-use/state/log-offset ]; then
  offset=$(cat .cc-use/state/log-offset)
else
  offset=0
fi

# Read new content (limit to last 200 lines if too much)
tail -c +$((offset + 1)) .cc-use/logs/inner-output.log | tail -200

# Update offset
wc -c < .cc-use/logs/inner-output.log > .cc-use/state/log-offset
```

#### Step 3: Decide next action

| Situation | Action |
|-----------|--------|
| Inner Claude completed a step successfully | Send next instruction or move to verification |
| Inner Claude is going in the wrong direction | Send correction via `tmux send-keys` |
| Inner Claude hit an error it can't resolve | Analyze the error, provide guidance |
| A milestone is reached | Run verification yourself (tests, browser checks) |
| Inner Claude's context is getting full | Send `/compact` or restart with `/clear` |
| Goal is fully achieved | Move to Phase 4 (Acceptance) |

#### Sending follow-up instructions to inner Claude:
```bash
# IMPORTANT: Always check inner Claude is idle BEFORE sending commands
# Look for the ❯ prompt to confirm it's ready for input
output=$(tmux capture-pane -t "cc-use-inner" -p -S -3)
if echo "$output" | grep -qE '^❯'; then
  tmux send-keys -t "cc-use-inner" "Your next instruction here..." Enter
fi
```

**WARNING — Command accumulation**: If you send multiple commands while inner Claude is busy, they queue up in the terminal input buffer and execute in rapid succession. This is especially dangerous with `/exit` + restart sequences. Always verify the inner Claude is idle before sending any command.

### Phase 4: Acceptance Testing

Once the inner Claude reports completion, verify the results yourself:

**Level 1 — Automated tests**:
```bash
# Run from the project directory
cd <project_dir> && pytest        # Python
cd <project_dir> && npm test      # Node.js
cd <project_dir> && cargo test    # Rust
```

**Level 2 — Browser-based verification** (requires agent-browser):

Check if agent-browser is available:
```bash
which agent-browser
```

If not installed, suggest the user to set it up:
> "Browser verification requires agent-browser. Install it with:
> `npm install -g agent-browser && agent-browser install`
> Then add the skill: `npx skills add vercel-labs/agent-browser`"

If available, use it for end-to-end verification:
```bash
agent-browser open http://localhost:3000
agent-browser snapshot -i
agent-browser screenshot .cc-use/logs/verification.png
# Then read the screenshot to visually verify
```

### Phase 5: Cleanup

1. **Stop inner Claude**:
   ```bash
   tmux send-keys -t "cc-use-inner" "/exit" Enter
   sleep 2
   tmux kill-session -t "cc-use-inner"
   ```

2. **Report to user**: summarize what was done, what was verified, and any remaining items.

3. **Environment rollback** (if needed): check `.cc-use/state/env-changes.md` and either:
   - Automatically revert changes that are safe to revert
   - List changes that need manual attention

## Managing Inner Claude's Context

You can manage the inner Claude's context from outside:

| Command | When to use | How |
|---------|-------------|-----|
| `/compact` | Context getting full, continue same task | `tmux send-keys -t "cc-use-inner" "/compact focus on <current task>" Enter` |
| `/clear` | Switch to a completely different subtask | `tmux send-keys -t "cc-use-inner" "/clear" Enter` |
| `/context` | Check how full the context is | `tmux send-keys -t "cc-use-inner" "/context" Enter` then capture output |
| `/cost` | Monitor token usage | `tmux send-keys -t "cc-use-inner" "/cost" Enter` |
| `/model sonnet` | Switch to cheaper model for simple tasks | `tmux send-keys -t "cc-use-inner" "/model sonnet" Enter` |
| Restart | MCP/plugin config changed, or context exhausted | Exit and relaunch claude in tmux |

### When inner Claude needs a restart (MCP/plugin/settings changed):
```bash
# Step 1: Ensure inner Claude is idle first
tmux send-keys -t "cc-use-inner" "/exit" Enter

# Step 2: Wait for actual exit (check for shell prompt, NOT just sleep)
for i in $(seq 1 15); do
  output=$(tmux capture-pane -t "cc-use-inner" -p -S -3)
  if echo "$output" | grep -qE '^\(base\)|^\$|^zhangchen@'; then
    break  # Shell prompt returned, claude has exited
  fi
  sleep 2
done

# Step 3: Now safe to restart
tmux send-keys -t "cc-use-inner" "claude <permission flags>" Enter

# Step 4: Wait for Claude to be ready
for i in $(seq 1 15); do
  output=$(tmux capture-pane -t "cc-use-inner" -p -S -3)
  if echo "$output" | grep -qE '^❯'; then
    break
  fi
  sleep 2
done

# Step 5: Send new prompt
tmux send-keys -t "cc-use-inner" "Continue the task: <brief context>" Enter
```

### What requires restart vs what doesn't:

| Change | Restart needed? |
|--------|----------------|
| Edit CLAUDE.md | No — dynamically loaded |
| Edit SKILL.md (via --add-dir) | No — hot-reloaded |
| `/reload-plugins` | No — reloads immediately |
| Add MCP server | **Yes** — restart claude |
| Change settings.json | **Yes** — restart claude |
| Change permissions | **Yes** — restart claude |

## Environment Change Tracking

When the inner Claude or you make system-level changes, record them in `.cc-use/state/env-changes.md`:

```markdown
## Environment Changes

### Packages
- [installed] agent-browser (npm global) → revert: `npm uninstall -g agent-browser`

### MCP Servers
- [added] chrome-devtools (scope: project) → revert: `claude mcp remove chrome-devtools`

### Config Files
- [modified] .mcp.json (project level, gitignored) → no revert needed

### System
- [unchanged] No system-level changes made
```

**Rules**:
- **Always ask the user** before: installing global packages, modifying shell config, installing MCP servers, modifying system settings, running sudo commands
- **OK to do without asking**: project-level `npm install` / `uv sync`, creating virtualenvs, running tests, git operations (non-force-push)

## Delegation Discipline

**Do NOT do the inner Claude's job.** As the outer Claude, you should:

- ✅ Read inner Claude's output to understand progress
- ✅ Send instructions and corrections to inner Claude
- ✅ Run acceptance tests (tests, browser checks) to verify results
- ✅ Manage inner Claude's context and lifecycle
- ❌ Do NOT read project source files yourself (let inner Claude do it)
- ❌ Do NOT edit project files directly (send instructions to inner Claude)
- ❌ Do NOT debug build errors yourself (tell inner Claude what you see)
- ❌ Do NOT configure project tooling (tell inner Claude to do it)

The whole point of cc-use is to keep implementation details OUT of your context. If you start reading and editing project files, you lose that advantage.

**Exception**: Acceptance testing in Phase 4 — you may directly run tests, use agent-browser, or read specific output files to verify results.

## Crafting Task Prompts for Inner Claude

Write clear, focused prompts. Include only what the inner Claude needs:

```
## Task: <name>

### Goal
<What to implement/fix — be specific about the deliverable>

### Context
<Only the background info needed for THIS task, not everything>

### Constraints
- Work within <specific directories/files>
- Do not modify <protected files>
- Use <specific tech stack/patterns>

### Done when
- <Testable completion criteria>
- <e.g., "all tests in tests/auth/ pass">
- <e.g., "the login page renders correctly at localhost:3000/login">
```

## References

For detailed guidance on specific topics, see:
- @references/tmux-operations.md — tmux commands and patterns
- @references/environment-management.md — environment tracking and rollback
- @references/acceptance-testing.md — verification strategies
- @references/cc-commands-guide.md — Claude Code slash commands reference
