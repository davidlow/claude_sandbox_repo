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
| `launch-scripted.sh` | `claude-yolo` — autonomous mode with rate-limit auto-recovery |

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
```

### Autonomous mode — `claude-yolo`

Give Claude a task and walk away. It runs with `--dangerously-skip-permissions`, handles timeouts, compacts context when needed, and automatically waits out Claude Pro rate limits.

```bash
cd ~/my-project
claude-yolo "run the test suite and fix any failures"
claude-yolo "refactor the auth module for readability" claude-opus-4-8
```

**Rate limit handling:** if Claude Pro's token quota is exhausted mid-task, `claude-yolo` detects the reset time from the error message, prints a countdown every 5 minutes, then resumes automatically — no intervention needed.

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

## Safe Usage Notes

- **Commit before `claude-yolo`** — the container has full read/write access to your project directory. Stash or commit your work first.
- **Rate limits** — `claude-yolo` handles Pro rate limits automatically, but very long tasks may exhaust multiple quota windows.
- **`~/.claude` is shared** — the container reads and writes to your host's `~/.claude/` directory, so session history is shared between your host Claude Code and the sandbox.
