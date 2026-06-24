# Claude Code Docker Sandbox

A lightweight Docker sandbox for running Anthropic's Claude Code CLI using a **Claude Pro subscription** (no API key required). Designed for **Debian Linux** and **ChromeOS Linux (Crostini)**.

---

## How it Works

Claude Code runs inside an ephemeral Debian container that:

- **Sees only your project** — the current directory is bind-mounted as `/workspace`; the rest of your filesystem is invisible
- **Uses your host credentials** — `~/.claude` is mounted read/write so the container uses the same Claude Pro session as your host install
- **Destroys itself on exit** — `--rm` ensures every run starts from a pristine state
- **Matches host UIDs** — the container user is pinned to UID 1000, avoiding file permission mismatches on Debian and Crostini

### Authentication

OAuth tokens are extracted from `~/.claude/.credentials.json` and injected as `CLAUDE_CODE_OAUTH_TOKEN` / `CLAUDE_CODE_OAUTH_REFRESH_TOKEN` at launch. This bypasses Claude Code's first-run browser auth wizard so you drop straight into the chat.

---

## Repository Structure

| File / Directory | Purpose |
|---|---|
| `Dockerfile.claude` | Debian image: Node 20, Python venv, Claude Code native install |
| `entrypoint.sh` | Restores `~/.claude.json` into the container home on every start; saves it back on exit |
| `install.sh` | One-time setup: installs Docker, builds image, registers shell aliases |
| `setup-auth.sh` | One-time auth bootstrap: copies config and warms up Claude's first-run state |
| `launch-interactive.sh` | `claude-box` — interactive Claude Code session |
| `launch-scripted.sh` | `claude-yolo` — autonomous mode with rate-limit auto-recovery and Gemini audit |
| `lib/launch-lib.sh` | Pure helper functions sourced by `launch-scripted.sh` and the test suite |
| `.claude/skills/` | Native Claude Code skills: `gm`, `architect`, `brainstorm`, `decide`, `implement`, `qa`, `refactor`, `geminiapi`, `logging` |
| `.claude/commands/` | Slash-command aliases for every skill |
| `.claude/settings.json` | Project-level tool permissions for skills |
| `tests/run_tests.sh` | Test runner — `--unit` (no Docker) or `--int` (full integration) |
| `tests/test_*.sh` | Unit tests for bash functions + integration tests |
| `tests/fixtures/` | Fake credential JSON files used by unit tests |
| `docs/decisions/` | Timestamped decision logs written by the pipeline skills |
| `docs/skills-and-commands-overview.md` | Full technical reference for all skills and commands |
| `legacy/` | Old bash pipeline scripts (superseded by skills) |
| `tasks.md` | Example task list for `/gm` to execute autonomously |
| `.env.local.example` | Template for local API keys (copy to `.env.local`, which is gitignored) |

---

## Prerequisites

- A **Claude Pro** (or Max/Team/Enterprise) subscription — log in on your host with `claude auth login --claudeai` before running setup
- **Docker** (installed automatically by `install.sh` if missing)
- **Debian Linux** or **ChromeOS Linux (Crostini)**

---

## Installation

### 1. Clone and run the installer

```bash
git clone <your-repository-url> ~/claude-sandbox-repo
cd ~/claude-sandbox-repo
./install.sh
```

`install.sh` will:
- Install Docker if not present
- Build the `claude-sandbox` Docker image
- Register shell aliases in `~/.bashrc`: `claude-box`, `claude-yolo`, `claude-box-auth`

### 2. Reload your shell

- **Chromebook:** Right-click the Terminal icon → "Shut down Linux" → reopen Terminal
- **Debian:** `source ~/.bashrc` or open a new terminal

### 3. Bootstrap credentials (one time only)

You must already be logged into Claude Code on the host (`claude auth login --claudeai`). Then:

```bash
claude-box-auth
```

This copies `~/.claude.json` into `~/.claude/` for the container to find, and runs a quick bootstrap call to pre-populate Claude's first-run config state. You only need to do this once, or after re-installing Claude Code.

---

