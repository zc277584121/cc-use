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

1. Start or reuse an inner CC session for the same agent family as the outer
   session.
2. Break the user's request into short, focused inner requests.
3. Send each inner request exactly as written, without wrapper text.
4. Monitor by screen stability, not by parsing agent-specific UI rules.
5. When the screen stays quiet long enough, inspect the observation output and
   decide whether to wait, steer, or verify.
6. Run final acceptance checks yourself from the outer session.

## Commands

Run all commands from the target project root.

Start or reuse the inner session, send one short request, and wait for one
observation:

```bash
<skill_dir>/scripts/cc-use delegate "TASK_TEXT" --project "$PWD" --agent codex
```

`TASK_TEXT` is passed through unchanged. Do not ask the helper to add role
instructions or task wrappers; keep decomposition in the outer session.

Use `--agent codex` from Codex and `--agent claude` from Claude Code. Do not
cross-delegate between agent families.

For Codex, omit `--profile` by default. If the user explicitly requests a
specific inner Codex profile when the inner session is first created, pass it on
that first `delegate` call, for example `--profile zilliz`. Existing tmux/TUI
sessions are reused and do not need the profile on later requests.

Monitor again later using the derived tmux session:

```bash
<skill_dir>/scripts/cc-use monitor --project "$PWD" --agent codex
```

Check the derived project/session status:

```bash
<skill_dir>/scripts/cc-use project-status --project "$PWD" --agent codex
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
- Do not pass or synthesize environment variables for the inner session.
- Let the inner agent do implementation work.
- The outer agent owns acceptance testing and final judgment.
