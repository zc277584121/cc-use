#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/skills/cc-use/scripts/cc-use"

tmp_root="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_root"
}
trap cleanup EXIT

fail() {
  echo "not ok - $*" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  if [ "$expected" != "$actual" ]; then
    fail "$message: expected [$expected], got [$actual]"
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"
  case "$haystack" in
    *"$needle"*) ;;
    *) fail "$message: missing [$needle] in [$haystack]" ;;
  esac
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"
  case "$haystack" in
    *"$needle"*) fail "$message: unexpected [$needle] in [$haystack]" ;;
  esac
}

run_capture() {
  local __output_var="$1"
  local __status_var="$2"
  shift 2
  local command_output
  local command_status
  set +e
  command_output="$("$@" 2>&1)"
  command_status=$?
  set -e
  printf -v "$__output_var" '%s' "$command_output"
  printf -v "$__status_var" '%s' "$command_status"
}

write_tmux_stub() {
  local stub_dir="$1"
  local mode="$2"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/tmux" <<EOF
#!/usr/bin/env bash
mode="$mode"
case "\$mode:\$1" in
  list:list-sessions)
    printf 'alpha\nbeta\n'
    ;;
  snapshot:capture-pane)
    printf '\\033[31mred\\033[0m  \n'
    ;;
  scrollback:capture-pane)
    if [ "\$6" = "-2000" ] && [ "\$8" = "-" ]; then
      printf 'older line\ncurrent line  \n'
    else
      exit 2
    fi
    ;;
  scrollback-range:capture-pane)
    if [ "\$6" = "-4000" ] && [ "\$8" = "-2001" ]; then
      printf 'range line\n'
    else
      exit 2
    fi
    ;;
  unavailable:capture-pane)
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "$stub_dir/tmux"
}

# Loading the script should expose helpers without dispatching the CLI.
# shellcheck disable=SC1090
source "$SCRIPT"

assert_eq "abc-DEF-ghi" "$(safe_name "abc DEF/ghi")" "safe_name normalizes unsafe characters"
assert_eq "ccu-example-project" "$(session_name_for_project "/tmp/example project")" "session_name_for_project uses compact safe basename"

prompt="$(build_inner_task_prompt $'first line\nsecond line')"
assert_eq $'first line\nsecond line' "$prompt" "build_inner_task_prompt passes text through unchanged"

codex_command="$(build_codex_command "" "workspace-write" "never")"
assert_contains "$codex_command" "command codex" "build_codex_command bypasses shell aliases and functions"
assert_contains "$codex_command" "--no-alt-screen" "build_codex_command includes stable tmux-friendly mode"
assert_not_contains "$codex_command" "--profile" "build_codex_command omits profile by default"

codex_command="$(build_codex_command "zilliz" "workspace-write" "never")"
assert_contains "$codex_command" "--profile zilliz" "build_codex_command includes explicit profile only when requested"

# cc-use uses --dangerously-bypass-approvals-and-sandbox unconditionally
# (the old --ask-for-approval / --sandbox pair clashed with bypass-mode configs)
codex_command="$(build_codex_command "" "workspace-write" "never")"
assert_contains "$codex_command" "--dangerously-bypass-approvals-and-sandbox" "build_codex_command uses bypass mode"
assert_not_contains "$codex_command" "--ask-for-approval" "build_codex_command does not include --ask-for-approval"
assert_not_contains "$codex_command" "--sandbox" "build_codex_command does not include --sandbox"

codex_command="$(build_codex_command "zilliz" "workspace-write" "never")"
assert_contains "$codex_command" "--profile zilliz" "profile still appended in bypass mode"

claude_command="$(build_agent_command claude "" workspace-write never)"
assert_contains "$claude_command" "command claude" "build_agent_command bypasses shell aliases and functions for Claude"
assert_contains "$claude_command" "--dangerously-skip-permissions" "build_agent_command keeps Claude permissions bypass"

screen_file="$tmp_root/screen.txt"
printf 'Allow this command?\n' > "$screen_file"
decision_for_stable_screen
assert_eq "inspect" "$decision_action" "stable screen observations require semantic inspection"
assert_eq "0" "$decision_next" "stable screen observations do not schedule heuristic waiting"

