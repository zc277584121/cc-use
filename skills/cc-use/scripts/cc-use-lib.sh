#!/usr/bin/env bash
# cc-use helper functions for managing inner Claude via tmux
# Source this file: source <path>/cc-use-lib.sh

# --- Session Management ---

cc_use_launch() {
  # Launch inner Claude in a new tmux session
  # Usage: cc_use_launch <session_name> <project_dir> <state_dir> [permission_flags]
  local session="$1"
  local project_dir="$2"
  local state_dir="$3"
  local perm_flags="${4:-}"

  # Kill existing session if any
  tmux kill-session -t "$session" 2>/dev/null

  # Create session with fixed dimensions
  tmux new-session -d -s "$session" -c "$project_dir" -x 220 -y 50
  tmux set-option -t "$session" history-limit 50000

  # Clear screen snapshot state
  rm -f "$state_dir/last-screen.txt"

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
  # Usage: cc_use_restart <session_name> [permission_flags]
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
  # Quick glance at inner Claude's current screen (from bottom)
  # Usage: cc_use_glance <session_name> [lines]
  local session="$1"
  local lines="${2:-40}"

  tmux capture-pane -t "$session" -p -S "-$lines"
}

cc_use_scroll() {
  # Page through tmux scrollback like scrolling up in a terminal.
  # Each call returns a non-overlapping page of output.
  #
  # Usage: cc_use_scroll <session_name> <page> [page_size]
  # page=0: bottom (most recent), page=1: one page up, page=2: two pages up, ...
  # Default page_size: 30 lines
  #
  # Example — read bottom 3 pages without overlap:
  #   cc_use_scroll "$session" 0    # lines -30 to 0   (most recent)
  #   cc_use_scroll "$session" 1    # lines -60 to -31
  #   cc_use_scroll "$session" 2    # lines -90 to -61
  local session="$1"
  local page="${2:-0}"
  local page_size="${3:-30}"

  local end_offset=$(( page * page_size ))
  local start_offset=$(( end_offset + page_size ))

  # -S = start line (negative = from bottom), -E = end line
  # For page 0: -S -30 -E -1  (last 30 lines, excluding prompt line)
  # For page 1: -S -60 -E -31
  if [ "$end_offset" -eq 0 ]; then
    tmux capture-pane -t "$session" -p -S "-$start_offset"
  else
    tmux capture-pane -t "$session" -p -S "-$start_offset" -E "-$((end_offset + 1))"
  fi
}

cc_use_read_conversation() {
  # Read inner Claude's conversation from its JSONL transcript (Tier 3).
  # Finds the most recent transcript for the given project dir and extracts
  # the last N assistant messages as clean text.
  #
  # Usage: cc_use_read_conversation <project_dir> [last_n_messages]
  # Default: last 1 message
  local project_dir="$1"
  local last_n="${2:-1}"

  # Claude Code stores transcripts in ~/.claude/projects/<mangled-path>/
  # The path is the project dir with / replaced by -
  local mangled
  mangled=$(echo "$project_dir" | sed 's|^/||; s|/|-|g')
  local transcript_dir="$HOME/.claude/projects/$mangled"

  if [ ! -d "$transcript_dir" ]; then
    echo "No transcript directory found at $transcript_dir"
    return 1
  fi

  # Find the most recently modified .jsonl file
  local latest
  latest=$(ls -t "$transcript_dir"/*.jsonl 2>/dev/null | head -1)

  if [ -z "$latest" ]; then
    echo "No transcript files found"
    return 1
  fi

  echo "=== Transcript: $(basename "$latest") ==="
  # Extract assistant text messages, get last N
  jq -r '
    select(.type == "assistant")
    | .message.content[]
    | select(.type == "text")
    | .text
  ' "$latest" 2>/dev/null | tail -n "$last_n"
}

# --- Screen-Diff Based Monitoring ---

cc_use_watch() {
  # Monitor inner Claude via screen snapshot diffs.
  # Blocks until screen is stable (no changes for quiet_count consecutive checks).
  # Outputs only incremental changes (≤ threshold lines) to minimize context usage.
  # Large changes (> threshold) are silently absorbed — inner Claude is clearly busy.
  #
  # Usage: cc_use_watch <session_name> <state_dir> [interval] [quiet_count] [max_iter] [diff_threshold]
  # Defaults: interval=10s, quiet_count=2, max_iter=60 (=10min), diff_threshold=5
  local session="$1"
  local state_dir="$2"
  local interval="${3:-10}"
  local quiet_count="${4:-2}"
  local max_iter="${5:-60}"
  local diff_threshold="${6:-5}"

  local screen_file="$state_dir/last-screen.txt"
  local curr_file
  curr_file=$(mktemp)
  trap "rm -f '$curr_file'" RETURN

  local consecutive_same=0

  for i in $(seq 1 "$max_iter"); do
    # Capture current screen
    tmux capture-pane -t "$session" -p -S -40 > "$curr_file" 2>/dev/null

    if [ ! -f "$screen_file" ]; then
      # First check — save baseline, no output
      cp "$curr_file" "$screen_file"
      sleep "$interval"
      continue
    fi

    # Compare with previous screen
    local new_lines
    new_lines=$(diff "$screen_file" "$curr_file" 2>/dev/null | grep '^>' | sed 's/^> //')
    local new_count=0
    if [ -n "$new_lines" ]; then
      new_count=$(printf '%s\n' "$new_lines" | wc -l)
      new_count=$((new_count + 0))  # ensure integer
    fi

    if [ "$new_count" -eq 0 ]; then
      # No change
      consecutive_same=$((consecutive_same + 1))
      if [ "$consecutive_same" -ge "$quiet_count" ]; then
        echo "QUIET after $((i * interval))s"
        # Output final status (Tier 0: last 3 lines)
        tmux capture-pane -t "$session" -p -S -3
        return 0
      fi
    elif [ "$new_count" -le "$diff_threshold" ]; then
      # Small change — output the diff for outer Claude
      consecutive_same=0
      echo "$new_lines"
      cp "$curr_file" "$screen_file"
    else
      # Large change (>threshold lines) — inner is busy, stay silent
      consecutive_same=0
      cp "$curr_file" "$screen_file"
    fi

    sleep "$interval"
  done

  echo "TIMEOUT after $((max_iter * interval))s"
  tmux capture-pane -t "$session" -p -S -3
  return 1
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
