# cc-use

A Claude Code skill that lets an outer Claude supervise an inner Claude running in tmux — offloading implementation work to keep the outer context lean for long-running task management.

## The Problem

When you use Claude Code for complex tasks, **everything accumulates in one context window**: every file read, every code edit, every test output, every debugging iteration. A typical bug fix might consume 50k+ tokens just on implementation details, leaving little room for the bigger picture.

This means:
- Long tasks hit context limits and require manual `/compact` or restarts
- Claude loses track of the overall goal while deep in code details
- You can't manage multi-step workflows that span hours of work

## How cc-use Solves It

cc-use splits the work into two layers:

```
┌─────────────────────────────────────────┐
│  Outer Claude (Supervisor)              │  Lean context:
│  ├── Understands the goal               │  only sees ~40 lines
│  ├── Designs the task prompt            │  of inner output
│  ├── Monitors progress via tmux         │  at a time
│  ├── Steers & corrects when needed      │
│  ├── End-to-end acceptance testing      │
│  └── Reports results to user            │
└────────────────┬────────────────────────┘
                 │ tmux send-keys / capture-pane
┌────────────────▼────────────────────────┐
│  Inner Claude (Worker)                  │  Full context:
│  ├── Reads source code                  │  all the code,
│  ├── Writes & edits files               │  edits, tests,
│  ├── Runs tests & debugs               │  and debugging
│  ├── Handles all implementation detail  │  live here
│  └── Can be restarted with fresh context│
└─────────────────────────────────────────┘
```

The inner Claude's file reads, code edits, and command outputs **never enter the outer Claude's context**. The outer Claude only sees brief summaries via `tmux capture-pane`, keeping its context growth minimal.

## Why This Works: The Numbers

From real-world testing (fixing a bug in an MCP server project):

| Metric | Without cc-use (single Claude) | With cc-use (outer) | With cc-use (inner) |
|--------|-------------------------------|--------------------|--------------------|
| Context consumed by code details | Everything in one window | Almost zero | All here (isolated) |
| Can restart with fresh context | Loses all progress | N/A (stays lean) | Yes, outer re-sends task |
| Typical context per monitoring cycle | N/A | ~50 tokens (silent poll) | N/A |

**Key insight**: The inner Claude can be restarted with fresh context at any time. The outer Claude re-sends a task prompt, and the inner Claude picks up where it left off — with a clean context window. This means the overall workflow length is no longer bounded by context limits.

## Use Cases

### Long implementation tasks
> "Add user authentication to this app — registration, login, JWT tokens, password reset"

One Claude would exhaust its context halfway through. With cc-use, the outer Claude manages the multi-step plan while cycling through inner Claude sessions for each sub-task.

### Bug fixes with verification
> "Fix issue #142 and verify it end-to-end"

The outer Claude reproduces the bug first (black-box, like a real user), delegates the fix to the inner Claude, then verifies the fix end-to-end — without ever reading the source code itself.

### Plugin / MCP / Skill development and testing
> "Develop this MCP server and test it actually works"

The inner Claude writes the code. The outer Claude manages the environment (install dependencies, configure MCP, restart Claude when config changes), and tests the result by actually connecting and calling tools.

### Refactoring with confidence
> "Refactor the database layer to use the new ORM"

The outer Claude keeps track of which files need changing and runs end-to-end tests after each batch. The inner Claude does the actual refactoring work, getting fresh context for each batch.

## How It Works (Technical)

1. **You start Claude in `.cc-use/`** inside your project. This is the outer Claude's workspace.

2. **Outer Claude launches inner Claude in tmux**:
   ```bash
   tmux new-session -d -s "cc-use-<project>" -c "<project_dir>" -x 220 -y 50
   tmux pipe-pane -t "cc-use-<project>" -o 'cat >> .cc-use/logs/inner-output.log'
   tmux send-keys -t "cc-use-<project>" "claude" Enter
   ```

3. **Task prompts are sent via tmux** (flattened to single line, text and Enter sent separately to avoid paste-bracketing issues):
   ```bash
   tmux send-keys -t "cc-use-<project>" "$flat_prompt"
   sleep 1
   tmux send-keys -t "cc-use-<project>" Enter
   ```

4. **Monitoring uses silent polling loops** — a single Bash tool call that runs for minutes but only adds ~50 tokens to the outer context:
   ```bash
   for i in $(seq 1 120); do
     output=$(tmux capture-pane -t "cc-use-<project>" -p -S -5 2>/dev/null)
     if echo "$output" | grep -qE '^❯'; then break; fi
     sleep 5
   done
   tmux capture-pane -t "cc-use-<project>" -p -S -40
   ```

5. **Acceptance testing is black-box**: the outer Claude tests like a real user — running commands, calling APIs, using agent-browser for UI verification. It reads documentation but NOT source code.

6. **Inner Claude's context can be managed remotely**:
   ```bash
   tmux send-keys -t "cc-use-<project>" "/compact focus on current task" Enter
   tmux send-keys -t "cc-use-<project>" "/clear" Enter
   ```

## Install

```bash
npx skills add zc277584121/cc-use
```

### Update

```bash
npx skills add zc277584121/cc-use
```

Same command as install — it pulls the latest version and overwrites existing files.

### Manual install

```bash
mkdir -p ~/.claude/skills/cc-use
cp -r skills/cc-use/* ~/.claude/skills/cc-use/
```

## Usage

```bash
# From your project directory
mkdir -p .cc-use
cd .cc-use && claude
```

Then tell Claude your goal. The skill guides it to:
1. Ask your preferred permission mode for the inner Claude
2. Launch an inner Claude in tmux
3. Monitor progress and steer as needed
4. Run end-to-end acceptance tests
5. Report results

You can open the tmux session anytime to see what the inner Claude is doing:
```bash
tmux attach -t cc-use-<your-project-name>
```

## Key Features

- **Context efficiency**: Inner Claude's tool calls never enter outer context
- **Silent polling**: Monitoring loops add ~50 tokens regardless of wait duration
- **Two-step prompt delivery**: Reliably sends prompts of any length to inner Claude
- **Inner context management**: Send `/compact`, `/clear`, `/model` to inner Claude via tmux
- **Black-box acceptance testing**: Outer Claude tests like a user, not a developer
- **Environment tracking**: Records system-level changes in `.cc-use/state/env-changes.md`
- **Browser verification**: Supports agent-browser for end-to-end UI testing
- **Restartable inner sessions**: Inner Claude can be restarted with fresh context anytime

## Requirements

- `tmux` installed
- `claude` CLI (Claude Code) installed
- (Optional) `agent-browser` for browser-based acceptance testing

## License

MIT
