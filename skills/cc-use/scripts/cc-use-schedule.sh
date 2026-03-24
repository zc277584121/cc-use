#!/usr/bin/env bash
# cc-use schedule management: heartbeat + cron
# Source this file alongside cc-use-lib.sh for schedule_* functions.
#
# Global config:  ~/.cc-use/config.json      (notifiers, etc.)
# Schedule DB:    ~/.cc-use/schedules.json    (all registered schedules)
# Logs:           ~/.cc-use/logs/             (per-schedule log files)
# Project state:  <project>/.cc-use/heartbeat.md, heartbeat-state.json

# ─── Constants ────────────────────────────────────────────────────────

_CC_USE_DIR="$HOME/.cc-use"
_CC_USE_SCHEDULES="$_CC_USE_DIR/schedules.json"
_CC_USE_CONFIG="$_CC_USE_DIR/config.json"
_CC_USE_LOGS="$_CC_USE_DIR/logs"
_CC_USE_PLIST_PREFIX="com.cc-use"

# ─── Init & Helpers ──────────────────────────────────────────────────

_cc_use_schedule_init() {
  mkdir -p "$_CC_USE_LOGS"
  if [ ! -f "$_CC_USE_SCHEDULES" ]; then
    echo '{"schedules":[]}' > "$_CC_USE_SCHEDULES"
  fi
}

_cc_use_detect_platform() {
  case "$(uname -s)" in
    Darwin) echo "macos" ;;
    Linux)  echo "linux" ;;
    *)      echo "unsupported" ;;
  esac
}

_cc_use_gen_id() {
  # Generate a short unique ID with prefix
  local prefix="$1"
  echo "${prefix}-$(date +%s | shasum | head -c 8)"
}

_cc_use_schedule_get() {
  # Get a schedule entry by ID, returns JSON object
  local id="$1"
  jq -e --arg id "$id" '.schedules[] | select(.id == $id)' "$_CC_USE_SCHEDULES" 2>/dev/null
}

_cc_use_schedule_update_field() {
  # Update a single field in a schedule entry
  local id="$1" field="$2" value="$3"
  local tmp
  tmp=$(mktemp)
  jq --arg id "$id" --arg f "$field" --arg v "$value" \
    '(.schedules[] | select(.id == $id))[$f] = $v' \
    "$_CC_USE_SCHEDULES" > "$tmp" && mv "$tmp" "$_CC_USE_SCHEDULES"
}

# ─── Log Rotation ────────────────────────────────────────────────────

_cc_use_log_rotate() {
  # Rotate log if > 1MB, keep 3 backups
  local log_file="$1"
  [ ! -f "$log_file" ] && return 0

  local size
  size=$(wc -c < "$log_file" 2>/dev/null | tr -d ' ')
  if [ "${size:-0}" -gt 1048576 ]; then
    [ -f "${log_file}.2" ] && rm -f "${log_file}.3"
    [ -f "${log_file}.2" ] && mv "${log_file}.2" "${log_file}.3"
    [ -f "${log_file}.1" ] && mv "${log_file}.1" "${log_file}.2"
    mv "$log_file" "${log_file}.1"
  fi
}

# ─── Notification Abstraction ────────────────────────────────────────

_cc_use_notify() {
  # Send notification via configured notifier
  # Usage: _cc_use_notify <title> <body> [notifier_name]
  local title="$1" body="$2" notifier_name="${3:-}"

  if [ ! -f "$_CC_USE_CONFIG" ]; then
    return 0
  fi

  # Resolve notifier: explicit name > schedule override > default
  local notifier_json
  if [ -n "$notifier_name" ]; then
    notifier_json=$(jq -e --arg n "$notifier_name" \
      '.notifiers[] | select(.name == $n)' "$_CC_USE_CONFIG" 2>/dev/null)
  else
    local default_name
    default_name=$(jq -r '.default_notifier // empty' "$_CC_USE_CONFIG" 2>/dev/null)
    if [ -n "$default_name" ]; then
      notifier_json=$(jq -e --arg n "$default_name" \
        '.notifiers[] | select(.name == $n)' "$_CC_USE_CONFIG" 2>/dev/null)
    fi
  fi

  if [ -z "$notifier_json" ]; then
    return 0
  fi

  local ntype webhook_url
  ntype=$(echo "$notifier_json" | jq -r '.type')
  webhook_url=$(echo "$notifier_json" | jq -r '.webhook_url // empty')

  # Dispatch to platform-specific function
  if declare -f "_cc_use_notify_${ntype}" > /dev/null 2>&1; then
    "_cc_use_notify_${ntype}" "$title" "$body" "$webhook_url"
  fi
}

