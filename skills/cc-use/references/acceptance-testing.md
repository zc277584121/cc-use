# Acceptance Testing

## Core Philosophy

**You are the user, not the developer.**

- Treat the project as a **black box** — do NOT read source code for verification
- You MAY read: documentation, README, API docs, user guides, config examples
- Use **real environments and real data**, not mocks or test fixtures
- Test **end-to-end**: actually run commands, call APIs, click buttons, fill forms
- If fixing a bug, **reproduce the bug first** before checking the fix

## For Bug Fixes: Reproduce First

Before verifying the fix, confirm the bug existed:

1. Read the issue description / TODO to understand the reported behavior
2. Reproduce it end-to-end — actually trigger the bug with real operations
3. If you can't reproduce it, tell the inner Claude — the fix may be wrong

```
Example flow for an MCP server bug:
1. Start the MCP server
2. Connect a client
3. Call the tool that was reported broken
4. Observe the actual error / wrong behavior
5. After fix: repeat the same steps, verify correct behavior
```

## End-to-End Verification

### CLI tools / Libraries
```bash
# Actually USE the tool the way a real user would
cd <project_dir> && <the command users run>

# Feed it real inputs
echo "real data" | <tool>
<tool> --input real-file.json

# Check real outputs — don't grep source code for correctness
```

### APIs / Servers
```bash
# Actually start the server and hit endpoints
cd <project_dir> && <start command> &
sleep 3

# Real HTTP requests
curl -s http://localhost:3000/api/endpoint | python3 -m json.tool
curl -s -X POST http://localhost:3000/api/resource \
  -H "Content-Type: application/json" \
  -d '{"field": "real value"}'
```

### MCP Servers
```bash
# Connect and call tools — don't just check if it compiles
# Start the server, verify tools are listed, call them with real data
```

### Web Applications (requires agent-browser)
```bash
which agent-browser || echo "Install: npm i -g agent-browser && agent-browser install"

agent-browser open http://localhost:3000
agent-browser snapshot -i
agent-browser fill @e1 "real test data"
agent-browser click @e2
agent-browser screenshot .cc-use/logs/verification.png
# Read the screenshot to visually verify
agent-browser close
```

## Edge Case Coverage

Don't just test the happy path. For each, do a real end-to-end test:

| Edge case | What to test |
|-----------|-------------|
| **Empty inputs** | Pass empty strings, empty files, no arguments |
| **Null / missing** | Omit required fields, use null values |
| **Large inputs** | Big files, long strings, many records |
| **Special characters** | Unicode, quotes, newlines, SQL-injection-like strings |
| **Invalid inputs** | Wrong types, malformed data, out-of-range values |
| **Boundary values** | 0, -1, MAX_INT, empty array vs single-element array |
| **Concurrent use** | Multiple requests at once, race conditions |
| **Service failures** | What if DB is down? What if network times out? |

Each of these should be tested by **actually doing it**, not by reading code to see if there's a check.

## Run Existing Test Suite (Supplementary)

After your end-to-end verification, also run the project's tests as a sanity check:

```bash
cd <project_dir> && pytest        # Python
cd <project_dir> && npm test      # Node.js
cd <project_dir> && cargo test    # Rust
cd <project_dir> && go test ./... # Go
```

Also linters / type checks:
```bash
cd <project_dir> && mypy .           # Python types
cd <project_dir> && npx tsc --noEmit # TypeScript types
cd <project_dir> && ruff check .     # Python lint
```

**Remember**: passing unit tests does NOT replace end-to-end verification. Unit tests can pass while the actual user experience is broken.

## Acceptance Checklist

Before reporting completion to the user:

- [ ] Bug was reproducible before the fix (for bug fixes)
- [ ] Fix resolves the issue end-to-end (not just in unit tests)
- [ ] Happy path works with real data
- [ ] Edge cases tested end-to-end (empty, null, large, invalid, special chars)
- [ ] No regressions in existing functionality
- [ ] UI looks correct (if applicable, via screenshots)
- [ ] Existing test suite still passes
