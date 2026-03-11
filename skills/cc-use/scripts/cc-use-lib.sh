#!/usr/bin/env bash
# cc-use helper functions for managing inner Claude via tmux
# Source this file: source <path>/cc-use-lib.sh
#
# NOTE on tmux capture-pane coordinates:
#   -S/-E use tmux's line numbering where 0 = first visible line,
#   and NEGATIVE numbers go INTO scrollback (above visible area).
#   So "-S -3" does NOT mean "last 3 lines" — it means "3 lines of
#   scrollback + entire visible area". To get the last N lines,
#   always use: tmux capture-pane -p | tail -N

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

  # Auto-confirm "trust this folder" dialog if it appears
  sleep 5
  local screen
  screen=$(tmux capture-pane -t "$session" -p 2>/dev/null)
  if echo "$screen" | grep -q "Yes, I trust this folder"; then
    tmux send-keys -t "$session" Enter
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

  # Flatten newlines to single line
  local flat
  flat=$(echo "$prompt" | tr '\n' ' ')

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

  local flat
  flat=$(cat "$file" | tr '\n' ' ')
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
  # Quick glance at inner Claude's current screen (last N lines, TUI noise filtered)
  # Usage: cc_use_glance <session_name> [lines]
  local session="$1"
  local lines="${2:-40}"

  tmux capture-pane -t "$session" -p 2>/dev/null | grep -vE "$_cc_use_filter" | tail -"$lines"
}

cc_use_scroll() {
  # Page through tmux output like scrolling up in a terminal.
  # Each call returns a non-overlapping page of output from scrollback + visible area.
  #
  # Usage: cc_use_scroll <session_name> <page> [page_size]
  # page=0: bottom (most recent), page=1: one page up, page=2: two pages up, ...
  # Default page_size: 30 lines
  #
  # Example — read bottom 3 pages without overlap:
  #   cc_use_scroll "$session" 0    # most recent 30 lines
  #   cc_use_scroll "$session" 1    # previous 30 lines (no overlap)
  #   cc_use_scroll "$session" 2    # even further back
  local session="$1"
  local page="${2:-0}"
  local page_size="${3:-30}"

  local skip_from_end=$(( page * page_size ))

  # -S - : capture from start of scrollback history
  # -E - : capture to end of visible area
  # This gives us the FULL output (scrollback + visible), then we paginate with tail+head
  local total_from_end=$(( skip_from_end + page_size ))

  if [ "$skip_from_end" -eq 0 ]; then
    tmux capture-pane -t "$session" -p -S - 2>/dev/null | tail -"$page_size"
  else
    tmux capture-pane -t "$session" -p -S - 2>/dev/null | tail -"$total_from_end" | head -"$page_size"
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
  mangled=$(echo "$project_dir" | sed 's|[/_]|-|g')
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
  # Extract last N complete assistant messages (all text blocks joined per message)
  # Uses jq slurp to treat each JSONL line as a message, then pick last N
  jq -rs '
    [.[] | select(.type == "assistant")
     | .message.content
     | map(select(.type == "text") | .text)
     | if length > 0 then join("\n") else empty end
    ] | .[-'"$last_n"':][] | "--- MESSAGE ---\n" + .
  ' "$latest" 2>/dev/null
}

