# Acceptance Testing

## Testing Levels

### Level 1: Automated Tests (run these first)

Run the project's existing test suite from the project directory:

```bash
# Python
cd <project_dir> && pytest
cd <project_dir> && python -m pytest tests/ -v

# Node.js
cd <project_dir> && npm test
cd <project_dir> && npx jest

# Rust
cd <project_dir> && cargo test

# Go
cd <project_dir> && go test ./...
```

Also run linters and type checkers if configured:
```bash
# Python
cd <project_dir> && mypy .
cd <project_dir> && ruff check .

# TypeScript
cd <project_dir> && npx tsc --noEmit

# ESLint
cd <project_dir> && npx eslint .
```

### Level 2: Browser-Based Verification

For web applications, use **agent-browser** for end-to-end verification.

#### Prerequisites check
```bash
which agent-browser
```

If not available, tell the user:
> "Browser verification needs agent-browser. Install with:
> ```bash
> npm install -g agent-browser
> agent-browser install
> npx skills add vercel-labs/agent-browser
> ```"

#### Basic browser verification workflow
```bash
# 1. Open the target page
agent-browser open http://localhost:3000

# 2. Get interactive elements
agent-browser snapshot -i

# 3. Interact with elements (using refs from snapshot)
agent-browser fill @e1 "test@example.com"
agent-browser click @e2

# 4. Take screenshot for visual verification
agent-browser screenshot .cc-use/logs/verification.png

# 5. Read the screenshot to verify visually
# (use the Read tool on the png file)

# 6. Close when done
agent-browser close
```

#### Common verification patterns

**Form submission**:
```bash
agent-browser open http://localhost:3000/login
agent-browser snapshot -i
agent-browser fill @e1 "user@test.com"
agent-browser fill @e2 "password123"
agent-browser click @e3  # submit button
agent-browser snapshot -i  # check result
agent-browser screenshot .cc-use/logs/login-result.png
```

**Navigation flow**:
```bash
agent-browser open http://localhost:3000
agent-browser snapshot -i
agent-browser click @e5  # navigate to a page
agent-browser snapshot -i  # verify new page content
```

**API response check**:
```bash
# Use curl for API endpoints
curl -s http://localhost:3000/api/health | python3 -m json.tool
curl -s -X POST http://localhost:3000/api/users -H "Content-Type: application/json" -d '{"name":"test"}'
```

### Level 3: Visual Regression (optional)

Take before/after screenshots and compare:
```bash
# Before (save reference)
agent-browser screenshot .cc-use/logs/before.png

# After changes
agent-browser screenshot .cc-use/logs/after.png

# Read both screenshots and compare visually
```

## Acceptance Checklist

Before reporting completion to the user:

- [ ] All existing tests pass
- [ ] New functionality works as specified
- [ ] No regressions in existing features
- [ ] UI looks correct (if applicable, via screenshots)
- [ ] Error cases handled appropriately
- [ ] No security issues introduced (check for hardcoded secrets, injection points)