_cc_use_notify_feishu() {
  local title="$1" body="$2" webhook_url="$3"
  curl -s -X POST "$webhook_url" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg t "[$title] $body" '{msg_type:"text",content:{text:$t}}')" \
    > /dev/null 2>&1
}

# Future notifiers:
# _cc_use_notify_slack() { ... }
# _cc_use_notify_discord() { ... }
# _cc_use_notify_telegram() { ... }

# ─── Platform Abstraction: macOS launchd ─────────────────────────────

_cc_use_plist_path() {
  local id="$1"
  echo "$HOME/Library/LaunchAgents/${_CC_USE_PLIST_PREFIX}.${id}.plist"
}

_cc_use_plist_create_heartbeat() {
  # Create and load a launchd plist for heartbeat (interval-based)
  local id="$1" interval_sec="$2" runner_path="$3" log_file="$4"
  local plist_path
  plist_path=$(_cc_use_plist_path "$id")
  local label="${_CC_USE_PLIST_PREFIX}.${id}"

  cat > "$plist_path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${runner_path}</string>
    <string>${id}</string>
  </array>
  <key>StartInterval</key>
  <integer>${interval_sec}</integer>
  <key>StandardOutPath</key>
  <string>${log_file}</string>
  <key>StandardErrorPath</key>
  <string>${log_file}</string>
  <key>RunAtLoad</key>
  <false/>
</dict>
</plist>
PLIST

  launchctl load "$plist_path" 2>/dev/null
  echo "Loaded launchd job: $label"
}

_cc_use_plist_create_cron() {
  # Create and load a launchd plist for cron (calendar-based)
  # Supports simple cron expressions: minute hour day month weekday
  # Handles ranges (1-5) by expanding to multiple StartCalendarInterval entries
  local id="$1" cron_expr="$2" runner_path="$3" log_file="$4"
  local plist_path
  plist_path=$(_cc_use_plist_path "$id")
  local label="${_CC_USE_PLIST_PREFIX}.${id}"

  # Parse cron expression (5 fields: min hour day month weekday)
  local min hour day month weekday
  read -r min hour day month weekday <<< "$cron_expr"

  # Helper: build a single <dict> with the given field values
  _build_cal_dict() {
    local m="$1" h="$2" d="$3" mo="$4" w="$5"
    echo "    <dict>"
    [ "$m" != "*" ]  && echo "      <key>Minute</key><integer>${m}</integer>"
    [ "$h" != "*" ]  && echo "      <key>Hour</key><integer>${h}</integer>"
    [ "$d" != "*" ]  && echo "      <key>Day</key><integer>${d}</integer>"
    [ "$mo" != "*" ] && echo "      <key>Month</key><integer>${mo}</integer>"
    [ "$w" != "*" ]  && echo "      <key>Weekday</key><integer>${w}</integer>"
    echo "    </dict>"
  }

  # Check if any field uses a range (e.g., 1-5) — expand into multiple dicts
  # For simplicity, only expand ranges on the weekday field (most common case)
  local cal_content=""
  if [[ "$weekday" =~ ^([0-9]+)-([0-9]+)$ ]]; then
    local w_start="${BASH_REMATCH[1]}" w_end="${BASH_REMATCH[2]}"
    cal_content="  <key>StartCalendarInterval</key>
  <array>"
    for w in $(seq "$w_start" "$w_end"); do
      cal_content="${cal_content}
$(_build_cal_dict "$min" "$hour" "$day" "$month" "$w")"
    done
    cal_content="${cal_content}
  </array>"
  else
    cal_content="  <key>StartCalendarInterval</key>
  <dict>"
    [ "$min" != "*" ]     && cal_content="${cal_content}
    <key>Minute</key><integer>${min}</integer>"
    [ "$hour" != "*" ]    && cal_content="${cal_content}
    <key>Hour</key><integer>${hour}</integer>"
    [ "$day" != "*" ]     && cal_content="${cal_content}
    <key>Day</key><integer>${day}</integer>"
    [ "$month" != "*" ]   && cal_content="${cal_content}
    <key>Month</key><integer>${month}</integer>"
    [ "$weekday" != "*" ] && cal_content="${cal_content}
    <key>Weekday</key><integer>${weekday}</integer>"
    cal_content="${cal_content}
  </dict>"
  fi

  cat > "$plist_path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${runner_path}</string>
    <string>${id}</string>
  </array>
${cal_content}
  <key>StandardOutPath</key>
  <string>${log_file}</string>
  <key>StandardErrorPath</key>
  <string>${log_file}</string>
</dict>
</plist>
PLIST

  launchctl load "$plist_path" 2>/dev/null
  echo "Loaded launchd job: $label"
}

