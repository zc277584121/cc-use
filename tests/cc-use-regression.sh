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
  mkdir -p "$stub_dir"
  cat > "$stub_dir/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CC_USE_TMUX_LOG"
case "$1" in
  has-session)
    [ -f "$CC_USE_TEST_SESSION_FILE" ]
    ;;
  new-session)
    : > "$CC_USE_TEST_SESSION_FILE"
    ;;
  kill-session)
    rm -f "$CC_USE_TEST_SESSION_FILE"
    ;;
  display-message)
    printf '%s\n' "${CC_USE_TEST_GEOMETRY:-80 24 0}"
    ;;
  resize-window|set-option|send-keys|paste-buffer)
    ;;
  load-buffer)
    last_arg="${!#}"
    printf 'BUFFER:%s\n' "$(cat "$last_arg")" >> "$CC_USE_TMUX_LOG"
    ;;
  capture-pane)
    [ -f "$CC_USE_TEST_SESSION_FILE" ] || exit 1
    if printf '%s\n' "$*" | grep -q -- '-S'; then
      printf '%s\n' "${CC_USE_TEST_SCROLLBACK:-older line}"
    else
      printf '%b\n' "${CC_USE_TEST_SCREEN:-ready}"
    fi
    ;;
  list-sessions)
    printf 'user-session\nccu-codex-project-1\n'
    ;;
esac
EOF
  chmod +x "$stub_dir/tmux"
}

# Loading the script should expose helpers without dispatching the CLI.
# shellcheck disable=SC1090
source "$SCRIPT"

assert_eq "abc-DEF-ghi" "$(safe_name "abc DEF/ghi")" "safe_name normalizes unsafe characters"
assert_contains "$(new_session_name "/tmp/example project" codex)" "ccu-codex-example-project-" "new_session_name includes the agent and project"
assert_eq "=example" "$(tmux_session_target "example")" "tmux_session_target forces exact session matching"
assert_eq "=example:" "$(tmux_pane_target "example")" "tmux_pane_target forces exact pane matching"

codex_command="$(build_codex_command "")"
assert_eq "command codex --no-alt-screen --dangerously-bypass-approvals-and-sandbox" "$codex_command" "build_codex_command uses the interactive Codex command"

CODEX_FORCED_LOGIN_METHOD=api
codex_command="$(build_codex_command "")"
assert_not_contains "$codex_command" "forced_login_method" "build_codex_command never selects a login method"
unset CODEX_FORCED_LOGIN_METHOD

codex_command="$(build_codex_command "zilliz")"
assert_eq "command codex --no-alt-screen --dangerously-bypass-approvals-and-sandbox --profile zilliz" "$codex_command" "build_codex_command appends an explicit profile"

claude_command="$(build_agent_command claude "")"
assert_contains "$claude_command" "command claude" "build_agent_command bypasses shell aliases and functions for Claude"
assert_contains "$claude_command" "--dangerously-skip-permissions" "build_agent_command keeps Claude permissions bypass"

run_capture output status "$SCRIPT"
[ "$status" -eq 1 ] || fail "missing command should exit 1"
assert_contains "$output" "Usage:" "missing command prints usage"

run_capture output status "$SCRIPT" send
[ "$status" -eq 1 ] || fail "send without task should exit 1"
assert_contains "$output" "send requires TASK" "send without task reports a clear error"

run_capture output status "$SCRIPT" keys
[ "$status" -eq 1 ] || fail "keys without key names should exit 1"
assert_contains "$output" "keys requires at least one key" "keys requires an explicit interaction"

run_capture output status "$SCRIPT" monitor
[ "$status" -eq 1 ] || fail "monitor without a session should exit 1"
assert_contains "$output" "--session is required" "monitor requires an explicit task session"

run_capture output status "$SCRIPT" snapshot 'invalid:name'
[ "$status" -eq 1 ] || fail "invalid session name should exit 1"
assert_contains "$output" "session name may contain only" "invalid session name reports the allowed character set"

stub_dir="$tmp_root/stub"
write_tmux_stub "$stub_dir"
tmux_log="$tmp_root/tmux.log"
session_file="$tmp_root/session.exists"
project="$tmp_root/project"
lock_root="$tmp_root/locks"
mkdir -p "$project"
: > "$tmux_log"

common_env=(
  env
  PATH="$stub_dir:$PATH"
  CC_USE_TMUX_LOG="$tmux_log"
  CC_USE_TEST_SESSION_FILE="$session_file"
  CC_USE_LOCK_ROOT="$lock_root"
)

