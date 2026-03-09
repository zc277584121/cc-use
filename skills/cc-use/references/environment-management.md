# Environment Management

## Tracking Changes

All environment modifications made during a cc-use session should be recorded in `.cc-use/state/env-changes.md`.

### Format

```markdown
## Environment Changes

### Packages (global)
- [installed] <package> (<manager>) → revert: `<uninstall command>`

### Packages (project)
- [installed] <package> → no revert needed (project-scoped)

### MCP Servers
- [added] <name> (scope: <user|project|local>) → revert: `claude mcp remove <name>`

### Plugins
- [installed] <name> → revert: `claude plugin uninstall <name>`

### Config Files
- [created] <file> → revert: `rm <file>`
- [modified] <file> → revert: <instructions or backup path>

### System
- [modified] <what> → revert: <instructions>
```

## What Requires User Confirmation

**ALWAYS ask the user before:**
- Installing global packages (`npm i -g`, `pip install` without venv)
- Modifying shell config (`.bashrc`, `.zshrc`, `.profile`)
- Installing/configuring MCP servers
- Modifying Claude Code settings (`settings.json`, `CLAUDE.md` at user level)
- Running `sudo` commands
- Creating/modifying Docker containers
- Changing Python/Node versions (pyenv, nvm)
- Modifying system PATH

**OK to do automatically:**
- `uv sync` / `npm install` / `pip install` in venv (project-level dependencies)
- Creating virtual environments
- Running tests
- Git operations (commit, branch, checkout — not force-push)
- Creating project-level config files
- Reading any files

## Configuration Hot-Reload Reference

When inner Claude is developing plugins/skills/MCP, know what needs a restart:

| Change | Needs claude restart? | How to apply |
|--------|----------------------|-------------|
| Edit CLAUDE.md | No | Auto-loaded on next read |
| Edit SKILL.md (`--add-dir`) | No | Hot-reloaded |
| Install plugin | No | `/reload-plugins` |
| Edit plugin code | No | `/reload-plugins` |
| Add MCP server | **Yes** | Exit claude, restart |
| Edit `.mcp.json` | **Yes** | Exit claude, restart |
| Change `settings.json` | **Yes** | Exit claude, restart |
| Change permissions | **Yes** | Exit claude, restart |

### Restarting inner Claude after config change
```bash
# Record the change in env-changes.md first
# Then restart:
tmux send-keys -t "cc-use-inner" "/exit" Enter
sleep 3
tmux send-keys -t "cc-use-inner" "claude <permission-flags>" Enter
sleep 5
# Send context about what was being worked on
tmux send-keys -t "cc-use-inner" "Continue: <brief task description>" Enter
```

## Rollback on Completion

When the task is done, review `.cc-use/state/env-changes.md`:

1. **Auto-revertible**: project-level config files, MCP servers (project scope)
2. **Ask user**: global packages, system config, user-level settings
3. **No revert needed**: project dependencies, git changes, created source files

Report all changes to the user and let them decide what to keep vs revert.