## Daily Usage

Navigate to **any project directory**, then run either command.

### Interactive mode — `claude-box`

Drops you into a full Claude Code session. Use it for manual interaction or to run the pipeline skills (see below).

```bash
cd ~/my-project
claude-box                        # default model (claude-sonnet-4-6)
claude-box claude-opus-4-8        # override model
claude-box claude-fable-5         # Fable model
```

### Autonomous mode — `claude-yolo`

Give Claude a task and walk away. It runs with `--dangerously-skip-permissions`, handles timeouts, compacts context when needed, and automatically waits out Claude Pro rate limits.

```bash
cd ~/my-project
claude-yolo "run the test suite and fix any failures"
claude-yolo "refactor the auth module for readability" claude-opus-4-8
claude-yolo "add input validation to all API endpoints" claude-haiku-4-5
claude-yolo "migrate the database schema" --no-gemini
```

**Rate limit handling:** if Claude Pro's token quota is exhausted mid-task, `claude-yolo` detects the reset time from the error message, prints a countdown every 5 minutes, then resumes automatically.

**Recovery strategies:** on timeout or failure, `claude-yolo` tries three escalating strategies:
- **Strategy A** — pipes `/compact` to Claude Code to summarise the conversation in-place, then resumes
- **Strategy B+C** — asks Claude to write a `.task_handoff.md` checkpoint, wipes the bloated session, then starts fresh with the handoff context injected

**Context bootstrap:** if `CLAUDE.md` is absent from your project root, `claude-yolo` generates it automatically before starting the main task.

---

## Pipeline Skills

Inside a `claude-box` session, a set of composable skills and slash commands turn Claude Code into a structured multi-phase pipeline engine. Each skill phase runs in an isolated subagent (`context: fork`) with a fresh context window — preventing the cognitive anchoring that comes from carrying one phase's reasoning into the next.

### General Manager — `/gm` (hands-off engine)

The top-level orchestrator. Give it a task list or a free-text prompt; it decomposes the work, creates a **git branch per task**, invokes the right pipeline skill for each one, and merges to the base branch only when all tests pass. Failed branches are left alive for manual inspection.

```bash
# Inside claude-box:

/gm "add user authentication with JWT tokens and refresh logic"

/gm --tasks tasks.md                             # run every unchecked item in tasks.md
/gm --tasks tasks.md --qa                        # + adversarial QA layer before each merge
/gm --tasks tasks.md --no-gemini                 # skip Gemini cross-model audits
/gm "Fix: broken pagination; Add: CSV export; QA: test the reporting module"
```

**What it does per task:**
1. Creates `gm/YYYYMMDD-HHMM-<slug>` branch from the current base
2. Detects task type → routes to `/architect`, `/refactor`, or `/qa`
3. With `--qa`: runs `/qa` as a second adversarial test pass after the primary skill passes
4. On success: `git merge --no-ff` to base, marks the `tasks.md` checkbox `[x]`
5. On failure: leaves the branch alive, continues to the next task

**Type detection:**

| Prefix / keyword | Skill invoked |
|---|---|
| `Fix:`, `Bug:`, `Hotfix:`, starts with "fix/patch/repair/debug" | `/refactor` |
| `QA:`, `Test:`, `Coverage:`, starts with "test/write tests" | `/qa` |
| Everything else | `/architect` |

### Building Blocks

Use these individually for manual step-by-step control, or let the orchestrators call them automatically.

| Skill / Command | What it does |
|---|---|
| `/brainstorm [architect\|refactor] <task>` | Haiku generates 3 distinct approaches → `docs/architecture_candidates.md` or `docs/refactor_candidates.md` |
| `/decide [architect\|refactor] <task>` | Sonnet evaluates candidates, picks the best, writes spec → `docs/approved_architecture.md` or `docs/approved_fix.md` |
| `/implement [architect\|refactor\|<task>]` | Executes an approved spec or a direct task, then runs tests |
| `/geminiapi [architect-critique\|qa-audit\|refactor-diagnosis\|dispatch] <task>` | Sends context to Gemini for cross-model audit; bridges to `lib/launch-lib.sh` |
| `/logging [init\|section\|note\|outcome\|read] ...` | Manages `docs/decisions/` decision logs for the audit trail |