run_capture output status "${common_env[@]}" CC_USE_TEST_SCREEN=$'\033[31mStartup ready\033[0m  ' \
  "$SCRIPT" start --project "$project" --agent codex --session ccu-test --initial-quiet-seconds 0 --poll-interval 1
[ "$status" -eq 0 ] || fail "start should exit 0"
assert_contains "$output" '"event":"screen_stable"' "start emits a stable-screen observation"
assert_contains "$output" '"phase":"startup"' "start marks the observation as startup"
assert_contains "$output" '"session":"ccu-test"' "start returns the generated task session"
assert_eq "Startup ready" "$(cat "$project/.cc-use/state/ccu-test/screens/ccu-test-0001.txt")" "start saves a normalized startup screen"
[ -f "$session_file" ] || fail "start creates the tmux session"
[ -f "$project/.cc-use/state/ccu-test/session.json" ] || fail "start writes task-scoped session metadata"
assert_contains "$(cat "$tmux_log")" "new-session -d -s ccu-test -c $project" "start creates the session in the project"
assert_contains "$(cat "$tmux_log")" "send-keys -t =ccu-test: command codex --no-alt-screen --dangerously-bypass-approvals-and-sandbox Enter" "start launches Codex through the login shell"
assert_eq "1" "$(grep -c '^send-keys ' "$tmux_log")" "start sends only the launch command and no blind follow-up Enter"

: > "$tmux_log"
run_capture output status "${common_env[@]}" CC_USE_TEST_SCREEN="Ready after interaction" \
  "$SCRIPT" keys Down Enter --project "$project" --session ccu-test --initial-quiet-seconds 0 --poll-interval 1
[ "$status" -eq 0 ] || fail "keys should exit 0"
assert_contains "$output" '"phase":"interaction"' "keys marks the observation as interaction"
assert_contains "$(cat "$tmux_log")" "send-keys -t =ccu-test: Down Enter" "keys sends only the explicitly selected TUI keys"
assert_not_contains "$(cat "$tmux_log")" "C-u" "keys does not use the task-input clearing sequence"
assert_not_contains "$(cat "$tmux_log")" "C-m" "keys does not use the task-input Enter fallback"

: > "$tmux_log"
run_capture output status "${common_env[@]}" CC_USE_TEST_SCREEN="Task complete" \
  "$SCRIPT" send "Implement the fix." --project "$project" --session ccu-test --initial-quiet-seconds 0 --poll-interval 1
[ "$status" -eq 0 ] || fail "send should exit 0"
assert_contains "$output" '"phase":"work"' "send marks the observation as work"
assert_contains "$(cat "$tmux_log")" "BUFFER:Implement the fix." "send pastes the task unchanged"
assert_contains "$(cat "$tmux_log")" "send-keys -t =ccu-test: C-u" "send clears pending input before pasting"
assert_contains "$(cat "$tmux_log")" "send-keys -t =ccu-test: Enter" "send preserves the proven Enter submission sequence"
assert_contains "$(cat "$tmux_log")" "send-keys -t =ccu-test: C-m" "send preserves the carriage-return fallback"

run_capture output status "${common_env[@]}" "$SCRIPT" status --project "$project" --session ccu-test --json
[ "$status" -eq 0 ] || fail "status should exit 0"
assert_contains "$output" '"session_available":true' "status reports the active session"
assert_contains "$output" '"seconds_until_stable":' "status exposes the mechanical quiet-window countdown"
assert_not_contains "$output" "next_check" "status does not expose a semantic next-check suggestion"

: > "$tmux_log"
run_capture output status "${common_env[@]}" CC_USE_TEST_SCROLLBACK=$'older line\ncurrent line  ' \
  "$SCRIPT" scrollback --session ccu-test --lines 2000
[ "$status" -eq 0 ] || fail "scrollback should exit 0"
assert_eq $'older line\ncurrent line' "$output" "scrollback captures and normalizes recent history"

run_capture output status "$SCRIPT" scrollback --session ccu-test --start abc
[ "$status" -eq 1 ] || fail "scrollback with invalid start should exit 1"
assert_contains "$output" "--start must be '-' or an integer line number" "scrollback validates explicit ranges"