_cc_use_plist_remove() {
  local id="$1"
  local plist_path
  plist_path=$(_cc_use_plist_path "$id")
  local label="${_CC_USE_PLIST_PREFIX}.${id}"

  if [ -f "$plist_path" ]; then
    launchctl unload "$plist_path" 2>/dev/null
    rm -f "$plist_path"
    echo "Removed launchd job: $label"
  fi
}

_cc_use_plist_status() {
  local id="$1"
  local label="${_CC_USE_PLIST_PREFIX}.${id}"
  launchctl list 2>/dev/null | grep "$label" || echo "not loaded"
}

# ─── Platform Abstraction: Linux crontab ─────────────────────────────

_cc_use_crontab_add() {
  # Add a crontab entry with a marker comment for identification
  local id="$1" cron_expr="$2" command="$3"
  local marker="#cc-use:${id}"

  # Remove existing entry for this ID first
  _cc_use_crontab_remove "$id" 2>/dev/null

  # Append new entry
  (crontab -l 2>/dev/null; echo "${cron_expr} ${command} ${marker}") | crontab -
  echo "Added crontab entry: $id"
}

_cc_use_crontab_remove() {
  local id="$1"
  local marker="#cc-use:${id}"

  crontab -l 2>/dev/null | grep -v "$marker" | crontab -
  echo "Removed crontab entry: $id"
}

_cc_use_crontab_status() {
  local id="$1"
  local marker="#cc-use:${id}"
  crontab -l 2>/dev/null | grep "$marker" || echo "not found"
}

# ─── Heartbeat State Management ──────────────────────────────────────

_cc_use_heartbeat_state_file() {
  local project_dir="$1"
  echo "${project_dir}/.cc-use/heartbeat-state.json"
}

_cc_use_heartbeat_state_init() {
  local state_file="$1"
  if [ ! -f "$state_file" ]; then
    cat > "$state_file" <<'JSON'
{
  "last_run": null,
  "last_result": null,
  "consecutive_ok": 0,
  "consecutive_errors": 0,
  "last_alert": null,
  "last_alert_time": null,
  "history": []
}
JSON
  fi
}

