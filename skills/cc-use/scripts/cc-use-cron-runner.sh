#!/usr/bin/env bash
# Cron runner — called by launchd (macOS) or cron (Linux)
# Usage: cc-use-cron-runner.sh <schedule_id>
#
# Runs claude -p with the configured prompt in the project directory.
# This script is NOT meant to be called by users directly.

set -uo pipefail

SCHEDULE_ID="${1:?Usage: cc-use-cron-runner.sh <schedule_id>}"

# ─── Bootstrap ───────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "$SCRIPT_DIR/cc-use-schedule.sh"

# ─── Launchd Environment Fix ─────────────────────────────────────────
# launchd has minimal env — set HOME explicitly and unset Claude Code
# env vars to avoid SSE port conflicts in unattended mode.

export HOME="${HOME:-/Users/$(whoami)}"
unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SSE_PORT

# ─── Load Config ─────────────────────────────────────────────────────

_cc_use_schedule_init

entry=$(_cc_use_schedule_get "$SCHEDULE_ID")
if [ -z "$entry" ]; then
  echo "[ERROR] Schedule not found: $SCHEDULE_ID"
  exit 1
fi

name=$(echo "$entry" | jq -r '.name')
project_dir=$(echo "$entry" | jq -r '.project_dir')
prompt=$(echo "$entry" | jq -r '.prompt')
claude_flags=$(echo "$entry" | jq -r '.claude_flags // "-p"')
notify_enabled=$(echo "$entry" | jq -r '.notify // false')
claude_path=$(echo "$entry" | jq -r '.claude_path // "claude"')
env_path=$(echo "$entry" | jq -r '.env_path // empty')

# Restore PATH for launchd environment
if [ -n "$env_path" ]; then
  export PATH="$env_path"
fi

# ─── Logging ─────────────────────────────────────────────────────────

LOG_FILE="${_CC_USE_LOGS}/cron-${SCHEDULE_ID}.log"
_cc_use_log_rotate "$LOG_FILE"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# ─── Execute ─────────────────────────────────────────────────────────

log "=== Cron job start: $name ==="
log "Project: $project_dir"
log "Prompt: ${prompt:0:200}"

start_time=$(date +%s)

# Run claude in the project directory
cd "$project_dir" || {
  log "ERROR: cannot cd to $project_dir"
  if [ "$notify_enabled" = "true" ]; then
    _cc_use_notify "Cron Error" "Job '$name' failed: cannot cd to $project_dir"
  fi
  exit 1
}

# Execute claude with the prompt
# Redirect stdin from /dev/null to avoid "no stdin data" warning
output=$("$claude_path" $claude_flags "$prompt" --output-format text < /dev/null 2>&1)
exit_code=$?

duration=$(( $(date +%s) - start_time ))

log "Exit code: $exit_code"
log "Duration: ${duration}s"
log "Output:"
log "$output"

# ─── Notify on failure ──────────────────────────────────────────────

if [ "$exit_code" -ne 0 ] && [ "$notify_enabled" = "true" ]; then
  _cc_use_notify "Cron Failed" "Job '$name' exited with code $exit_code (${duration}s)"
fi

log "=== Cron job end (${duration}s, exit $exit_code) ==="
