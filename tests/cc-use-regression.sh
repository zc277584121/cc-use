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
assert_contains "$codex_command" "--no-alt-screen" "build_codex_command includes stable tmux-friendly mode"
assert_not_contains "$codex_command" "--profile" "build_codex_command omits profile by default"

codex_command="$(build_codex_command "zilliz" "workspace-write" "never")"
assert_contains "$codex_command" "--profile zilliz" "build_codex_command includes explicit profile only when requested"

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

echo "ok - cc-use regression tests passed"
