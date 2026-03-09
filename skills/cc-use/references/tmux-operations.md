# tmux Operations Reference

## Session Lifecycle

### Create and launch inner Claude
```bash
# Create session with large terminal size
tmux new-session -d -s "cc-use-inner" -c "/path/to/project" -x 220 -y 50

# Increase scrollback buffer (default 2000 is too small)
tmux set-option -t "cc-use-inner" history-limit 50000

# Start output logging BEFORE launching claude
tmux pipe-pane -t "cc-use-inner" -o 'cat >> /path/to/.cc-use/logs/inner-output.log'

# Launch claude
tmux send-keys -t "cc-use-inner" "claude --dangerously-skip-permissions" Enter
```

### Send input to inner Claude
```bash
# Send a prompt or instruction
tmux send-keys -t "cc-use-inner" "Your instruction here" Enter

# Send a slash command
tmux send-keys -t "cc-use-inner" "/compact focus on authentication" Enter

# Send Ctrl+C to interrupt
tmux send-keys -t "cc-use-inner" C-c
```

### Stop and cleanup
```bash
# Graceful exit
tmux send-keys -t "cc-use-inner" "/exit" Enter
sleep 3

# Kill session (if exit doesn't work)
tmux kill-session -t "cc-use-inner"

# Stop output logging
tmux pipe-pane -t "cc-use-inner"
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

### Incremental log reading
The `pipe-pane` log file captures everything. Read incrementally by tracking byte offset:

```bash
# Read new content since last check
offset=$(cat .cc-use/state/log-offset 2>/dev/null || echo 0)
tail -c +$((offset + 1)) .cc-use/logs/inner-output.log | tail -200
wc -c < .cc-use/logs/inner-output.log > .cc-use/state/log-offset
```

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
| `> ` at end of output | Idle — waiting for user input |
| `⏺` or tool names appearing | Running — executing tools |
| `Permission needed` or `Allow?` | Blocked — waiting for permission |
| `Cost:` line visible | Just finished a round |
| No change between captures | Idle or stuck |

## Advanced: Multiple Sessions

If managing multiple inner Claudes (future multi-task support):
```bash
# Create named sessions
tmux new-session -d -s "cc-use-task-1" -c "/path/to/project" -x 220 -y 50
tmux new-session -d -s "cc-use-task-2" -c "/path/to/project" -x 220 -y 50

# List all cc-use sessions
tmux list-sessions -F "#{session_name}" | grep "^cc-use-"
```
