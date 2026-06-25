# Brainstorm: Real-Time Progress Logging for claude-box and claude-yolo

**Generated:** 2026-06-24

## Option A: Minimal Wrapper with Live Log File

**Summary:** Wrap `claude` invocations with a progress-tracking script that writes state to a single shared log file as Claude executes, without modifying launch scripts or integrating deeply with the logging infrastructure.

**Key design decisions:**
- Create a new `claude-progress.log` file in `/workspace` (shared across host/container via Docker volume)
- Implement a thin bash wrapper (`lib/progress-wrapper.sh`) that intercepts `claude` command calls
- Wrapper writes initial state (timestamp, task, model, phase="setup") at start, then polls Claude's TUI output via `tee` to detect state changes
- Parse Claude Code's output patterns for activity indicators (e.g., "thinking", tool invocation messages, skill transitions) and update log in real-time
- Wrapper runs `claude` via `tee` to capture both stdout/stderr, detecting patterns and updating the log file on each pattern match
- No changes to `launch-interactive.sh` or `launch-scripted.sh`; wrapper can be sourced or invoked as a pre-command

**Trade-offs:**
- Extensibility: Low — pattern matching is brittle; if Claude Code's output format changes, the regex patterns break
- Complexity: Low — minimal code, easy to understand and test; just string matching and file writes
- Blast radius: Very small — isolated to a new wrapper script; existing scripts unaffected

**Risks or prerequisites:**
- Depends on heuristics from Claude Code's output; doesn't have direct integration with Claude's internals
- May miss some state transitions if output is buffered or delayed
- Single log file approach means concurrent runs overwrite each other (unsuitable for `claude-yolo` retries or multiple interactive sessions)
- Requires careful regex tuning to avoid false positives

---

## Option B: Structured Integration with Logging Skill and Launch Scripts

**Summary:** Extend the existing `/logging` skill and `docs/decisions/` infrastructure to emit real-time progress updates that a user can tail, by hooking progress callbacks into both launch scripts and having the logging skill write to a unified progress feed.

**Key design decisions:**
- Extend `/logging` skill with a new action: `progress [start|update|end]` that writes timestamped progress events to `docs/progress/current.jsonl` (JSON Lines format with one event per line)
- Each progress event: `{"timestamp": "2026-06-24T14:30:42Z", "phase": "brainstorm", "status": "active", "detail": "generating 3 approaches", "task": "..."})`
- Modify `launch-interactive.sh` and `launch-scripted.sh` to invoke `/logging progress start` at the beginning with task metadata
- Pass `PROGRESS_LOG_PATH=/workspace/docs/progress/current.jsonl` to the container as an env var
- Inside the container, create a shell hook that Claude Code can invoke (or create a `.claude/commands/` alias that logs progress mid-run)
- User can `tail -f /workspace/docs/progress/current.jsonl | jq .` to see live updates
- Integrate with decision logs: link progress log entries to the corresponding decision log file
- On completion, move `current.jsonl` to `docs/progress/YYYYMMDD_HHMM_<task-slug>.jsonl` and finalize via `/logging outcome`

**Trade-offs:**
- Extensibility: High — JSON Lines format is future-proof; new fields can be added without breaking existing parsers
- Complexity: Medium — requires changes to launch scripts, extending the logging skill, and ensuring env var propagation through Docker
- Blast radius: Moderate — touches launch scripts (critical infrastructure) but changes are additive, not destructive

**Risks or prerequisites:**
- Launch scripts must reliably pass `PROGRESS_LOG_PATH` into the container and ensure `/workspace/docs/progress/` directory exists
- Requires Claude Code skills to have a way to invoke progress updates; could use a slash command or a library function that Claude calls
- If Claude is not aware of the progress mechanism, updates will be sparse (only at launch start/end); richer updates require Claude to explicitly log them

---

## Option C: Full Observability with Daemon and Polling

**Summary:** Run a lightweight daemon process inside the container that polls Claude Code's process state and writes real-time progress by inspecting file handles, memory usage, and process state, combined with log file analysis; expose the progress via a REST API or Unix socket that the host can query.

**Key design decisions:**
- Create `lib/progress-daemon.sh` — a background process spawned by the launch scripts that continuously monitors Claude Code's process
- Daemon polls `/proc/<claude-pid>/` (Linux procfs) to get CPU usage, memory, number of open file handles, and recent activity
- Daemon also tails `.claude/logs/` (if Claude Code maintains logs) to extract high-level state
- Daemon writes structured progress data to a Unix socket at `/tmp/claude-progress.sock` (accessible from host via Docker volume or network)
- Host-side command `claude-progress` reads from the socket and displays current state
- Daemon persists progress events to `docs/progress/current.jsonl` (same as Option B) for historical record
- On Claude exit, daemon cleans up and finalizes the log entry
- Use structured formats (JSON) for all output to ensure machine-parseable and human-readable results

**Trade-offs:**
- Extensibility: Very High — daemon-based architecture is modular; easy to add new metrics (CPU, memory, handle count) and parsers for new Claude Code output formats
- Complexity: High — requires process monitoring, procfs parsing, socket management, and careful cleanup on exit
- Blast radius: Moderate — daemon runs separately from main Claude process; if daemon crashes, Claude continues unaffected

**Risks or prerequisites:**
- Requires understanding of Claude Code's internal logging structure (if it has one) — may not be documented
- Linux procfs availability is assumed (not portable to macOS without significant rework)
- Daemon must be carefully designed to avoid resource leaks (e.g., unclosed sockets, lingering processes)
- Socket permissions and cleanup on unclean shutdown (e.g., SIGKILL) need careful handling
- Higher operational overhead; more code to test and maintain

---
