# tmux Operations Reference

## Session Lifecycle

### Create and launch inner Claude
```bash
# Create session with large terminal size
tmux new-session -d -s "cc-use-inner" -c "/path/to/project" -x 220 -y 50

# Increase scrollback buffer (default 2000 is too small)
tmux set-option -t "cc-use-inner" history-limit 50000

# Launch claude
tmux send-keys -t "cc-use-inner" "claude --dangerously-skip-permissions" Enter
```

### Send input to inner Claude

**CRITICAL: Always verify inner Claude is idle before sending input.**
```bash
# Check for idle state (❯ prompt visible)
output=$(tmux capture-pane -t "cc-use-inner" -p -S -3)
echo "$output" | grep -qE '^❯' && echo "ready" || echo "busy"
```

```bash
# Short, single-line instructions (preferred)
tmux send-keys -t "cc-use-inner" "Fix the auth bug in src/auth.ts" Enter

# Send a slash command
tmux send-keys -t "cc-use-inner" "/compact focus on authentication" Enter

# Send Ctrl+C to interrupt
tmux send-keys -t "cc-use-inner" C-c
```

### Sending prompts (IMPORTANT)

Claude Code collapses long pasted text (>~700 chars) into `[Pasted text ...]` and does NOT auto-submit it. To handle this reliably, **always send text and Enter as two separate calls**:

```bash
# CORRECT: Write to temp file, flatten, send text + Enter separately
cat > /tmp/cc-use-prompt.txt <<'PROMPT'
## Task: Fix auth bug

### Goal
Fix token validation in auth.ts

### Done when
All tests in tests/auth/ pass
PROMPT

# Add [CC-USE] prefix to distinguish your instructions from inner output
flat="[CC-USE] $(cat /tmp/cc-use-prompt.txt | tr '\n' ' ')"
tmux send-keys -t "cc-use-inner" "$flat"
sleep 1
tmux send-keys -t "cc-use-inner" Enter
```

**Tested results**:
| Length | Single `send-keys ... Enter` | Two-step (text, then Enter) |
|--------|------------------------------|----------------------------|
| <500 chars | ✅ Works | ✅ Works |
| 500-700 chars | ⚠️ May work | ✅ Works |
| >700 chars | ❌ Collapsed, not submitted | ✅ Works |

**Always use the two-step method** — it works for any length.

```bash
# WRONG: raw multi-line text with actual newlines
tmux send-keys -t "cc-use-inner" "$(cat <<'EOF'
Line 1
Line 2
EOF
)" Enter
# ^^^ Paste bracketing eats the Enter
```

### Avoiding command accumulation

If you send commands while inner Claude is busy, they queue in the terminal buffer and fire in rapid succession when Claude finishes. This causes chaos — especially `/exit` followed by `claude` restart.

**Rule: One command at a time. Always check idle state first.**

### Stop and cleanup
```bash
# Graceful exit
tmux send-keys -t "cc-use-inner" "/exit" Enter
sleep 3

# Kill session (if exit doesn't work)
tmux kill-session -t "cc-use-inner"

```

## Reading Output

### Quick glance (one screen, ~40 lines)
```bash
tmux capture-pane -t "cc-use-inner" -p -S -40
```
Use this for quick status checks. Equivalent to a human glancing at the terminal.

### Capture more context
```bash
# Last 200 lines
tmux capture-pane -t "cc-use-inner" -p -S -200

# Full scrollback buffer
tmux capture-pane -t "cc-use-inner" -p -S -
```

### Screen-diff monitoring (recommended)

Instead of polling for idle state, use `cc_use_watch` which compares screen snapshots:
- Captures screen every N seconds, diffs against previous snapshot
- Small diffs (≤5 lines): outputs incrementally — outer Claude sees only new content
- Large diffs (>5 lines): inner Claude is busy, stays silent
- No diff for consecutive checks: screen is stable, exits

This avoids repeating previously-seen output and minimizes outer context usage.

### Important notes on output capture
- `tmux capture-pane` captures what's **currently rendered** on screen
- It does NOT capture content hidden behind interactive UI (e.g., Ctrl+O expanded details)
- For full conversation history, read Claude's session jsonl files in `~/.claude/projects/`
- `pipe-pane` logs contain raw terminal output including ANSI escape codes

## Checking Session Status

```bash
# Is the session alive?
tmux has-session -t "cc-use-inner" 2>/dev/null && echo "alive" || echo "dead"

# List all sessions
tmux list-sessions

# Check pane dimensions
tmux list-panes -t "cc-use-inner" -F "#{pane_width}x#{pane_height}"
```

## Detecting Inner Claude's State

Read the last few lines of output and look for patterns:

| Pattern | State |
|---------|-------|
| `❯` at start of last line | Idle — waiting for user input |
| `●` or tool names appearing | Running — executing tools |
| `Allow?` or permission dialog | Blocked — waiting for permission |
| `✻ Brewed for` line visible | Just finished a round |
| Shell prompt (e.g., `$`, `(base) user@host:`) | Claude has exited |
| No change between captures | Idle or stuck |

### Polling until idle (recommended pattern)

**Key: Keep loops silent to minimize context usage.** Each Bash tool call = one context entry. A silent loop that runs 5 minutes adds ~50 tokens. Multiple separate calls would each add hundreds.

```bash
# Silent poll — only output on completion. Adjust max iterations for expected task duration.
# 120 iterations × 5s = 10 minutes max
for i in $(seq 1 120); do
  output=$(tmux capture-pane -t "cc-use-inner" -p -S -5 2>/dev/null)
  if echo "$output" | grep -qE '^❯'; then
    echo "IDLE after $((i*5))s"
    break
  fi
  sleep 5
done
# Capture output only AFTER confirming idle
tmux capture-pane -t "cc-use-inner" -p -S -40
```

**Do NOT** echo or print inside the loop body — that output goes into your context.

### Polling until Claude process exits (for restart)

```bash
# Wait for shell prompt to return after /exit
for i in $(seq 1 15); do
  output=$(tmux capture-pane -t "cc-use-inner" -p -S -3)
  if echo "$output" | grep -qE '^\$|^[a-z]+@|^\(base\)'; then
    echo "Claude has exited, shell prompt returned"
    break
  fi
  sleep 2
done
```

## Advanced: Multiple Sessions

If managing multiple inner Claudes (future multi-task support):
```bash
# Create named sessions
tmux new-session -d -s "cc-use-task-1" -c "/path/to/project" -x 220 -y 50
tmux new-session -d -s "cc-use-task-2" -c "/path/to/project" -x 220 -y 50

# List all cc-use sessions
tmux list-sessions -F "#{session_name}" | grep "^cc-use-"
```