### Orchestrators

These run all phases end-to-end. Pass `--no-gemini` to skip the Gemini audit step.

#### `/architect <task> [--no-gemini]`

Full architectural design pipeline — use for new features or significant design decisions.

```bash
/architect "add a plugin system to the CLI"
/architect "design a caching layer for the database" --no-gemini
/architect "migrate from REST to GraphQL"
/architect "add real-time notifications via WebSocket"
```

**Phases:**
1. **Brainstorm** (haiku, isolated) — generates 3 distinct architectural approaches → `docs/architecture_candidates.md`
2. **Gemini critique** (optional) — adversarial review of all three candidates → `docs/gemini_architectural_audit.md`
3. **Decide** (sonnet, isolated) — selects the best option, writes spec → `docs/approved_architecture.md`
4. **Implement** (isolated) — builds exactly what the spec says, runs tests

#### `/qa <scope> [--no-gemini]`

Adversarial test generation — use when building or hardening a test suite.

```bash
/qa "write tests for the payments module"
/qa "add integration tests for the REST API" --no-gemini
/qa "achieve 80% coverage on the user service"
/qa "test edge cases for the CSV parser"
```

**Phases:**
1. **Generate** (isolated) — writes comprehensive tests, runs them, fixes failures
2. **Gemini red-team audit** (optional) — scans all source and test files for edge cases, boundary conditions, race conditions → `tests/gemini_missing_coverage.md`
3. **Remediate** (isolated) — implements every missing test case from the Gemini audit, verifies all pass

#### `/refactor <task> [--no-gemini]`

Bug fix and refactoring pipeline — use for fixing bugs or reducing technical debt.

```bash
/refactor "fix the race condition in the job queue"
/refactor "reduce coupling in the user service" --no-gemini
/refactor "eliminate N+1 query in the orders endpoint"
/refactor "fix memory leak in the file upload handler"
```

**Phases:**
1. **Diagnose** (haiku, isolated) — analyzes the problem and proposes 3 options → `docs/refactor_candidates.md`
2. **Decide** (sonnet, isolated) — selects the best approach, writes a step-by-step plan → `docs/approved_fix.md`
3. **Implement** (isolated) — applies the fix, runs tests; if tests fail and Gemini is enabled, calls Gemini for circuit-breaker diagnosis

### Phase Isolation

Skills use `context: fork` — each phase spawns a completely fresh subagent with no memory of prior phase conversations. Phases share data only through files written to `docs/` and `tests/`. This prevents cognitive anchoring (an LLM fixating on its first idea) without needing separate Docker containers.

### Decision Logs

Every orchestrator run writes a timestamped decision log to `docs/decisions/YYYYMMDD_HHMM_<slug>_<pipeline>.md`. These logs capture what was attempted, which option was chosen, and whether it succeeded. Later `/decide` runs read past logs to avoid repeating failed approaches.

---

## Examples

### Interactive examples (`claude-box`)

Start a session, then type any of these at the Claude Code prompt:

```bash
cd ~/my-python-api
claude-box

# --- inside the claude-box session ---

# Design and build a new feature end-to-end
/architect "add OAuth2 social login (Google + GitHub)"

# Fix a known bug with three proposed solutions to choose from
/refactor "fix: users can bypass rate limiting by rotating IPs"

# Generate a hardened test suite with Gemini red-teaming the gaps
/qa "write comprehensive tests for the authentication module"

# Run the full task list from tasks.md, one branch per task
/gm --tasks tasks.md

# Run task list with an extra adversarial QA pass before each merge
/gm --tasks tasks.md --qa

# Decompose a free-text brief into tasks and execute all of them
/gm "add pagination to the API, add request logging middleware, fix the broken CSV export"

# Step-by-step manual pipeline: brainstorm → you review → decide → implement
/brainstorm architect "replace synchronous job processing with a queue"
# (review docs/architecture_candidates.md, edit if needed)
/decide architect "replace synchronous job processing with a queue"
# (review docs/approved_architecture.md)
/implement architect

# Just implement a spec you already wrote at docs/approved_architecture.md
/implement architect

# Get a Gemini second opinion on a set of candidates you already brainstormed
/geminiapi architect-critique "add a plugin system"

# View the decision log from the last architect run
/logging read architect
```

