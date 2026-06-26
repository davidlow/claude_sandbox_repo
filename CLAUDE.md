# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Purpose

A Docker sandbox that lets you run Claude Code autonomously using a Claude Pro OAuth session (no API key). Designed for Debian Linux and ChromeOS Linux (Crostini). The two main entry points are:

- **`claude-box`** (`launch-interactive.sh`) — interactive Claude Code session with access to pipeline skills
- **`claude-box-yolo`** (`launch-interactive-yolo.sh`) — same as `claude-box` but with `--dangerously-skip-permissions`; Claude never asks for confirmation before running commands
- **`claude-yolo`** (`launch-scripted.sh`) — fully autonomous mode with `--dangerously-skip-permissions`, rate-limit auto-recovery, context compaction, and optional Gemini cross-model audit on failure

## Common Commands

```bash
# Initial setup (installs Docker, builds image, registers aliases)
./install.sh

# Rebuild the Docker image (e.g., after editing Dockerfile.claude)
docker build -t claude-sandbox -f Dockerfile.claude .

# Bootstrap credentials after logging in on the host
./setup-auth.sh          # or: claude-box-auth (after install)

# Launch an interactive session in the current directory
./launch-interactive.sh [model]          # or: claude-box [model]
./launch-interactive-yolo.sh [model]     # or: claude-box-yolo [model]  (auto-approve all commands)

# Launch autonomous mode
./launch-scripted.sh "task description" [model] [--no-gemini]  # or: claude-yolo

# Run tests
./tests/run_tests.sh            # all tests (unit + integration)
./tests/run_tests.sh --unit     # unit tests only (no Docker/credentials needed)
./tests/run_tests.sh --int      # integration tests only (requires Docker + credentials)
```

## Pipeline Skills (use inside claude-box)

Multi-phase pipeline workflows are implemented as native Claude Code skills. Invoke them inside a `claude-box` session:

```
/architect "add a plugin system"          # brainstorm → [gemini critique] → decide → implement
/qa "write tests for the auth module"     # generate tests → [gemini audit] → fill gaps
/refactor "fix the race condition"        # diagnose → decide → implement → [gemini on failure]
```

Building blocks (usable standalone):
```
/brainstorm [architect|refactor] <task>   # generate 3 approaches → docs/
/decide [architect|refactor] <task>       # evaluate candidates → docs/approved_*.md
/implement [architect|refactor|<task>]    # execute a spec or direct task
/geminiapi [architect-critique|qa-audit|refactor-diagnosis|dispatch] <task>
/logging [init|section|note|outcome|read] <pipeline> <args>
```

## Architecture

### Logging Directories

Two directories are auto-created at launch time by both `launch-scripted.sh` and `launch-interactive.sh`:
- `docs/decisions/` — timestamped Markdown logs (one per pipeline run). Created by `/logging init`; finalized by `/logging outcome`. Claude should call these at the start and end of any architect/qa/refactor pipeline run.
- `docs/progress/` — real-time JSONL event stream (`current.jsonl`). Written by `/logging progress`. Users can `tail -f docs/progress/current.jsonl` in a second terminal to monitor active sessions.

Claude does not need to create these directories manually — they exist before the container starts.

### Authentication flow
`~/.claude/.credentials.json` (host) → OAuth tokens extracted by Python one-liner → injected as `CLAUDE_CODE_OAUTH_TOKEN` / `CLAUDE_CODE_OAUTH_REFRESH_TOKEN` env vars into the container → bypasses Claude Code's first-run browser wizard.

`entrypoint.sh` handles a second config file: `~/.claude.json` lives in `$HOME` inside the container but is outside the mounted volume, so it's backed up into the volume on exit and restored on the next start.

