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

You are the outer supervisor. The user should not have to run cc-use commands
manually. Use this skill's `scripts/cc-use` helper as an implementation detail
to start and supervise an inner CC session in tmux.

Here, **CC** means a coding command-line agent. Depending on the host and local
configuration, that can mean Claude Code, Codex CLI, or another compatible
coding CLI.

## User Experience

The expected user flow is natural language in the outer TUI:

> Use cc-use to implement this long task: ...

You should then:

1. Start or reuse an inner CC session.
2. Send the user's task to the inner session.
3. Monitor by screen stability, not by parsing agent-specific UI rules.
4. When the screen stays quiet long enough, inspect the observation output and
   decide whether to wait, steer, or verify.
5. Run final acceptance checks yourself from the outer session.

## Commands

Run all commands from the target project root.

Start or reuse the inner session, send the task, and wait for one observation:

```bash
<skill_dir>/scripts/cc-use delegate "TASK_TEXT" --project "$PWD"
```

Monitor again later using saved project state:

```bash
<skill_dir>/scripts/cc-use monitor --project "$PWD"
```

Check saved project state:

```bash
<skill_dir>/scripts/cc-use project-status --project "$PWD"
```

Stop the inner session only when no longer needed:

```bash
session=$(<skill_dir>/scripts/cc-use project-status --project "$PWD" --json | jq -r .config.session)
<skill_dir>/scripts/cc-use kill "$session"
```

## Monitoring Model

`delegate` and `monitor` use adaptive observation:

- If the tmux screen changes, the outer agent does not read details and lets the
  inner agent keep working.
- If the screen stays unchanged past the current quiet threshold, cc-use captures
  the screen once and emits an observation with a suggested next check interval.
- Treat the suggested interval as a scheduling hint. If it says wait, call
  `monitor` again later. If it suggests intervention, inspect the screen or send
  a correction.

## Discipline

- Do not ask the user to run cc-use commands.
- Do not expose tmux/session/state details unless the user asks.
- Let the inner agent do implementation work.
- The outer agent owns acceptance testing and final judgment.