### Autonomous examples (`claude-yolo`)

These run entirely without you — `claude-yolo` passes the task to Claude and manages rate limits, retries, and Gemini audits automatically.

```bash
# ----- Bug fixes -----

# Fix failing tests and commit the result
claude-yolo "run the test suite, diagnose every failure, fix them, and commit"

# Fix a specific reported bug
claude-yolo "Fix: the /export endpoint returns 500 when the date range spans a DST boundary"

# Fix performance — profile, identify bottleneck, patch
claude-yolo "the search endpoint takes >2s on datasets over 10k rows — find and fix the bottleneck"


# ----- New features -----

# Build a new feature with full architectural pipeline
claude-yolo "/architect add webhook support so external services can subscribe to order events"

# Add an endpoint and its tests in one pass
claude-yolo "/architect add a GET /users/:id/activity endpoint that returns paginated audit logs"

# Add a new CLI command
claude-yolo "/architect add a --dry-run flag to the migration command"


# ----- Test coverage -----

# Harden an existing module's tests
claude-yolo "/qa write comprehensive tests for the billing module, targeting 90% line coverage"

# Red-team the auth system
claude-yolo "/qa test the authentication module for token expiry edge cases, concurrent session handling, and brute-force scenarios"

# Add contract tests between services
claude-yolo "/qa add contract tests between the orders service and the inventory service"


# ----- Refactoring -----

# Extract shared logic and clean up coupling
claude-yolo "/refactor extract the duplicated database retry logic into a shared helper in lib/"

# Modernize an old module
claude-yolo "/refactor migrate the user service from callbacks to async/await"

# Reduce memory usage
claude-yolo "/refactor the batch processor loads entire datasets into memory — refactor to stream in chunks"


# ----- Multi-task with /gm (fully hands-off) -----

# Run every unchecked item in tasks.md autonomously, one branch per task
claude-yolo "/gm --tasks tasks.md"

# Same, but with adversarial QA before every merge
claude-yolo "/gm --tasks tasks.md --qa"

# Give a free-text brief; gm decomposes it into tasks and runs them all
claude-yolo "/gm add JWT authentication, add request-rate limiting, write tests for both, fix the broken logout endpoint"

# Skip Gemini (faster, cheaper for prototyping)
claude-yolo "/gm --tasks tasks.md --no-gemini"


# ----- With model overrides -----

# Use Haiku for fast/cheap tasks
claude-yolo "add docstrings to every public function in src/" claude-haiku-4-5

# Use Opus for deep architectural work
claude-yolo "/architect redesign the data pipeline to handle 10x throughput" claude-opus-4-8

# Use Fable for creative/generative tasks
claude-yolo "write the user-facing help text and error messages for all CLI commands" claude-fable-5


# ----- Compound / multi-step -----

# Audit security, fix issues, write regression tests, all in one command
claude-yolo "audit src/ for SQL injection and XSS vulnerabilities, fix every instance you find, then write regression tests that would catch them"

# Migrate and verify
claude-yolo "migrate the ORM models from SQLAlchemy 1.x to 2.0 style, update all queries, and make sure the test suite still passes"

# Build + document
claude-yolo "/architect add a plugin API, then update README.md with usage examples and the plugin contract"
```

### Using `tasks.md` for batch work

Create a `tasks.md` in your project root and run `/gm --tasks tasks.md` (or `claude-yolo "/gm --tasks tasks.md"`) to execute the whole list hands-off. The GM checks off each task as it merges.