### Docker volumes
Every container run bind-mounts two paths:
- `$(pwd)` → `/workspace` (the user's project directory — full read/write)
- `~/.claude` → `/home/claudeuser/.claude` (shared OAuth state between host and container)

### `launch-scripted.sh` retry loop
1. **Pre-flight**: if `CLAUDE.md` is absent in the workspace, a separate headless container generates it before the main task.
2. **Main loop** (up to `MAX_RETRIES` attempts):
   - Runs `claude --dangerously-skip-permissions -p "$TASK_PROMPT"` (or `--continue` on resume).
   - On **rate-limit** (parses "try again after HH:MM" from output): sleeps until the quota window reopens (with a 5-minute buffer), then retries without consuming a retry slot.
   - On **timeout or non-zero exit**: runs the Gemini audit (if `GEMINI_API_KEY` is set), then tries **Strategy A** (`/compact` piped to Claude Code), then falls back to **Strategy B+C** (handoff checkpoint + full `.claude/` wipe; wipe restores committed skills/commands via `git checkout`).
3. **Gemini audit** (`run_gemini_audit`): calls the Gemini API with automatic model fallback (tries flash models in order: 3.5→3→2.5→2.5-flash-lite; falls back to lite models with a warning if all flash models are rate-limited). Writes advice to `GEMINI_ADVICE.md` and prepends it to the next prompt. Set `GEMINI_MODEL_TIER=lite` to force lite-only (e.g. for test runs).

### Per-model token/timeout budgets (in `launch-scripted.sh`)
| Model | `MAX_MINUTES` | `MAX_CONTEXT_TOKENS` | `MAX_THINKING_TOKENS` |
|-------|--------------|---------------------|----------------------|
| haiku | 15 | 50 000 | 0 |
| sonnet (default) | 10 | 80 000 | 10 000 |
| opus | 5 | 120 000 | 24 000 |
| fable | 4 | 120 000 | 0 |

### Two Docker run configs
- `DOCKER_RUN_BASE` — uses `-it` (allocates a PTY) for the main task so Claude Code's TUI renders correctly.
- `DOCKER_RECOVERY_BASE` — uses `-i` (no TTY) for headless recovery passes (`/compact`, handoff writes, Gemini bootstrap) where a PTY would corrupt output.

### Skills and phase isolation
Pipeline skills (in `.claude/skills/`) use `context: fork` — each phase spawns a fresh subagent with no memory of prior phase conversations. Phases share data through files written to `docs/` and `tests/`. This replaces the `.claude/` wipe pattern used by the legacy bash scripts.

## Key Files

| File | Role |
|------|------|
| `Dockerfile.claude` | Debian image: Node 20, Python venv, Claude Code native install via `claude install` |
| `entrypoint.sh` | Restores/saves `~/.claude.json` across ephemeral container runs |
| `install.sh` | One-time host setup: Docker install, image build, `~/.bashrc` aliases |
| `setup-auth.sh` | One-time auth bootstrap: copies `.claude.json`, warms first-run state |
| `launch-interactive.sh` | `claude-box` alias implementation |
| `launch-interactive-yolo.sh` | `claude-box-yolo` alias — same as `claude-box` with `--dangerously-skip-permissions` |
| `launch-scripted.sh` | `claude-yolo` alias: full retry/recovery/audit engine |
| `lib/launch-lib.sh` | Pure helper functions sourced by pipeline scripts and the test suite |
| `.claude/skills/` | Pipeline skills: `brainstorm`, `decide`, `implement`, `geminiapi`, `logging`, `architect`, `qa`, `refactor` |
| `.claude/commands/` | Thin slash-command aliases for every skill |
| `.claude/settings.json` | Project-level Bash tool permissions for skills |
| `tests/run_tests.sh` | Test runner — `--unit` (no Docker) or `--int` (full integration) |
| `tests/test_*.sh` | Individual test files: unit tests for bash functions + integration tests |
| `tests/fixtures/` | Fake credential JSON files used by unit tests |
| `docs/decisions/` | Timestamped decision logs from pipeline runs (YYYYMMDD_HHMM_description_stage.md) |
| `legacy/` | Superseded bash pipeline scripts (`launch-architect.sh`, `launch-qa.sh`, etc.) |

## Style Notes

- Scripts use `set -eo pipefail` but intentionally omit `-u` (nounset) because Claude Code's bash shell integration references `$ZSH_VERSION`, which is unset in bash and would break Docker tee pipelines.
- `PIPESTATUS[0]` is used (not `$?`) after piped Docker commands so `tee`'s exit code doesn't mask failures.
- Recovery strategies are labeled A/B/C in comments throughout `launch-scripted.sh` — keep this convention when adding strategies.
- `GEMINI_ADVICE.md` is intentionally left on disk after a final failure for user review; it is cleaned up on success.
- `claude-auth/` is git-ignored; never commit OAuth credentials or session state. `.claude/` runtime state is also git-ignored (via `.claude/.gitignore`); only skills, commands, and `settings.json` are committed.

## Development Practices

- **Testing**: Write tests for new functionality. Unit tests live in `tests/test_*.sh` and must pass with `./tests/run_tests.sh --unit` before committing.
- **Commits**: Make small, logical commits — one coherent change per commit. Not so granular that every line is separate, but not giant all-in-one commits either. Each commit should represent a single meaningful unit of work that leaves the repo in a working state.
