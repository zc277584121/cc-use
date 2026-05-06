# cc-use

cc-use is a skill for delegating long-running coding work to an inner CC session
running in tmux. The user-facing interface is the skill, not the CLI.

The outer agent stays in the main interactive TUI, starts or reuses an inner
CC session, sends the task there, monitors by screen stability, and performs
final acceptance checks itself.

Here, **CC** means a coding command-line agent. Depending on the host and local
configuration, that can mean Claude Code, Codex CLI, or another compatible
coding CLI. The important part is the supervision pattern: one outer interactive
agent delegates implementation work to an inner terminal session.

## How Users Invoke It

Use cc-use from an interactive coding-agent session by mentioning the skill and
the task in natural language.

### Codex CLI

In Codex CLI, first confirm the skill is visible:

```text
/skills
```

Then invoke it from the chat:

```text
$cc-use Fix the flaky test in this repo. Let the inner agent investigate and
implement the fix, then verify it end-to-end.
```

or:

```text
Use cc-use to add a small CLI command to this project. Let the inner agent do
the implementation and come back when it has a result to verify.
```

The outer agent should load `cc-use` skill instructions and run the underlying
delegation commands itself. The user should not need to type tmux or `uv run`
commands.

### Claude Code

In Claude Code, confirm the skill is available:

```text
/skills
```

Then ask for it explicitly:

```text
Use the cc-use skill to refactor the database module. Delegate the implementation
to an inner session and keep me updated only when there is something to review.
```

or:

```text
Use cc-use for this long task: implement password reset, run the tests, and let
me know when the outer verification should start.
```

The exact trigger syntax may differ by host, but the reliable pattern is to name
the skill directly: `cc-use`, `$cc-use`, or `Use the cc-use skill...`.

## What The Skill Does

When invoked, the outer agent should:

1. Start or reuse an inner CC session in tmux.
2. Send the user's task to the inner session.
3. Avoid reading the inner screen while it is actively changing.
4. If the screen is quiet past the current expectation, inspect one screen
   snapshot and decide when to check again.
5. Steer the inner agent only when needed.
6. Run final acceptance checks from the outer session.

This keeps the outer context small while the inner session handles code-level
implementation details.

## Monitoring Model

cc-use does not try to parse a specific TUI state. It compares normalized tmux
screen snapshots:

- If the screen changes, the inner agent is considered active and the outer agent
  stays out of the way.
- If the screen stays unchanged past the current quiet threshold, cc-use captures
  one screen snapshot and emits an observation.
- Each observation includes a suggested next check interval. The outer agent can
  wait, inspect further, steer the inner session, or start verification.

## How It Works

cc-use treats the tmux pane as the only shared surface between the outer and
inner agents. The outer agent does not consume the inner agent's file reads,
tool calls, or command output directly. It only observes the terminal screen at
controlled moments.

The loop is:

1. Capture the current tmux screen text.
2. Normalize it and compute a hash.
3. If the hash changed, mark the inner session as active and do nothing else.
4. If the hash stays unchanged long enough, capture one screen snapshot for
   inspection.
5. Based on that snapshot, produce an observation with a suggested next check
   time.

This keeps the outer context small while preserving enough information to make
human-like supervision decisions.

### What The Outer Agent Sees

The outer agent sees a normal terminal screen from the inner CC session. Typical
examples:

```text
• Running pytest
  └ collected 42 items
```

The screen is changing. cc-use treats this as active work. The outer agent does
not inspect every line; it waits.

```text
• Running npm test
```

The screen may stop changing while a long command is still running. When the
quiet threshold is reached, cc-use emits an observation. A reasonable decision is
to wait longer, for example 60-180 seconds, because test/build commands can be
quiet for a while.

```text
› Create result.txt with hello.

• DONE
```

The screen is quiet and appears to show a completed response. The outer agent can
inspect the result and start acceptance verification.

```text
Allow this command?
```

The screen is quiet because the inner session is blocked on input. The outer
agent should intervene, ask the user if needed, or send an appropriate key.

```text
network request timed out
```

The screen is quiet after an error. The outer agent can send a correction or ask
the inner agent to retry with a different approach.

### Observation Actions

An observation is a structured event written to `.cc-use/state/` and printed to
the outer agent. It includes:

- how long the screen has been quiet;
- the current screen hash;
- the saved screen snapshot path;
- a suggested action and next check interval.

Example:

```json
{
  "event": "observation",
  "session": "cc-use-my-project",
  "silence_seconds": 8.005,
  "decision": {
    "action": "wait",
    "next_check_after_seconds": 60,
    "reason": "No screen changes were observed; wait a moderate interval before checking again.",
    "confidence": 0.5
  }
}
```

The decision is not a hard rule. It is a scheduling hint for the outer agent.

### Situation To Action

| tmux screen situation | cc-use behavior | outer agent action |
| --- | --- | --- |
| Screen keeps changing | Resets quiet timer | Do not inspect; let inner work |
| Quiet after a short task | Emits observation | Verify files, commands, or UI from outside |
| Quiet while tests/build likely run | Suggests waiting longer | Call `monitor` later |
| Quiet on permission/input prompt | Suggests intervention | Send key, steer, or ask user |
| Quiet after visible error | Emits observation | Send corrective instruction |
| Session disappeared | Emits `session_unavailable` | Decide whether to restart or report failure |

The important distinction is that cc-use is not an idle detector. It is an
adaptive observation scheduler: it decides when the outer agent should look
again if nothing changes.

## Installation

Install using [npx skills](https://skills.sh).

### Install to all supported agents

```bash
# Global: available in all projects, all supported agents
npx skills add zc277584121/cc-use --all -g

# Project-level: current project only, all supported agents
npx skills add zc277584121/cc-use --all
```

### Install to a specific agent

```bash
npx skills add zc277584121/cc-use -a claude-code -g
npx skills add zc277584121/cc-use -a codex -g
```

Other supported agents include `cursor`, `windsurf`, `github-copilot`, `cline`,
`roo`, `gemini-cli`, `goose`, `kilo`, `augment`, `opencode`, and more. See
[skills.sh](https://skills.sh) for the current list.

Without `-g`, skills are installed into the current project. With `-g`, they are
installed globally and are available across projects.

## Updating

```bash
# Check for updates
npx skills check

# Update globally installed skills
npx skills update
```

To update a project-level install, re-run the `npx skills add` command.

## Local Development Notes

The skill file should be installed where the host agent loads skills from.

On this machine, the installed skill file is:

```text
/Users/zilliz/.agents/skills/cc-use/SKILL.md
```

The source copy in this repository is:

```text
skills/cc-use/SKILL.md
```

After updating the skill file, restart the interactive agent or reload skills if
the host supports it.

## Developer Debugging

The shell helper exists for the skill and for maintainers. It is not the normal
user interface, and it does not require `uv` or a Python package install.

Project-level commands used by the skill:

```bash
skills/cc-use/scripts/cc-use delegate "TASK_TEXT" --project "$PWD"
skills/cc-use/scripts/cc-use monitor --project "$PWD"
skills/cc-use/scripts/cc-use project-status --project "$PWD"
```

Low-level debugging commands:

```bash
skills/cc-use/scripts/cc-use list
skills/cc-use/scripts/cc-use snapshot <session>
skills/cc-use/scripts/cc-use kill <session>
```

## Runtime State

For each delegated project, cc-use writes state under:

```text
.cc-use/state/
```

Important files:

- `session-info.json`: project, session, and agent config.
- `watch.json`: current watch schedule and latest observation.
- `watch.observations.jsonl`: observation history.
- `screens/`: normalized screen snapshots captured during observations.