```markdown
# Sprint tasks

- [ ] Add: user profile photo upload with S3 storage
- [ ] Add: email verification on signup
- [ ] Fix: password reset link expires too quickly (currently 5 min, should be 24 h)
- [ ] Fix: duplicate notification emails sent on concurrent logins
- [ ] QA: write tests for the file upload pipeline
- [ ] QA: test email sending with invalid addresses and bounces
```

Each item becomes its own git branch (`gm/YYYYMMDD-HHMM-<slug>`). Successful items are merged and checked off; failed items are left on their branches for you to inspect.

#### Checking progress mid-run

`/gm` writes `gm-status.md` to your project root after every task. While it's running under `claude-yolo`, open a second terminal in the same directory:

```bash
cat gm-status.md                         # live task table — updates after each task completes
cat docs/decisions/*gm*.md | tail -40    # decision log: branch created, skill outcome, merge/fail events
ls gm/ 2>/dev/null || git branch | grep gm/  # see what branches exist so far
```

All pipeline skills (`/architect`, `/qa`, `/refactor`) also write timestamped decision logs to `docs/decisions/` throughout their runs:

```bash
ls -lt docs/decisions/                   # most recent first
cat docs/decisions/<latest>.md           # full log for a single run
```

---

## Gemini Cross-Model Audit

When `claude-yolo` tasks fail or time out, it sends the failure context (task objective, `CLAUDE.md`, git diff, last 100 lines of output) to **Gemini Flash** for an independent architectural analysis. The advice is saved to `GEMINI_ADVICE.md` and prepended to the next retry prompt.

Inside `claude-box`, the `/geminiapi` skill provides the same capability on demand.

### Setting up your Gemini API key (recommended)

```bash
cp .env.local.example .env.local
# edit .env.local and replace "your-key-here" with your actual key
```

`.env.local` is gitignored and sourced automatically by `claude-yolo` — no manual `export` needed. Get a free key at [Google AI Studio](https://aistudio.google.com/apikey).

To disable for a single `claude-yolo` run:

```bash
claude-yolo "your task" --no-gemini
```

---

## Model Tiers

`claude-yolo` enforces per-model resource budgets:

| Model | Timeout | Max retries | Context tokens | Thinking tokens |
|---|---|---|---|---|
| `claude-haiku-4-5` | 15 min | 3 | 50 000 | — |
| `claude-sonnet-4-6` (default) | 10 min | 3 | 80 000 | 10 000 |
| `claude-opus-4-8` | 5 min | 2 | 120 000 | 24 000 |
| `claude-fable-5` | 4 min | 2 | 120 000 | — |

Unknown model names fall back to the Sonnet defaults.

---

## When Your Session Expires

```bash
claude auth login --claudeai   # browser login on the host
claude-box-auth                # re-copy config into the container mount
```

---

## Updating Claude Code

Claude Code auto-updates are lost when ephemeral containers exit. To pick up a new version permanently:

```bash
cd ~/claude-sandbox-repo
docker build -t claude-sandbox -f Dockerfile.claude .
```

---

## Running Tests

```bash
./tests/run_tests.sh            # all tests (unit + integration)
./tests/run_tests.sh --unit     # unit tests only — no Docker or credentials needed
./tests/run_tests.sh --int      # integration tests only — requires Docker + credentials
```

---

## Safe Usage Notes

- **Commit before `claude-yolo`** — the container has full read/write access to your project directory. Stash or commit your work first.
- **Rate limits** — `claude-yolo` handles Pro rate limits automatically, but very long tasks may exhaust multiple quota windows.
- **`~/.claude` is shared** — the container reads and writes to your host's `~/.claude/` directory, so session history is shared between your host Claude Code and the sandbox.
- **Failed branches are safe** — `/gm` never deletes a failed branch. Run `git branch | grep gm/` to list them, `git checkout <branch>` to inspect, `git branch -D <branch>` to discard.

---

## Legacy Bash Pipelines

The original bash pipeline scripts (`launch-architect.sh`, `launch-qa.sh`, `launch-refactor.sh`, `launch-dispatch.sh`, `run-pipeline.sh`) have been superseded by the native Claude Code skills above. They are preserved in `legacy/` for reference.