busy_lock="$lock_root/ccu-test.lock"
mkdir -p "$busy_lock"
printf '%s\n' "$$" > "$busy_lock/pid"
run_capture output status "${common_env[@]}" "$SCRIPT" monitor --project "$project" --session ccu-test --initial-quiet-seconds 0 --poll-interval 1
[ "$status" -eq 1 ] || fail "monitor on a busy session should exit 1"
assert_contains "$output" "session is busy: ccu-test" "the session lock prevents concurrent input and observation"
rm -rf "$busy_lock"

stale_session="ccu-stale"
stale_lock="$lock_root/$stale_session.lock"
mkdir -p "$stale_lock"
printf '%s\n' "99999999" > "$stale_lock/pid"
run_capture output status "${common_env[@]}" "$SCRIPT" monitor --project "$project" --session "$stale_session" --initial-quiet-seconds 0 --poll-interval 1
[ "$status" -eq 0 ] || fail "monitor should recover a dead operation lock"
assert_contains "$output" '"event":"screen_stable"' "monitor continues after recovering a dead operation lock"
[ ! -e "$stale_lock" ] || fail "monitor releases the recovered operation lock"

rm -f "$session_file"
run_capture output status "${common_env[@]}" "$SCRIPT" monitor --project "$project" --session ccu-missing --initial-quiet-seconds 0 --poll-interval 1
[ "$status" -eq 0 ] || fail "monitor should report a missing session"
assert_contains "$output" '"event":"session_unavailable"' "monitor reports a missing session as an observation"

: > "$session_file"
mkdir -p "$project/.cc-use/state/ccu-test"
run_capture output status "${common_env[@]}" "$SCRIPT" finish --project "$project" --session ccu-test
[ "$status" -eq 0 ] || fail "finish should exit 0"
assert_contains "$output" '"event":"session_finished"' "finish reports cleanup"
[ ! -f "$session_file" ] || fail "finish kills the exact task session"
[ ! -e "$project/.cc-use/state/ccu-test" ] || fail "finish removes the task observation state"

: > "$tmux_log"
: > "$session_file"
run_capture output status "${common_env[@]}" CC_USE_TEST_GEOMETRY="10 4 0" \
  "$SCRIPT" snapshot ccu-tiny
[ "$status" -eq 0 ] || fail "snapshot with a tiny detached pane should exit 0"
assert_contains "$(cat "$tmux_log")" "resize-window -t =ccu-tiny -x 160 -y 50" "snapshot enlarges a tiny detached pane before capture"

: > "$tmux_log"
run_capture output status "${common_env[@]}" CC_USE_TEST_GEOMETRY="10 4 1" \
  "$SCRIPT" snapshot ccu-attached
[ "$status" -eq 0 ] || fail "snapshot with a tiny attached pane should exit 0"
assert_not_contains "$(cat "$tmux_log")" "resize-window" "snapshot does not resize an attached pane"

run_capture output status "${common_env[@]}" "$SCRIPT" list
[ "$status" -eq 0 ] || fail "list should exit 0"
assert_eq "ccu-codex-project-1" "$output" "list hides unrelated user sessions"

if command -v tmux >/dev/null 2>&1; then
  base="ccu-target-check-$$"
  sibling="${base}-sibling"
  tiny="${base}-tiny"
  cleanup_tmux() {
    tmux kill-session -t "=$base" >/dev/null 2>&1 || true
    tmux kill-session -t "=$sibling" >/dev/null 2>&1 || true
    tmux kill-session -t "=$tiny" >/dev/null 2>&1 || true
  }
  cleanup_tmux
  trap 'cleanup_tmux; cleanup' EXIT

  tmux new-session -d -s "$sibling"
  if tmux_has_session "$base"; then
    fail "exact lookup matched a prefix sibling"
  fi

  tmux new-session -d -s "$base"
  tmux kill-session -t "=$base"
  tmux has-session -t "=$base" 2>/dev/null && fail "exact cleanup left the target alive"
  tmux has-session -t "=$sibling" 2>/dev/null || fail "exact cleanup removed a prefix sibling"

  tmux new-session -d -s "$tiny"
  tmux resize-window -t "=$tiny" -x 10 -y 4
  "$SCRIPT" snapshot "$tiny" >/dev/null
  assert_eq "160x50" "$(tmux list-panes -t "=$tiny" -F '#{pane_width}x#{pane_height}')" "snapshot repairs a tiny detached tmux pane"

  cleanup_tmux
  trap cleanup EXIT
fi

echo "ok - cc-use regression tests passed"