_cc_use_heartbeat_state_update() {
  # Update heartbeat state after a run
  # Usage: _cc_use_heartbeat_state_update <state_file> <result> <duration_sec> [summary]
  # result: ok | alert | skipped | error
  local state_file="$1" result="$2" duration="$3" summary="${4:-}"
  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  local tmp
  tmp=$(mktemp)

  # Build the history entry
  local entry
  if [ -n "$summary" ]; then
    entry=$(jq -n --arg t "$now" --arg r "$result" --argjson d "$duration" --arg s "$summary" \
      '{time:$t, result:$r, duration_sec:$d, summary:$s}')
  else
    entry=$(jq -n --arg t "$now" --arg r "$result" --argjson d "$duration" \
      '{time:$t, result:$r, duration_sec:$d}')
  fi

  jq --arg now "$now" --arg result "$result" --argjson entry "$entry" '
    .last_run = $now |
    .last_result = $result |
    if $result == "ok" then
      .consecutive_ok += 1 | .consecutive_errors = 0
    elif $result == "alert" then
      .consecutive_ok = 0 | .consecutive_errors = 0 |
      .last_alert = ($entry.summary // "alert") |
      .last_alert_time = $now
    elif $result == "error" then
      .consecutive_ok = 0 | .consecutive_errors += 1
    else . end |
    .history = ([$entry] + .history | .[0:20])
  ' "$state_file" > "$tmp" && mv "$tmp" "$state_file"
}

# ─── Schedule CRUD ───────────────────────────────────────────────────

cc_use_schedule_add() {
  # Add a new scheduled task
  # Usage: cc_use_schedule_add heartbeat <name> <project_dir> <interval_min> [session_name] [perm_flags]
  # Usage: cc_use_schedule_add cron <name> <project_dir> "<cron_expr>" "<prompt>" [claude_flags]
  local type="${1:?Usage: cc_use_schedule_add <heartbeat|cron> <name> <project_dir> ...}"
  shift

  _cc_use_schedule_init

  case "$type" in
    heartbeat) _cc_use_schedule_add_heartbeat "$@" ;;
    cron)      _cc_use_schedule_add_cron "$@" ;;
    *)         echo "Unknown type: $type (use 'heartbeat' or 'cron')" >&2; return 1 ;;
  esac
}

_cc_use_schedule_add_heartbeat() {
  local name="${1:?Usage: schedule_add heartbeat <name> <project_dir> <interval_min> [session] [perm_flags]}"
  local project_dir="${2:?Missing project_dir}"
  local interval_min="${3:?Missing interval_minutes}"
  local session_name="${4:-cc-use-${name}}"
  local perm_flags="${5:-}"

  local id
  id=$(_cc_use_gen_id "hb")
  local heartbeat_file="${project_dir}/.cc-use/heartbeat.md"
  local log_file="${_CC_USE_LOGS}/heartbeat-${id}.log"
  local interval_sec=$((interval_min * 60))
  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Record current environment for launchd
  local claude_path env_path
  claude_path=$(command -v claude 2>/dev/null || echo "claude")
  env_path="$PATH"

  # Find runner script path (sibling of this script)
  local runner_path
  runner_path="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/cc-use-heartbeat-runner.sh"

  # Ensure project .cc-use dir exists
  mkdir -p "${project_dir}/.cc-use"

  # Create default heartbeat.md if missing
  if [ ! -f "$heartbeat_file" ]; then
    cat > "$heartbeat_file" <<'MD'
# Heartbeat Checklist

Check the following items. If everything is normal and nothing needs attention,
respond with exactly: HEARTBEAT_OK

Otherwise, describe what needs attention.

- [ ] Check for any issues that need immediate attention
- [ ] Review recent changes or pending items
MD
    echo "Created default heartbeat.md at $heartbeat_file"
  fi

  # Initialize heartbeat state
  local state_file
  state_file=$(_cc_use_heartbeat_state_file "$project_dir")
  _cc_use_heartbeat_state_init "$state_file"

  # Add to schedules.json
  local tmp
  tmp=$(mktemp)
  jq --arg id "$id" --arg name "$name" --arg pdir "$project_dir" \
     --arg session "$session_name" --arg hfile "$heartbeat_file" \
     --argjson imin "$interval_min" --arg perm "$perm_flags" \
     --arg now "$now" --arg plabel "${_CC_USE_PLIST_PREFIX}.${id}" \
     --arg cpath "$claude_path" --arg epath "$env_path" \
     '.schedules += [{
       id: $id, type: "heartbeat", name: $name,
       project_dir: $pdir, session_name: $session,
       heartbeat_file: $hfile, interval_minutes: $imin,
       perm_flags: $perm, auto_restart: true, notify: true,
       enabled: true, created_at: $now, platform_id: $plabel,
       claude_path: $cpath, env_path: $epath
     }]' "$_CC_USE_SCHEDULES" > "$tmp" && mv "$tmp" "$_CC_USE_SCHEDULES"

  # Register with OS scheduler
  local platform
  platform=$(_cc_use_detect_platform)
  case "$platform" in
    macos)
      _cc_use_plist_create_heartbeat "$id" "$interval_sec" "$runner_path" "$log_file"
      ;;
    linux)
      # Convert minutes to cron: */N * * * *
      local cron_expr="*/${interval_min} * * * *"
      _cc_use_crontab_add "$id" "$cron_expr" "/bin/bash ${runner_path} ${id}"
      ;;
    *)
      echo "Warning: unsupported platform, schedule registered but no OS trigger created" >&2
      ;;
  esac

  echo "Added heartbeat schedule: $name ($id) every ${interval_min}m"
  echo "  Project:   $project_dir"
  echo "  Session:   $session_name"
  echo "  Heartbeat: $heartbeat_file"
  echo "  Log:       $log_file"
}

