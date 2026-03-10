#!/usr/bin/env bash
# cc-use helper functions for managing inner Claude via tmux
# Source this file: source <path>/cc-use-lib.sh

# --- Session Management ---

cc_use_launch() {
  # Launch inner Claude in a new tmux session
  # Usage: cc_use_launch <session_name> <project_dir> <log_file> <permission_flags>
  local session="$1"
  local project_dir="$2"
  local log_file="$3"
  local perm_flags="${4:-}"

  # Kill existing session if any
  tmux kill-session -t "$session" 2>/dev/null

  # Create session with fixed dimensions
  tmux new-session -d -s "$session" -c "$project_dir" -x 220 -y 50
  tmux set-option -t "$session" history-limit 50000

  # Start logging
  : > "$log_file"
  tmux pipe-pane -t "$session" -o "cat >> $log_file"

  # Launch claude
  if [ -n "$perm_flags" ]; then
    tmux send-keys -t "$session" "claude $perm_flags" Enter
  else
    tmux send-keys -t "$session" "claude" Enter
  fi

  echo "Launched in tmux session '$session'"
}

cc_use_stop() {
  # Gracefully stop inner Claude and kill session
  # Usage: cc_use_stop <session_name>
  local session="$1"

  tmux send-keys -t "$session" "/exit" Enter 2>/dev/null
  cc_use_wait_shell "$session" 15
  tmux kill-session -t "$session" 2>/dev/null
  echo "Session '$session' stopped"
}

cc_use_restart() {
  # Restart inner Claude (for config changes that need restart)
  # Usage: cc_use_restart <session_name> <permission_flags>
  local session="$1"
  local perm_flags="${2:-}"

  tmux send-keys -t "$session" "/exit" Enter
  cc_use_wait_shell "$session" 15

  # Restore window size (may have changed if user attached)
  tmux resize-window -t "$session" -x 220 -y 50 2>/dev/null

  if [ -n "$perm_flags" ]; then
    tmux send-keys -t "$session" "claude $perm_flags" Enter
  else
    tmux send-keys -t "$session" "claude" Enter
  fi

  cc_use_wait_idle "$session" 30
  echo "Restarted"
}

# --- Sending Input ---

cc_use_send() {
  # Send a prompt to inner Claude (handles long text reliably)
  # Usage: cc_use_send <session_name> <prompt_text>
  local session="$1"
  local prompt="$2"

  # Flatten newlines and add prefix
  local flat="[CC-USE] $(echo "$prompt" | tr '\n' ' ')"

  # Two-step send: text first, then Enter
  tmux send-keys -t "$session" "$flat"
  sleep 1
  tmux send-keys -t "$session" Enter
}

cc_use_send_file() {
  # Send a prompt from a file to inner Claude
  # Usage: cc_use_send_file <session_name> <prompt_file>
  local session="$1"
  local file="$2"

  local flat="[CC-USE] $(cat "$file" | tr '\n' ' ')"
  tmux send-keys -t "$session" "$flat"
  sleep 1
  tmux send-keys -t "$session" Enter
}

cc_use_cmd() {
  # Send a slash command to inner Claude (short, no prefix needed)
  # Usage: cc_use_cmd <session_name> <command>
  # Example: cc_use_cmd my-session "/compact focus on auth"
  local session="$1"
  local cmd="$2"

  tmux send-keys -t "$session" "$cmd" Enter
}

# --- Reading Output ---

cc_use_glance() {
  # Quick glance at inner Claude's current screen (~40 lines)
  # Usage: cc_use_glance <session_name> [lines]
  local session="$1"
  local lines="${2:-40}"

  tmux capture-pane -t "$session" -p -S "-$lines"
}

cc_use_read_incremental() {
  # Read only NEW output since last check (via byte offset tracking)
  # Usage: cc_use_read_incremental <log_file> <offset_file> [max_lines]
  local log_file="$1"
  local offset_file="$2"
  local max_lines="${3:-200}"

  local offset=0
  if [ -f "$offset_file" ]; then
    offset=$(cat "$offset_file")
  fi

  tail -c +$((offset + 1)) "$log_file" | tail -"$max_lines"
  wc -c < "$log_file" > "$offset_file"
}

# --- State Detection ---

cc_use_is_idle() {
  # Check if inner Claude is idle (showing ❯ prompt)
  # Usage: cc_use_is_idle <session_name> && echo "idle" || echo "busy"
  local session="$1"
  local output
  output=$(tmux capture-pane -t "$session" -p -S -5 2>/dev/null)
  echo "$output" | grep -qE '^❯'
}

cc_use_is_alive() {
  # Check if the tmux session exists
  # Usage: cc_use_is_alive <session_name> && echo "alive" || echo "dead"
  local session="$1"
  tmux has-session -t "$session" 2>/dev/null
}

# --- Waiting ---

cc_use_wait_idle() {
  # Wait for inner Claude to become idle (silent, minimal context usage)
  # Usage: cc_use_wait_idle <session_name> [max_iterations] [interval_seconds]
  # Default: 120 iterations × 5s = 10 minutes
  local session="$1"
  local max="${2:-120}"
  local interval="${3:-5}"

  for i in $(seq 1 "$max"); do
    if cc_use_is_idle "$session"; then
      echo "IDLE after $((i * interval))s"
      return 0
    fi
    sleep "$interval"
  done
  echo "TIMEOUT after $((max * interval))s"
  return 1
}

cc_use_wait_shell() {
  # Wait for Claude to exit and shell prompt to return
  # Usage: cc_use_wait_shell <session_name> [max_iterations]
  local session="$1"
  local max="${2:-15}"

  for i in $(seq 1 "$max"); do
    local output
    output=$(tmux capture-pane -t "$session" -p -S -3 2>/dev/null)
    if echo "$output" | grep -qE '^\$|^\(base\)|^[a-z]+@'; then
      echo "Shell prompt returned after $((i * 2))s"
      return 0
    fi
    sleep 2
  done
  echo "TIMEOUT waiting for shell"
  return 1
}

# --- Window Management ---

cc_use_fix_size() {
  # Restore tmux window to standard size (call after user attaches/detaches)
  # Usage: cc_use_fix_size <session_name>
  local session="$1"
  tmux resize-window -t "$session" -x 220 -y 50 2>/dev/null
}
