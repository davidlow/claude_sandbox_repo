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
| `.claude/skills/` | Native Claude Code skills: `brainstorm`, `decide`, `implement`, `geminiapi`, `logging`, `architect`, `qa`, `refactor` |
| `.claude/commands/` | Slash-command aliases for every skill |
| `.claude/settings.json` | Project-level tool permissions for skills |
| `tests/run_tests.sh` | Test runner — `--unit` (no Docker) or `--int` (full integration) |
| `tests/test_*.sh` | Unit tests for bash functions + integration tests |
| `tests/fixtures/` | Fake credential JSON files used by unit tests |
| `docs/decisions/` | Timestamped decision logs written by the pipeline skills |
| `legacy/` | Old bash pipeline scripts (superseded by skills) |
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

```
/architect "add a plugin system to the CLI"
/architect "design a caching layer for the database" --no-gemini
```

**Phases:**
1. **Brainstorm** (haiku, isolated) — generates 3 distinct architectural approaches → `docs/architecture_candidates.md`
2. **Gemini critique** (optional) — adversarial review of all three candidates → `docs/gemini_architectural_audit.md`
3. **Decide** (sonnet, isolated) — selects the best option, writes spec → `docs/approved_architecture.md`
4. **Implement** (isolated) — builds exactly what the spec says, runs tests

#### `/qa <scope> [--no-gemini]`

Adversarial test generation — use when building or hardening a test suite.

```
/qa "write tests for the payments module"
/qa "add integration tests for the REST API" --no-gemini
```

**Phases:**
1. **Generate** (isolated) — writes comprehensive tests, runs them, fixes failures
2. **Gemini red-team audit** (optional) — scans all source and test files for edge cases, boundary conditions, race conditions → `tests/gemini_missing_coverage.md`
3. **Remediate** (isolated) — implements every missing test case from the Gemini audit, verifies all pass

#### `/refactor <task> [--no-gemini]`

Bug fix and refactoring pipeline — use for fixing bugs or reducing technical debt.

```
/refactor "fix the race condition in the job queue"
/refactor "reduce coupling in the user service" --no-gemini
```

**Phases:**
1. **Diagnose** (haiku, isolated) — analyzes the problem and proposes 3 options (minimal patch / structural fix / rewrite) → `docs/refactor_candidates.md`
2. **Decide** (sonnet, isolated) — selects the best approach, writes a step-by-step plan → `docs/approved_fix.md`
3. **Implement** (isolated) — applies the fix, runs tests; if tests fail and Gemini is enabled, calls Gemini for circuit-breaker diagnosis

### Phase Isolation

Skills use `context: fork` — each phase spawns a completely fresh subagent with no memory of prior phase conversations. Phases share data only through files written to `docs/` and `tests/`. This prevents cognitive anchoring (an LLM fixating on its first idea) without needing separate Docker containers.

### Decision Logs

Every orchestrator run writes a timestamped decision log to `docs/decisions/YYYYMMDD_HHMM_<slug>_<pipeline>.md`. These logs capture what was attempted, which option was chosen, and whether it succeeded. Later `/decide` runs read past logs to avoid repeating failed approaches.

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

---

## Legacy Bash Pipelines

The original bash pipeline scripts (`launch-architect.sh`, `launch-qa.sh`, `launch-refactor.sh`, `launch-dispatch.sh`, `run-pipeline.sh`) have been superseded by the native Claude Code skills above. They are preserved in `legacy/` for reference.