_cc_use_schedule_add_cron() {
  local name="${1:?Usage: schedule_add cron <name> <project_dir> <cron_expr> <prompt> [claude_flags]}"
  local project_dir="${2:?Missing project_dir}"
  local cron_expr="${3:?Missing cron_expression}"
  local prompt="${4:?Missing prompt}"
  local claude_flags="${5:--p}"

  local id
  id=$(_cc_use_gen_id "cr")
  local log_file="${_CC_USE_LOGS}/cron-${id}.log"
  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  local claude_path env_path
  claude_path=$(command -v claude 2>/dev/null || echo "claude")
  env_path="$PATH"

  local runner_path
  runner_path="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/cc-use-cron-runner.sh"

  # Add to schedules.json
  local tmp
  tmp=$(mktemp)
  jq --arg id "$id" --arg name "$name" --arg pdir "$project_dir" \
     --arg cron "$cron_expr" --arg prompt "$prompt" \
     --arg flags "$claude_flags" --arg now "$now" \
     --arg plabel "${_CC_USE_PLIST_PREFIX}.${id}" \
     --arg cpath "$claude_path" --arg epath "$env_path" \
     '.schedules += [{
       id: $id, type: "cron", name: $name,
       project_dir: $pdir, cron_expr: $cron,
       prompt: $prompt, claude_flags: $flags,
       notify: true, enabled: true, created_at: $now,
       platform_id: $plabel,
       claude_path: $cpath, env_path: $epath
     }]' "$_CC_USE_SCHEDULES" > "$tmp" && mv "$tmp" "$_CC_USE_SCHEDULES"

  # Register with OS scheduler
  local platform
  platform=$(_cc_use_detect_platform)
  case "$platform" in
    macos)
      _cc_use_plist_create_cron "$id" "$cron_expr" "$runner_path" "$log_file"
      ;;
    linux)
      _cc_use_crontab_add "$id" "$cron_expr" "/bin/bash ${runner_path} ${id}"
      ;;
    *)
      echo "Warning: unsupported platform, schedule registered but no OS trigger created" >&2
      ;;
  esac

  echo "Added cron schedule: $name ($id)"
  echo "  Project:  $project_dir"
  echo "  Schedule: $cron_expr"
  echo "  Prompt:   ${prompt:0:80}..."
  echo "  Log:      $log_file"
}

cc_use_schedule_list() {
  # List all registered schedules
  _cc_use_schedule_init

  local count
  count=$(jq '.schedules | length' "$_CC_USE_SCHEDULES")

  if [ "$count" -eq 0 ]; then
    echo "No schedules registered."
    return 0
  fi

  echo "ID            TYPE       NAME                     ENABLED  INTERVAL/SCHEDULE"
  echo "────────────  ─────────  ───────────────────────  ───────  ─────────────────"
  jq -r '.schedules[] |
    [ .id, .type,  .name,
      (if .enabled then "yes" else "no" end),
      (if .type == "heartbeat" then "every \(.interval_minutes)m" else .cron_expr end)
    ] | @tsv' "$_CC_USE_SCHEDULES" | column -t -s$'\t'
}

