#!/usr/bin/env bash
# Heartbeat runner — called by launchd (macOS) or cron (Linux)
# Usage: cc-use-heartbeat-runner.sh <schedule_id>
#
# This script is NOT meant to be called by users directly.
# It is registered as the program for a launchd/cron schedule.

set -uo pipefail

SCHEDULE_ID="${1:?Usage: cc-use-heartbeat-runner.sh <schedule_id>}"

# ─── Bootstrap ───────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "$SCRIPT_DIR/cc-use-lib.sh"
source "$SCRIPT_DIR/cc-use-schedule.sh"

# ─── Launchd Environment Fix ─────────────────────────────────────────
# launchd has minimal env — set HOME explicitly, restore PATH from config,
# and unset Claude Code env vars to avoid SSE port conflicts.
# (Learned from daily-nurturing.sh pattern)

export HOME="${HOME:-/Users/$(whoami)}"
unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SSE_PORT

# ─── Load Config ─────────────────────────────────────────────────────

_cc_use_schedule_init

entry=$(_cc_use_schedule_get "$SCHEDULE_ID")
if [ -z "$entry" ]; then
  echo "[ERROR] Schedule not found: $SCHEDULE_ID"
  exit 1
fi

session_name=$(echo "$entry" | jq -r '.session_name')
project_dir=$(echo "$entry" | jq -r '.project_dir')
heartbeat_file=$(echo "$entry" | jq -r '.heartbeat_file')
perm_flags=$(echo "$entry" | jq -r '.perm_flags // empty')
auto_restart=$(echo "$entry" | jq -r '.auto_restart // false')
notify_enabled=$(echo "$entry" | jq -r '.notify // false')
claude_path=$(echo "$entry" | jq -r '.claude_path // "claude"')
env_path=$(echo "$entry" | jq -r '.env_path // empty')

# Restore PATH for launchd environment
if [ -n "$env_path" ]; then
  export PATH="$env_path"
fi

# ─── Logging ─────────────────────────────────────────────────────────

LOG_FILE="${_CC_USE_LOGS}/heartbeat-${SCHEDULE_ID}.log"
_cc_use_log_rotate "$LOG_FILE"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# ─── Locking (prevent concurrent runs) ──────────────────────────────

LOCK_FILE="${_CC_USE_DIR}/.lock-${SCHEDULE_ID}"

# Use flock if available, otherwise simple pid-based lock
if command -v flock > /dev/null 2>&1; then
  exec 200>"$LOCK_FILE"
  if ! flock -n 200; then
    log "SKIP: another heartbeat instance is running"
    exit 0
  fi
else
  if [ -f "$LOCK_FILE" ]; then
    old_pid=$(cat "$LOCK_FILE" 2>/dev/null)
    if kill -0 "$old_pid" 2>/dev/null; then
      log "SKIP: another heartbeat instance is running (pid $old_pid)"
      exit 0
    fi
  fi
  echo $$ > "$LOCK_FILE"
  trap 'rm -f "$LOCK_FILE"' EXIT
fi

# ─── State File ──────────────────────────────────────────────────────

state_file=$(_cc_use_heartbeat_state_file "$project_dir")
_cc_use_heartbeat_state_init "$state_file"

start_time=$(date +%s)

log "=== Heartbeat start ==="
log "Session: $session_name | Project: $project_dir"

# ─── Step 1: Check session alive ────────────────────────────────────

if ! cc_use_is_alive "$session_name"; then
  if [ "$auto_restart" = "true" ]; then
    log "Session dead, attempting restart..."

    # Ensure project .cc-use state dir exists
    mkdir -p "${project_dir}/.cc-use/state"

    cc_use_launch "$session_name" "$project_dir" "${project_dir}/.cc-use/state" "$perm_flags"

    # Wait for startup — use full watch (not wait_idle) with generous timeout
    # Claude needs time to render welcome screen and fully stabilize
    if cc_use_wait_idle "$session_name" 60; then
      # Extra settle time: wait_idle returns when ❯ first appears,
      # but Claude TUI may still be rendering the welcome screen
      sleep 5
      log "Session restarted successfully"
    else
      duration=$(( $(date +%s) - start_time ))
      log "ERROR: Session restart failed, could not reach idle state"
      _cc_use_heartbeat_state_update "$state_file" "error" "$duration" "session restart failed"
      if [ "$notify_enabled" = "true" ]; then
        _cc_use_notify "Heartbeat Error" "Session '$session_name' restart failed in $project_dir"
      fi
      log "=== Heartbeat end (error) ==="
      exit 1
    fi
  else
    duration=$(( $(date +%s) - start_time ))
    log "Session dead, auto_restart disabled, skipping"
    _cc_use_heartbeat_state_update "$state_file" "error" "$duration" "session dead, auto_restart disabled"
    log "=== Heartbeat end (error) ==="
    exit 1
  fi
