# Claude Code Commands Guide

Quick reference for slash commands you can send to the inner Claude via tmux.

## Context Management

| Command | What it does | When to use |
|---------|-------------|-------------|
| `/compact` | Compress conversation history, keep key info | Context getting full, same task continues |
| `/compact <hint>` | Compress with focus guidance | `"/compact focus on auth module changes"` |
| `/clear` | Completely clear conversation | Switching to unrelated subtask |
| `/context` | Show context usage grid | Check how full the context is |
| `/cost` | Show token usage stats | Monitor spending |

### Sending via tmux
```bash
tmux send-keys -t "cc-use-inner" "/compact focus on current progress" Enter
tmux send-keys -t "cc-use-inner" "/clear" Enter
tmux send-keys -t "cc-use-inner" "/context" Enter
```

## Session Management

| Command | What it does |
|---------|-------------|
| `/resume` | Resume a previous session (interactive picker) |
| `/resume <name>` | Resume a named session |
| `/rename <name>` | Rename current session |
| `/fork <name>` | Branch conversation at current point |
| `/export` | Export conversation as text |
| `/export <file>` | Export to specific file |

## Model and Mode

| Command | What it does |
|---------|-------------|
| `/model <name>` | Switch model (e.g., `/model sonnet` for cheaper tasks) |
| `/plan` | Enter plan mode (analysis only, no modifications) |

## Plugin / Skill / MCP

| Command | What it does | Needs restart? |
|---------|-------------|---------------|
| `/reload-plugins` | Reload all active plugins | No |
| `/plugin install <p>` | Install a plugin | No (then `/reload-plugins`) |
| `/skills` | List available skills | No |
| `/hooks` | Manage hooks interactively | No (changes apply immediately) |
| `/mcp` | Manage MCP servers | View: No. Add/remove: **needs restart** |

## Utility

| Command | What it does |
|---------|-------------|
| `/diff` | Show interactive diff of changes made |
| `/rewind` | Rewind conversation and/or code to earlier point |
| `/help` | Show all available commands |
| `/exit` | Exit Claude Code |

## Useful for Inner Claude Development Workflows

When inner Claude is developing/testing CC plugins or skills:

```bash
# After editing plugin code
tmux send-keys -t "cc-use-inner" "/reload-plugins" Enter

# After adding MCP server (needs restart)
tmux send-keys -t "cc-use-inner" "/exit" Enter
sleep 3
tmux send-keys -t "cc-use-inner" "claude <flags>" Enter

# Check what skills are available
tmux send-keys -t "cc-use-inner" "/skills" Enter

# Test a skill
tmux send-keys -t "cc-use-inner" "/my-skill-name arg1 arg2" Enter

# Check context after heavy work
tmux send-keys -t "cc-use-inner" "/context" Enter
# Then capture to see the result:
# tmux capture-pane -t "cc-use-inner" -p -S -20
```