cc_use_schedule_remove() {
  # Remove a scheduled task by ID
  # Usage: cc_use_schedule_remove <id>
  local id="${1:?Usage: cc_use_schedule_remove <id>}"

  _cc_use_schedule_init

  # Check exists
  local entry
  entry=$(_cc_use_schedule_get "$id")
  if [ -z "$entry" ]; then
    echo "Schedule not found: $id" >&2
    return 1
  fi

  local name
  name=$(echo "$entry" | jq -r '.name')

  # Unregister from OS scheduler
  local platform
  platform=$(_cc_use_detect_platform)
  case "$platform" in
    macos) _cc_use_plist_remove "$id" ;;
    linux) _cc_use_crontab_remove "$id" ;;
  esac

  # Remove from schedules.json
  local tmp
  tmp=$(mktemp)
  jq --arg id "$id" '.schedules |= map(select(.id != $id))' \
    "$_CC_USE_SCHEDULES" > "$tmp" && mv "$tmp" "$_CC_USE_SCHEDULES"

  echo "Removed schedule: $name ($id)"
}

cc_use_schedule_status() {
  # Show detailed status of a schedule (or all if no ID given)
  # Usage: cc_use_schedule_status [id]
  local id="${1:-}"

  _cc_use_schedule_init

  if [ -z "$id" ]; then
    # Show summary for all
    cc_use_schedule_list
    echo ""

    # Show platform-level status
    local platform
    platform=$(_cc_use_detect_platform)
    echo "Platform status ($platform):"
    case "$platform" in
      macos) launchctl list 2>/dev/null | grep "$_CC_USE_PLIST_PREFIX" || echo "  (no active jobs)" ;;
      linux) crontab -l 2>/dev/null | grep "#cc-use:" || echo "  (no active jobs)" ;;
    esac
    return 0
  fi

  # Detailed status for one schedule
  local entry
  entry=$(_cc_use_schedule_get "$id")
  if [ -z "$entry" ]; then
    echo "Schedule not found: $id" >&2
    return 1
  fi

  local type name project_dir enabled
  type=$(echo "$entry" | jq -r '.type')
  name=$(echo "$entry" | jq -r '.name')
  project_dir=$(echo "$entry" | jq -r '.project_dir')
  enabled=$(echo "$entry" | jq -r '.enabled')

  echo "ID:       $id"
  echo "Name:     $name"
  echo "Type:     $type"
  echo "Project:  $project_dir"
  echo "Enabled:  $enabled"

  if [ "$type" = "heartbeat" ]; then
    local interval
    interval=$(echo "$entry" | jq -r '.interval_minutes')
    echo "Interval: every ${interval}m"

    # Show heartbeat state
    local state_file
    state_file=$(_cc_use_heartbeat_state_file "$project_dir")
    if [ -f "$state_file" ]; then
      local last_run last_result consecutive_ok consecutive_errors
      last_run=$(jq -r '.last_run // "never"' "$state_file")
      last_result=$(jq -r '.last_result // "none"' "$state_file")
      consecutive_ok=$(jq -r '.consecutive_ok' "$state_file")
      consecutive_errors=$(jq -r '.consecutive_errors' "$state_file")

      echo "Last run: $last_run → $last_result"
      echo "Streak:   ${consecutive_ok} ok, ${consecutive_errors} errors"

      # Show recent history
      local history
      history=$(jq -r '.history[:5][] | .result' "$state_file" 2>/dev/null | tr '\n' ' ')
      if [ -n "$history" ]; then
        echo "History:  $history(last 5)"
      fi
    else
      echo "State:    no heartbeat runs yet"
    fi
  else
    local cron_expr prompt
    cron_expr=$(echo "$entry" | jq -r '.cron_expr')
    prompt=$(echo "$entry" | jq -r '.prompt')
    echo "Schedule: $cron_expr"
    echo "Prompt:   ${prompt:0:80}"
  fi

  # Platform status
  echo ""
  local platform
  platform=$(_cc_use_detect_platform)
  echo "Platform: $platform"
  case "$platform" in
    macos) _cc_use_plist_status "$id" ;;
    linux) _cc_use_crontab_status "$id" ;;
  esac

  # Log info
  local log_file="${_CC_USE_LOGS}/${type}-${id}.log"
  if [ -f "$log_file" ]; then
    local log_size
    log_size=$(wc -c < "$log_file" | tr -d ' ')
    echo ""
    echo "Log: $log_file (${log_size} bytes)"
    echo "--- Last 5 lines ---"
    tail -5 "$log_file"
  else
    echo ""
    echo "Log: $log_file (not created yet)"
  fi
}