run_capture output status "$SCRIPT"
[ "$status" -eq 1 ] || fail "missing command should exit 1"
assert_contains "$output" "Usage:" "missing command prints usage"

run_capture output status "$SCRIPT" delegate
[ "$status" -eq 1 ] || fail "delegate without task should exit 1"
assert_contains "$output" "delegate requires TASK" "delegate without task reports a clear error"

stub_dir="$tmp_root/stub-list"
write_tmux_stub "$stub_dir" list
run_capture output status env PATH="$stub_dir:$PATH" "$SCRIPT" list
[ "$status" -eq 0 ] || fail "list with tmux stub should exit 0"
assert_eq $'alpha\nbeta' "$output" "list prints tmux session names"

stub_dir="$tmp_root/stub-snapshot"
write_tmux_stub "$stub_dir" snapshot
run_capture output status env PATH="$stub_dir:$PATH" "$SCRIPT" snapshot fake-session
[ "$status" -eq 0 ] || fail "snapshot with tmux stub should exit 0"
assert_eq "red" "$output" "snapshot strips ANSI escapes and trailing spaces"

stub_dir="$tmp_root/stub-launch"
mkdir -p "$stub_dir"
cat > "$stub_dir/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CC_USE_TMUX_LOG"
exit 0
EOF
chmod +x "$stub_dir/tmux"
launch_log="$tmp_root/launch.log"
run_capture output status env PATH="$stub_dir:$PATH" CC_USE_TMUX_LOG="$launch_log" bash -c '
  source "$1"
  launch_agent_session test-session /tmp/project "command codex --profile zilliz"
' _ "$SCRIPT"
[ "$status" -eq 0 ] || fail "launch_agent_session with tmux stub should exit 0"
launch_output="$(cat "$launch_log")"
assert_contains "$launch_output" "new-session -d -s test-session -c /tmp/project" "launch_agent_session starts an interactive shell in the project"
assert_contains "$launch_output" "send-keys -t test-session command codex --profile zilliz Enter" "launch_agent_session starts the agent via shell input"
assert_not_contains "$launch_output" "bash -lc" "launch_agent_session does not bypass shell startup files"

stub_dir="$tmp_root/stub-scrollback"
write_tmux_stub "$stub_dir" scrollback
run_capture output status env PATH="$stub_dir:$PATH" "$SCRIPT" scrollback --project "$tmp_root" --agent codex --lines 2000
[ "$status" -eq 0 ] || fail "scrollback with tmux stub should exit 0"
assert_eq $'older line\ncurrent line' "$output" "scrollback captures requested history and normalizes output"

stub_dir="$tmp_root/stub-scrollback-range"
write_tmux_stub "$stub_dir" scrollback-range
run_capture output status env PATH="$stub_dir:$PATH" "$SCRIPT" scrollback --project "$tmp_root" --agent codex --start -4000 --end -2001
[ "$status" -eq 0 ] || fail "scrollback range with tmux stub should exit 0"
assert_eq "range line" "$output" "scrollback captures explicit start and end range"

run_capture output status "$SCRIPT" scrollback --project "$tmp_root" --agent codex --start abc
[ "$status" -eq 1 ] || fail "scrollback with invalid start should exit 1"
assert_contains "$output" "--start must be '-' or an integer line number" "scrollback validates explicit start"

project="$tmp_root/project"
mkdir -p "$project"
stub_dir="$tmp_root/stub-unavailable"
write_tmux_stub "$stub_dir" unavailable
run_capture output status env PATH="$stub_dir:$PATH" "$SCRIPT" monitor --project "$project" --agent claude --initial-quiet-seconds 0 --poll-interval 1
[ "$status" -eq 0 ] || fail "monitor unavailable session should exit 0"
assert_contains "$output" '"event":"session_unavailable"' "monitor reports unavailable session as JSON"
assert_contains "$output" '"session":"ccu-project"' "monitor includes derived session name"
[ -f "$project/.cc-use/state/ccu-project/watch.observations.jsonl" ] || fail "monitor writes session-scoped observation history"

