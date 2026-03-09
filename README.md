# cc-use

A Claude Code skill that lets an outer Claude supervise an inner Claude running in tmux — offloading implementation work to keep the outer context lean for long-running task management.

## What It Does

```
Outer Claude (you, in .cc-use/)          Inner Claude (in tmux, in project root)
├── Task planning                        ├── Read/write code
├── Progress monitoring (tmux output)    ├── Run tests
├── Context management (/compact, etc)   ├── Debug issues
├── End-to-end acceptance testing        └── All the heavy lifting
└── Report results to user
```

**Why?** A single Claude session accumulates all file reads, edits, and command outputs in its context window. With cc-use, the inner Claude handles all that detail work. The outer Claude only sees summaries (~40 lines at a time), so it can manage much longer workflows without running out of context.

## Install

```bash
npx skills add zc277584121/cc-use
```

Or manually:
```bash
mkdir -p ~/.claude/skills/cc-use
cp -r skills/cc-use/* ~/.claude/skills/cc-use/
```

## Usage

```bash
# From your project directory
mkdir -p .cc-use
cd .cc-use && claude
```

Then tell Claude your goal. The skill will guide it to:
1. Ask your preferred permission mode for the inner Claude
2. Launch an inner Claude in tmux
3. Monitor progress and steer as needed
4. Run acceptance tests (automated + browser-based)
5. Report results

## Key Features

- **Context efficiency**: Inner Claude's tool calls don't enter outer context
- **Incremental monitoring**: Read only new output via pipe-pane log tracking
- **Inner context management**: Send `/compact`, `/clear`, `/model` to inner Claude via tmux
- **Environment tracking**: Records all system-level changes for rollback
- **Browser verification**: Supports agent-browser for end-to-end UI testing

## Requirements

- `tmux` installed
- `claude` CLI (Claude Code) installed
- (Optional) `agent-browser` for browser-based acceptance testing

## License

MIT
