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

| File | Purpose |
|---|---|
| `Dockerfile.claude` | Debian image: Node 20, Python venv, Claude Code native install |
| `entrypoint.sh` | Restores `~/.claude.json` into the container home on every start; saves it back on exit |
| `install.sh` | One-time setup: installs Docker, builds image, registers shell aliases |
| `setup-auth.sh` | One-time auth bootstrap: copies config and warms up Claude's first-run state |
| `launch-interactive.sh` | `claude-box` — interactive Claude Code session |
| `launch-scripted.sh` | `claude-yolo` — autonomous mode with rate-limit auto-recovery and Gemini audit |
| `lib/launch-lib.sh` | Pure helper functions sourced by `launch-scripted.sh` and the test suite |
| `tests/run_tests.sh` | Test runner — `--unit` (no Docker) or `--int` (full integration) |
| `tests/test_*.sh` | Unit tests for bash functions + integration tests |
| `tests/fixtures/` | Fake credential JSON files used by unit tests |

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
- Register three shell aliases in `~/.bashrc`: `claude-box`, `claude-yolo`, `claude-box-auth`

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

Drops you into a full Claude Code session. Claude asks for permission before making changes.

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

**Rate limit handling:** if Claude Pro's token quota is exhausted mid-task, `claude-yolo` detects the reset time from the error message, prints a countdown every 5 minutes, then resumes automatically — no intervention needed.

**Recovery strategies:** on timeout or failure, `claude-yolo` tries three escalating strategies before giving up:
- **Strategy A** — pipes `/compact` to Claude Code to summarise the conversation history in-place, then resumes
- **Strategy B+C** — asks Claude to write a `.task_handoff.md` checkpoint, wipes the bloated session, then starts fresh with the handoff context injected into the next prompt

**Context bootstrap:** if `CLAUDE.md` is absent from your project root, `claude-yolo` generates it automatically before starting the main task.

---

## Multi-Stage Pipelines

Three higher-level commands that physically separate brainstorming, evaluation, and implementation into isolated containers. The `.claude/` session directory is wiped between phases so each model starts with a fresh context — preventing the "cognitive anchoring" where an LLM fixates on its first idea.

| Command | When to use | Phases |
|---|---|---|
| `claude-architect` | New features, greenfield design | Haiku brainstorms 3 approaches → Gemini critique → Sonnet picks one → Sonnet implements |
| `claude-qa` | Building or hardening a test suite | Sonnet writes + fixes tests → Gemini adversarial audit → Sonnet adds missing coverage |
| `claude-refactor` | Bug fixes, reducing technical debt | Haiku diagnoses + proposes 3 options → Sonnet picks one → Sonnet implements + verifies |

### `claude-architect`

```bash
claude-architect "add a plugin system to the CLI"
claude-architect "design a caching layer for the database" claude-opus-4-8
claude-architect "redesign the auth module" --no-gemini
```

Writes intermediate artifacts to `docs/` for review: `architecture_candidates.md` (three approaches), `gemini_architectural_audit.md` (Gemini critique, if enabled), and `approved_architecture.md` (the chosen spec).

### `claude-qa`

```bash
claude-qa "write tests for the payments module"
claude-qa "add integration tests for the REST API" claude-opus-4-8
claude-qa "test the file upload handler" --no-gemini
```

With `GEMINI_API_KEY` set, Gemini acts as an adversarial Red Team reviewer after Phase 1: it scans the codebase and test files to find edge cases, boundary conditions, and race conditions that the initial suite misses. Findings are saved to `tests/gemini_missing_coverage.md` and Phase 2 implements them all.

### `claude-refactor`

```bash
claude-refactor "fix the race condition in the job queue"
claude-refactor "reduce coupling in the user service" claude-opus-4-8
claude-refactor "the payment processor fails on retry" --no-gemini
```

Intermediate artifacts in `docs/`: `refactor_candidates.md` (three options: minimal patch, structural fix, module rewrite) and `approved_fix.md` (chosen plan). In Phase 3, Gemini acts as a circuit-breaker on failure — if Claude's implementation attempt fails, Gemini diagnoses the logical flaw before each retry.

---

## Gemini Cross-Model Audit

When a task fails or times out, `claude-yolo` can send the failure context (task objective, `CLAUDE.md`, git diff, last 100 lines of output) to **Gemini 2.5 Flash** for an independent architectural analysis. The advice is saved to `GEMINI_ADVICE.md` and prepended to the next retry prompt.

To enable, export your Google AI Studio key before running:

```bash
export GEMINI_API_KEY="your-key-here"
claude-yolo "your task"
```

To disable for a single run even if the key is set:

```bash
claude-yolo "your task" --no-gemini
```

`GEMINI_ADVICE.md` is kept on disk after a final failure for your review, and cleaned up automatically on success.

---

## Model Tiers

`claude-yolo` enforces per-model resource budgets to control costs:

| Model | Timeout | Max retries | Context tokens | Thinking tokens |
|---|---|---|---|---|
| `claude-haiku-4-5` | 15 min | 3 | 50 000 | — |
| `claude-sonnet-4-6` (default) | 10 min | 3 | 80 000 | 10 000 |
| `claude-opus-4-8` | 5 min | 2 | 120 000 | 24 000 |
| `claude-fable-5` | 4 min | 2 | 120 000 | — |

Unknown model names fall back to the Sonnet defaults.

---

## When Your Session Expires

Claude Pro sessions have a lifetime. When they expire, re-authenticate on the host and re-run the bootstrap:

```bash
claude auth login --claudeai   # browser login on the host
claude-box-auth                # re-copy config into the container mount
```

---

## Updating Claude Code

Claude Code's native install inside the image supports auto-updates, but since containers are ephemeral those updates are lost on exit. To pick up a new version permanently, rebuild the image:

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

Unit tests cover the pure bash functions in `lib/launch-lib.sh` (argument parsing, model tier selection, rate-limit detection, prompt composition, etc.) and can be run anywhere without any external dependencies.

---

## Safe Usage Notes

- **Commit before `claude-yolo`** — the container has full read/write access to your project directory. Stash or commit your work first.
- **Rate limits** — `claude-yolo` handles Pro rate limits automatically, but very long tasks may exhaust multiple quota windows.
- **`~/.claude` is shared** — the container reads and writes to your host's `~/.claude/` directory, so session history is shared between your host Claude Code and the sandbox.