fi

# ─── Step 2: Check idle ─────────────────────────────────────────────

if ! cc_use_is_idle "$session_name"; then
  duration=$(( $(date +%s) - start_time ))
  log "Claude is busy, skipping heartbeat"
  _cc_use_heartbeat_state_update "$state_file" "skipped" "$duration" "busy"
  log "=== Heartbeat end (skipped) ==="
  exit 0
fi

# ─── Step 3: Check heartbeat file ───────────────────────────────────

if [ ! -f "$heartbeat_file" ]; then
  duration=$(( $(date +%s) - start_time ))
  log "ERROR: heartbeat file not found: $heartbeat_file"
  _cc_use_heartbeat_state_update "$state_file" "error" "$duration" "heartbeat.md not found"
  log "=== Heartbeat end (error) ==="
  exit 1
fi

# Skip if heartbeat.md is effectively empty (only whitespace, headers, empty checkboxes)
content=$(grep -vE '^[[:space:]]*$|^#|^- \[ \]' "$heartbeat_file" 2>/dev/null || true)
if [ -z "$content" ]; then
  duration=$(( $(date +%s) - start_time ))
  log "Heartbeat file is empty/template-only, skipping"
  _cc_use_heartbeat_state_update "$state_file" "skipped" "$duration" "empty heartbeat.md"
  log "=== Heartbeat end (skipped) ==="
  exit 0
fi

# ─── Step 4: Send heartbeat ─────────────────────────────────────────

log "Sending heartbeat checklist..."
cc_use_send_file "$session_name" "$heartbeat_file"

# ─── Step 5: Wait for response ──────────────────────────────────────

# Wait for claude to START processing (❯ disappears / spinner appears).
# Without this, watch may see the stale ❯ from before the send and declare idle
# before claude even begins.
for _wait_busy in $(seq 1 30); do
  if ! cc_use_is_idle "$session_name"; then
    log "Claude started processing (after ${_wait_busy}s)"
    break
  fi
  sleep 1
done

# Now watch until claude finishes (❯ reappears after processing)
# 10s interval, 3 quiet checks, max 120 iterations (20min timeout)
cc_use_watch "$session_name" "" 10 3 120 >> "$LOG_FILE" 2>&1
watch_exit=$?

# ─── Step 6: Read response ──────────────────────────────────────────

# Prefer read_conversation (extracts actual Claude reply from JSONL transcript)
# over glance (which captures the entire tmux screen including startup banners).
response=$(cc_use_read_conversation "$project_dir" 1 2>/dev/null | grep -v '^=== Transcript' | grep -v '^--- MESSAGE')
if [ -z "$response" ]; then
  # Fallback to glance if transcript not available
  response=$(cc_use_glance "$session_name" 15)
fi
duration=$(( $(date +%s) - start_time ))

log "Response (${duration}s):"
log "$response"

# ─── Step 7: Evaluate result ────────────────────────────────────────

if echo "$response" | grep -qi "HEARTBEAT_OK"; then
  log "Result: HEARTBEAT_OK — all clear"
  _cc_use_heartbeat_state_update "$state_file" "ok" "$duration"
elif [ "$watch_exit" -eq 1 ]; then
  log "Result: TIMEOUT — claude did not respond in time"
  _cc_use_heartbeat_state_update "$state_file" "error" "$duration" "timeout"
  if [ "$notify_enabled" = "true" ]; then
    _cc_use_notify "Heartbeat Timeout" "No response in ${duration}s from $project_dir"
  fi
elif [ "$watch_exit" -eq 2 ]; then
  log "Result: STUCK — claude appears stuck"
  _cc_use_heartbeat_state_update "$state_file" "error" "$duration" "stuck"
  if [ "$notify_enabled" = "true" ]; then
    _cc_use_notify "Heartbeat Stuck" "Claude appears stuck in $project_dir"
  fi
else
  # Substantive response — something needs attention
  # Extract a short summary (first non-empty, non-header line)
  summary=$(echo "$response" | grep -vE '^[[:space:]]*$|^#|HEARTBEAT_OK' | head -3 | tr '\n' ' ' | head -c 200)
  log "Result: ALERT — needs attention"
  _cc_use_heartbeat_state_update "$state_file" "alert" "$duration" "$summary"

  if [ "$notify_enabled" = "true" ]; then
    _cc_use_notify "Heartbeat Alert" "$summary"
  fi
fi

log "=== Heartbeat end (${duration}s) ==="