cat > "$project/.cc-use/state/ccu-project/watch.env" <<'EOF'
last_digest=abc123
silence_started_at=1
next_check_at=1
observation_count=2
EOF
run_capture output status env PATH="$stub_dir:$PATH" "$SCRIPT" project-status --project "$project" --agent claude --json
[ "$status" -eq 0 ] || fail "project-status --json should exit 0"
assert_contains "$output" '"session":"ccu-project"' "project-status JSON includes derived session"
assert_contains "$output" '"agent":"claude"' "project-status JSON includes agent"
assert_contains "$output" '"observation_count":2' "project-status JSON includes watch state"

schedule_home="$tmp_root/schedule-home"
mkdir -p "$schedule_home"
stub_dir="$tmp_root/stub-launchctl"
mkdir -p "$stub_dir"
cat > "$stub_dir/launchctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$stub_dir/launchctl"
cat > "$stub_dir/codex" <<'EOF'
#!/usr/bin/env bash
printf 'codex args:'
printf ' <%s>' "$@"
printf '\n'
exit 0
EOF
chmod +x "$stub_dir/codex"

run_capture output status env HOME="$schedule_home" PATH="$stub_dir:$PATH" "$SCRIPT" schedule-add cron daily --project "$project" --cron-expr "0 7 * * *" --prompt "check" --agent codex --profile zilliz --search
[ "$status" -eq 0 ] || fail "schedule-add cron should exit 0"
assert_contains "$output" "added cron schedule" "schedule-add cron reports success"
cron_id="$(jq -r '.schedules[] | select(.type == "cron") | .id' "$schedule_home/.cc-use/schedules.json")"
assert_contains "$(jq -c '.schedules[0]' "$schedule_home/.cc-use/schedules.json")" '"agent":"codex"' "cron schedule stores agent"
assert_contains "$(jq -c '.schedules[0]' "$schedule_home/.cc-use/schedules.json")" '"profile":"zilliz"' "cron schedule stores profile"
assert_contains "$(jq -c '.schedules[0]' "$schedule_home/.cc-use/schedules.json")" '"search":true' "cron schedule stores search flag"
assert_contains "$(jq -c '.schedules[0]' "$schedule_home/.cc-use/schedules.json")" '"sandbox":"danger-full-access"' "cron schedule defaults to broad sandbox"
if [ "$(uname -s)" = "Darwin" ]; then
  [ -f "$schedule_home/Library/LaunchAgents/com.cc-use.${cron_id}.plist" ] || fail "schedule-add cron writes launchd plist"
  assert_contains "$(plutil -p "$schedule_home/Library/LaunchAgents/com.cc-use.${cron_id}.plist")" "schedule-run" "cron plist calls unified runner"
fi

run_capture output status env HOME="$schedule_home" PATH="$stub_dir:$PATH" "$SCRIPT" schedule-add heartbeat news --project "$project" --interval-minutes 15 --agent codex --profile zilliz --session hb-news
[ "$status" -eq 0 ] || fail "schedule-add heartbeat should exit 0"
assert_contains "$output" "added heartbeat schedule" "schedule-add heartbeat reports success"
assert_contains "$(jq -c '.schedules[] | select(.type == "heartbeat")' "$schedule_home/.cc-use/schedules.json")" '"session_name":"hb-news"' "heartbeat schedule stores explicit session"
assert_contains "$(jq -c '.schedules[] | select(.type == "heartbeat")' "$schedule_home/.cc-use/schedules.json")" '"sandbox":"danger-full-access"' "heartbeat schedule defaults to broad sandbox"

run_capture output status env HOME="$schedule_home" PATH="$stub_dir:$PATH" "$SCRIPT" schedule-list
[ "$status" -eq 0 ] || fail "schedule-list should exit 0"
assert_contains "$output" "zilliz" "schedule-list includes profile"

run_capture output status env HOME="$schedule_home" PATH="$stub_dir:$PATH" "$SCRIPT" schedule-run "$cron_id"
[ "$status" -eq 0 ] || fail "schedule-run cron should exit 0"
assert_contains "$(cat "$schedule_home/.cc-use/logs/cron-${cron_id}.log")" "codex args: <--profile> <zilliz> <--dangerously-bypass-approvals-and-sandbox> <--search> <exec> <--skip-git-repo-check>" "schedule-run cron uses stored global options"
assert_contains "$(cat "$schedule_home/.cc-use/logs/cron-${cron_id}.log")" "<--search>" "schedule-run cron uses the stored search flag"

echo "ok - cc-use regression tests passed"