cc_use_read_tools() {
  # Read what tools the inner Claude called in its last N messages.
  # Useful for understanding what inner Claude did without reading full output.
  #
  # Usage: cc_use_read_tools <project_dir> [last_n_messages]
  # Default: last 5 messages
  local project_dir="$1"
  local last_n="${2:-5}"

  local mangled
  mangled=$(echo "$project_dir" | sed 's|[/_]|-|g')
  local transcript_dir="$HOME/.claude/projects/$mangled"

  local latest
  latest=$(ls -t "$transcript_dir"/*.jsonl 2>/dev/null | head -1)

  if [ -z "$latest" ]; then
    echo "No transcript files found"
    return 1
  fi

  # Extract tool calls with their names and a snippet of input
  jq -rs '
    [.[] | select(.type == "assistant")
     | { tools: [.message.content[] | select(.type == "tool_use") | .name],
         text: ([.message.content[] | select(.type == "text") | .text] | join(" ") | .[:80]) }
     | if (.tools | length) > 0 or (.text | length) > 0 then . else empty end
    ] | .[-'"$last_n"':][]
    | (if (.tools | length) > 0 then "Tools: " + (.tools | join(", ")) else "" end)
      + (if (.text | length) > 0 then "\nText: " + .text else "" end)
  ' "$latest" 2>/dev/null
}

# --- TUI Filtering ---

# Filter patterns for Claude Code TUI noise:
# - Horizontal lines (─━)
# - Empty/whitespace lines
# - ⏵⏵ bypass permissions prompt
# - Spinner lines: various unicode symbols followed by text with … (e.g. "· Moonwalking… (3s)")
# - Timer lines: "✻ Verbed for Xm Ys" (Claude uses random verbs: Cooked, Churned, Bloviating, etc.)
# - Status bar: "? for shortcuts", ❯ prompt
_cc_use_filter='[─━]{3,}|^[[:space:]]*$|⏵⏵|^\s*$|^[·✢✶\*☐☑⏳⚡★✦●◆▶▸►⏵※†‡✻] .*…|\? for shortcuts|^[✻✶✢] [A-Z][a-z]+ for [0-9]|^❯'

_cc_use_tier0() {
  # Output Tier 0: find last ● in screen, return from there (filtered)
  # Usage: _cc_use_tier0 <screen_file>
  local file="$1"
  local last_line
  last_line=$(grep -n '^●' "$file" | tail -1 | cut -d: -f1)
  if [ -n "$last_line" ]; then
    tail -n +"$last_line" "$file" | grep -vE "$_cc_use_filter" | head -12
  else
    # No ● found, fall back to last 15 lines
    tail -15 "$file" | grep -vE "$_cc_use_filter" | head -8
  fi
}

# --- Screen-Diff Based Monitoring ---

cc_use_watch() {
  # Monitor inner Claude via screen snapshot diffs.
  # Blocks until inner Claude is idle (❯ prompt) with stable screen.
  # Outputs only incremental changes (≤ threshold lines) to minimize context usage.
  # Large changes (> threshold) are silently absorbed — inner Claude is clearly busy.
  #
  # Usage: cc_use_watch <session_name> <state_dir> [interval] [quiet_count] [max_iter] [diff_threshold]
  # Defaults: interval=10s, quiet_count=3, max_iter=60 (=10min), diff_threshold=5
  local session="$1"
  local state_dir="$2"
  local interval="${3:-10}"
  local quiet_count="${4:-3}"
  local max_iter="${5:-60}"
  local diff_threshold="${6:-5}"

  local screen_file="$state_dir/last-screen.txt"
  local curr_file
  curr_file=$(mktemp)
  trap "rm -f '$curr_file'" RETURN

  local consecutive_same=0

  for i in $(seq 1 "$max_iter"); do
    # Capture current visible screen (full pane)
    tmux capture-pane -t "$session" -p > "$curr_file" 2>/dev/null

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
      # No change — check if truly idle (❯ prompt visible)
      if grep -qE '^❯' "$curr_file"; then
        consecutive_same=$((consecutive_same + 1))
        if [ "$consecutive_same" -ge "$quiet_count" ]; then
          echo "IDLE after $((i * interval))s"
          # Output Tier 0: find last ● block, filtered
          _cc_use_tier0 "$curr_file"
          cp "$curr_file" "$screen_file"
          return 0
        fi
      else
        # Screen unchanged but no ❯ — might be thinking or stuck
        consecutive_same=$((consecutive_same + 1))
        if [ "$consecutive_same" -ge $((quiet_count * 2)) ]; then
          # Extended quiet without ❯ — probably stuck
          echo "STUCK after $((i * interval))s (no ❯ prompt)"
          _cc_use_tier0 "$curr_file"
          cp "$curr_file" "$screen_file"
          return 2
        fi
      fi
    elif [ "$new_count" -le "$diff_threshold" ]; then
      # Small change — filter TUI noise, output meaningful diff only
      consecutive_same=0
      local filtered
      filtered=$(printf '%s\n' "$new_lines" | grep -vE "$_cc_use_filter")
      if [ -n "$filtered" ]; then
        echo "$filtered"
      fi
      cp "$curr_file" "$screen_file"
    else
      # Large change (>threshold lines) — inner is busy, stay silent
      consecutive_same=0
      cp "$curr_file" "$screen_file"
    fi

    sleep "$interval"
  done

  echo "TIMEOUT after $((max_iter * interval))s"
  _cc_use_tier0 "$curr_file"
  cp "$curr_file" "$screen_file"
  return 1
}

# --- State Detection ---

cc_use_is_idle() {
  # Check if inner Claude is idle (showing ❯ prompt)
  # Usage: cc_use_is_idle <session_name> && echo "idle" || echo "busy"
  local session="$1"
  local output
  output=$(tmux capture-pane -t "$session" -p 2>/dev/null)
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
  # Wait for inner Claude to become idle (screen stable + ❯ visible)
  # Requires consecutive stable checks to avoid false detection after prompt send.
  #
  # Usage: cc_use_wait_idle <session_name> [max_iterations] [interval_seconds]
  # Default: 120 iterations × 5s = 10 minutes
  local session="$1"
  local max="${2:-120}"
  local interval="${3:-5}"
  local consecutive=0
  local prev_screen=""

  for i in $(seq 1 "$max"); do
    local curr_screen
    curr_screen=$(tmux capture-pane -t "$session" -p 2>/dev/null)

    if echo "$curr_screen" | grep -qE '^❯'; then
      # ❯ visible — check if screen is stable (same as previous capture)
      if [ "$curr_screen" = "$prev_screen" ]; then
        consecutive=$((consecutive + 1))
        if [ "$consecutive" -ge 2 ]; then
          echo "IDLE after $((i * interval))s"
          return 0
        fi
      else
        consecutive=0
      fi
    else
      consecutive=0
    fi

    prev_screen="$curr_screen"
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
    output=$(tmux capture-pane -t "$session" -p 2>/dev/null | tail -5)
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
