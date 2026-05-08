---
name: cc-use
description: >
  Delegate long-running coding work to an inner CC session running in tmux,
  while the outer agent stays focused on supervision, monitoring, and end-to-end
  verification. Use when the user asks to run a long task, offload implementation,
  keep working while an inner coding agent executes, or use cc-use.
allowed-tools:
  - Bash
  - Read
  - Glob
  - Grep
---

# cc-use

You are the outer supervisor. Use this skill's `scripts/cc-use` helper as an
implementation detail to start and supervise an inner CC session in tmux.

Here, **CC** means a coding command-line agent. Depending on the host and local
configuration, that can mean Claude Code, Codex CLI, or another compatible
coding CLI.

## User Experience

The expected user flow is natural language in the outer TUI:

> Use cc-use to implement this long task: ...

You should then:

1. Start or reuse an inner CC session for the same agent family as the outer
   session.
2. Break the user's request into short, focused inner requests.
3. Send each inner request exactly as written, without wrapper text.
4. Monitor by screen stability, not by parsing agent-specific UI rules.
5. When the screen stays quiet long enough, inspect the saved screen snapshot
   semantically and decide whether to wait, steer, or verify.
6. Run final acceptance checks yourself from the outer session.

## Commands

Run commands from the target project root unless you pass an explicit
`--project DIR`. Use `--agent codex` from Codex and `--agent claude` from
Claude Code. Do not cross-delegate between agent families.

`--project` controls the tmux working directory, the derived session name, and
the `.cc-use/state/` location. If omitted, it defaults to the current directory.
Passing `--project "$PWD"` is recommended when the outer session may change
directories.

### `delegate`

Start or reuse the inner session, send one short request exactly as provided,
and wait until one observation is emitted:

```bash
<skill_dir>/scripts/cc-use delegate "TASK_TEXT" --project "$PWD" --agent codex
```

Important options:

- `--project DIR`: target project root. Also determines state location.
- `--agent codex|claude`: inner agent family. Match the outer agent family.
- `--session NAME`: override the derived tmux session name.
- `--profile NAME`: Codex only; use only if the user explicitly requests an
  inner Codex profile and only when creating the session.
- `--initial-quiet-seconds N`: how long a stable screen must stay quiet before
  an observation is emitted. Default is `30`.
- `--poll-interval N`: seconds between screen captures while waiting. Default
  is `2`.
- `--replace`: kill and recreate an existing session. Use only for recovery or
  an explicit fresh-start decision.

`TASK_TEXT` is passed through unchanged. Keep task decomposition in the outer
session. Do not ask the helper to add role instructions, policy text, or task
wrappers.

For Codex, omit `--profile` by default. Existing tmux/TUI sessions are reused
and do not need the profile on later requests.

Expected behavior:

- If the session does not exist, the helper creates a persistent tmux session
  named like `ccu-<project-name>`.
- If the session already exists, the helper reuses it.
- The command normally returns one JSON event after the screen becomes stable.
- If the screen keeps changing, the command may block until the screen becomes
  quiet.

### `monitor`

Observe an existing derived session and wait for one observation:

```bash
<skill_dir>/scripts/cc-use monitor --project "$PWD" --agent codex
```

Use this after a previous observation suggests waiting, after you have waited
based on your own semantic judgment, or after the user asks for status.

Important options:

- `--project DIR`, `--agent codex|claude`, `--session NAME`: identify the target
  session.
- `--initial-quiet-seconds N`, `--poll-interval N`: same meaning as `delegate`.

Expected behavior:

- If the screen changes, the helper resets the quiet timer and continues
  waiting.
- If the screen stays unchanged long enough, the helper saves a snapshot and
  emits an `inspect` observation.
- If the tmux session is gone, the helper emits `session_unavailable`.

### `project-status`

Check the derived project/session status without sending input:

```bash
<skill_dir>/scripts/cc-use project-status --project "$PWD" --agent codex
```

Use `--json` when you need machine-readable output:

```bash
<skill_dir>/scripts/cc-use project-status --project "$PWD" --agent codex --json
```

Expected text output includes:

- `project`: resolved project directory.
- `session`: derived or explicit session name.
- `agent`: selected agent family.
- `session_available`: whether tmux currently has the session.
- `observations`: number of saved observations for this session.
- `silence_seconds`: seconds since the last detected screen change.
- `seconds_until_next_check`: current watch schedule hint from state.

### `scrollback`

