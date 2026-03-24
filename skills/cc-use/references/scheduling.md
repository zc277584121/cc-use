# Scheduling Reference: Heartbeat & Cron

cc-use provides OS-level scheduling (macOS launchd / Linux crontab) for two modes of automated Claude interaction.

## Overview

| Feature | Heartbeat | Cron |
|---------|-----------|------|
| **Purpose** | "Periodically check if anything needs attention" | "Do this specific thing at this specific time" |
| **Session** | Persistent tmux session (shared context) | Oneshot `claude -p` (isolated, no history) |
| **Trigger** | Interval-based (e.g., every 30m) | Cron expression (e.g., `0 9 * * *`) |
| **Output** | `HEARTBEAT_OK` (silent) or alert (notify) | Logged, notify on failure |
| **State** | `.cc-use/heartbeat-state.json` tracks history | Log file only |

## Configuration

### Global config: `~/.cc-use/config.json`

```json
{
  "notifiers": [
    {
      "name": "feishu-team",
      "type": "feishu",
      "webhook_url": "https://open.feishu.cn/open-apis/bot/v2/hook/YOUR_TOKEN"
    }
  ],
  "default_notifier": "feishu-team"
}
```

Set this up before using notifications. Without it, alerts are only written to log files.

### Adding notifiers

Each notifier is a `{name, type, webhook_url}` entry. Supported types:

| Type | Platform | Webhook format |
|------|----------|----------------|
| `feishu` | Feishu/Lark | Bot webhook URL from group settings |

Future types (not yet implemented): `slack`, `discord`, `telegram`.

To add a new platform, implement `_cc_use_notify_<type>()` in `cc-use-schedule.sh`.

### Schedule database: `~/.cc-use/schedules.json`

Auto-managed. Do not edit manually. Use `schedule_add` / `schedule_remove` commands.

## Writing heartbeat.md

The heartbeat checklist tells Claude what to check during each heartbeat. Keep it **short, specific, and actionable**.

### Good example

```markdown
# Heartbeat Checklist

Check the following and respond with HEARTBEAT_OK if everything is normal:

- Check if any GitHub PRs in this repo need review (use gh pr list)
- Check if CI is green on main branch (use gh run list)
- Check disk space (df -h) and alert if any filesystem is > 90% full
```

### Bad example (too vague, too long)

```markdown
# Heartbeat
- Check everything
- Make sure the project is working
- Review all code changes
- Analyze performance trends
- Generate a comprehensive report
```

### Tips

- Each check item should be completable in < 30 seconds
- Be specific about what tools/commands to use
- Include the threshold for alerting (e.g., "> 90% full")
- End with the HEARTBEAT_OK instruction
- 3-5 items is ideal; more items = more API cost per heartbeat

## Heartbeat State

Each project tracks heartbeat history in `.cc-use/heartbeat-state.json`:

```json
{
  "last_run": "2026-03-24T09:30:00Z",
  "last_result": "ok",
  "consecutive_ok": 5,
  "consecutive_errors": 0,
  "last_alert": null,
  "last_alert_time": null,
  "history": [
    {"time": "2026-03-24T09:30:00Z", "result": "ok", "duration_sec": 12},
    {"time": "2026-03-24T09:00:00Z", "result": "alert", "duration_sec": 45, "summary": "PR #123 needs review"}
  ]
}
```

**Results**: `ok` (HEARTBEAT_OK), `alert` (substantive response), `skipped` (Claude busy), `error` (session dead, timeout, etc.)

History keeps the last 20 entries, auto-pruned.

## Platform Details

### macOS (launchd)

Schedules are registered as LaunchAgents:
- Plist files: `~/Library/LaunchAgents/com.cc-use.<id>.plist`
- Heartbeat uses `StartInterval` (seconds)
- Cron uses `StartCalendarInterval` (simple expressions only)

**Important — launchd environment pitfalls**:

1. **Minimal PATH**: launchd only provides `/usr/bin:/bin:/usr/sbin:/sbin`. Runner scripts restore PATH from the value saved at `schedule_add` time. If you install claude to a new location, re-add the schedule.

2. **HOME may be unset**: Runner scripts explicitly set `HOME` as a fallback.

3. **Claude Code env vars cause conflicts**: If an outer Claude Code process was running when the plist was loaded, launchd may inherit `CLAUDECODE`, `CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_CODE_SSE_PORT` — these cause SSE port conflicts when the runner tries to start a new claude process. Runner scripts `unset` these variables.

4. **Don't source shell profiles**: `.bash_profile` / `.zshrc` often contain `conda init` or `nvm` hooks that hang in non-interactive shells. Set PATH explicitly instead.

### Linux (crontab)

Schedules are crontab entries with `#cc-use:<id>` marker comments:
```
*/30 * * * * /bin/bash /path/to/cc-use-heartbeat-runner.sh hb-abc123 #cc-use:hb-abc123
```

## Troubleshooting

### Heartbeat not firing

1. Check if schedule is registered: `.cc-use/cc schedule_status <id>`
2. macOS: `launchctl list | grep cc-use`
3. Linux: `crontab -l | grep cc-use`
4. Check log file: `cat ~/.cc-use/logs/heartbeat-<id>.log`

### "Session dead" errors

The heartbeat runner checks if the tmux session exists. If `auto_restart: true`, it will attempt to relaunch. If restart keeps failing:
1. Check if tmux is running: `tmux ls`
2. Check if claude is accessible: `which claude`
3. Check the saved `claude_path` in schedules.json matches current installation

### "Claude is busy, skipping"

Normal behavior — heartbeat won't interrupt ongoing work. If every heartbeat is skipped, the inner Claude may be stuck on a long task. Check manually: `tmux attach -t <session>`

### Notifications not working

1. Verify `~/.cc-use/config.json` exists and has correct webhook URL
2. Test webhook manually: `curl -X POST <url> -H "Content-Type: application/json" -d '{"msg_type":"text","content":{"text":"test"}}'`
3. Check log file for curl errors

### Cron expression limitations (macOS)

launchd's `StartCalendarInterval` only supports simple expressions. These work:
- `0 9 * * *` (daily at 9am)
- `0 9 * * 1-5` (weekdays at 9am)
- `30 */2 * * *` (every 2 hours at :30)

These do NOT work with launchd (use interval-based heartbeat instead):
- `*/5 * * * *` (every 5 minutes) — use heartbeat with `interval_min=5`
- Complex expressions with multiple values

## Logs

All logs are in `~/.cc-use/logs/`:
- `heartbeat-<id>.log` — heartbeat execution logs
- `cron-<id>.log` — cron job execution logs

Logs auto-rotate at 1MB, keeping 3 backups (`.log.1`, `.log.2`, `.log.3`).

View logs:
```bash
# Quick status (includes last 5 log lines)
.cc-use/cc schedule_status <id>

# Full log
cat ~/.cc-use/logs/heartbeat-<id>.log

# Follow live
tail -f ~/.cc-use/logs/heartbeat-<id>.log
```