If the saved screen snapshot does not include enough context, inspect recent
tmux scrollback on demand. This is a temporary read to stdout, not a persistent
transcript:

```bash
<skill_dir>/scripts/cc-use scrollback --project "$PWD" --agent codex --lines 2000
```

For paged inspection, use tmux line ranges. Negative numbers refer to scrollback
history, `0` is the first visible line, and `-` means the end of the visible
pane:

```bash
<skill_dir>/scripts/cc-use scrollback --project "$PWD" --agent codex --start -4000 --end -2001
<skill_dir>/scripts/cc-use scrollback --project "$PWD" --agent codex --start -2000 --end -
```

Options:

- `--lines N`: capture from `-N` through the end of the visible pane. Default is
  `2000`.
- `--start LINE`: explicit tmux capture start line.
- `--end LINE`: explicit tmux capture end line. Default is `-`.

Line semantics come from tmux:

- Negative numbers are lines in scrollback history.
- `0` is the first visible line.
- `-` means the end of the visible pane.

Use `scrollback` only after an `inspect` observation when the saved snapshot is
too narrow. Do not use it as a continuous progress feed while the screen is
actively changing.

### Low-level commands

These exist for diagnostics and recovery:

```bash
<skill_dir>/scripts/cc-use list
<skill_dir>/scripts/cc-use snapshot <session>
<skill_dir>/scripts/cc-use kill <session>
```

Use `kill` only when the user explicitly asks to close the inner session, or
when the session is broken and a fresh session is required.

Keep the inner session running by default. A long-running project may span
multiple outer conversations or calendar days, and the existing tmux/TUI session
preserves useful continuity for later work.

Only stop the inner session if the user explicitly asks you to close it, or if
the session is broken and you have decided a fresh session is required.

## Monitoring Model

`delegate` and `monitor` use adaptive observation:

- If the tmux screen changes, the outer agent does not read details and lets the
  inner agent keep working.
- If the screen stays unchanged past the current quiet threshold, cc-use captures
  the screen once and emits a neutral `inspect` observation.
- The helper does not classify stable screens as wait, intervene, or verify.
  Always read `screen_path` and make the semantic decision in the outer session.
- If the snapshot is too narrow, use `scrollback --lines N` or
  `scrollback --start LINE --end LINE` for temporary context. Do not create
  persistent transcript logs by default.

Typical observation:

```json
{
  "event": "observation",
  "session": "ccu-my-project",
  "observed_at": 1778223935,
  "silence_seconds": 20,
  "screen_digest": "sha256...",
  "screen_path": "/path/to/project/.cc-use/state/ccu-my-project/screens/ccu-my-project-0001.txt",
  "decision": {
    "action": "inspect",
    "next_check_after_seconds": 0,
    "reason": "The screen is stable; inspect screen_path semantically before deciding whether to wait, steer, or verify.",
    "confidence": 1.0
  }
}
```

`inspect` means only that the screen is stable enough to review. It does not
mean the task is complete, blocked, failed, or still running. The outer session
must read `screen_path` and decide.

`session_unavailable` means tmux no longer has the expected session. Decide
whether to restart, report failure, or ask the user.

## Outer Decision Rules

After an `inspect` observation:

- If the snapshot shows final output or a prompt after a completed response, run
  outer acceptance checks.
- If it shows tests, builds, downloads, or server commands that may still be
  running quietly, wait a reasonable interval and call `monitor` again.
- If it shows a permission prompt, password prompt, yes/no question, or blocked
  input, intervene or ask the user.
- If it shows an error, send one short corrective request or report the blocker.
- If it is too narrow to understand, call `scrollback` once with enough lines or
  an explicit range, then decide.

If the screen is actively changing, `delegate` or `monitor` may not return for a
while because the quiet timer keeps resetting. This is expected. The helper is
designed to avoid consuming active output.

Outer acceptance checks must be run outside the inner session. Check the actual
files, run relevant tests or commands, inspect UI if applicable, and confirm the
work matches the user's request.

## Discipline

- Do not expose tmux/session/state details unless the user asks.
- Do not pass or synthesize environment variables for the inner session.
- Do not kill the inner session at routine task completion; leave it available
  for future delegated work.
- Do not rely on the inner screen as proof of success; verify externally.
- Do not use `scrollback` as a persistent transcript. It is a temporary tmux
  history read.
- Let the inner agent do implementation work.
- The outer agent owns acceptance testing and final judgment.
