# architect: real-time-progress-logging-claude-box-yolo

**Date:** 2026-06-24 20:14
**Pipeline:** architect
**Model:** claude-sonnet-4-6
**Status:** success

## Task

real-time-progress-logging-claude-box-yolo

## Phase 1: Brainstorm

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

## Gemini Critique

skipped — GEMINI_API_KEY not set — Phase 2 evaluates without external critique

## Phase 2: Approved Design

# Approved Plan: Real-Time Progress Logging for claude-box and claude-yolo

**Date:** 2026-06-24
**Selected:** Option B — Structured Integration with Logging Skill and Launch Scripts

## Rationale

Option B is selected over A and C for the following reasons:

**Why not Option A (Minimal Wrapper):** The wrapper approach depends on regex-parsing Claude Code's TUI output, which is ANSI-colored and formatted for human display, not machine parsing. Claude Code already uses `tee` piping in `launch-scripted.sh` (PIPESTATUS[0] convention), and adding another layer of `tee` interception risks garbling PTY output or masking exit codes. Most critically, Option A's single-file approach silently overwrites progress across `claude-yolo` retry cycles, and the approach provides no integration point for skills to emit their own richer mid-run annotations. It would deliver a superficially functional feature that degrades under any real usage scenario.

**Why not Option C (Daemon + Socket):** The daemon approach introduces background process lifecycle complexity (SIGKILL cleanup, socket permissions, stale socket files) that is disproportionate to the task. The Linux procfs metrics (CPU %, open file handles) do not actually tell a user what Claude is *doing*—they tell you it is running. The socket/REST layer adds a host-side client to maintain. This is the most complex option for the least semantic signal: process stats say nothing about whether Claude is brainstorming, writing tests, or stuck in a retry loop.

**Why Option B:** The task goal is for a user in a second terminal to see what Claude is *currently doing*—not raw metrics. Option B writes semantically meaningful, human-readable progress updates that Claude itself emits as it transitions between phases. The JSONL format is trivially `tail -f`-able and `jq`-filterable. The architecture is additive: it extends the existing `/logging` skill (which already runs inside the container and has write access to `/workspace/docs/`) and hooks into both launch scripts with minimal, isolated changes. It survives retry cycles by appending new events to the same `current.jsonl` file, making the log a complete run history rather than a last-state snapshot.

The one genuine risk in Option B—that progress updates will be sparse if Claude does not proactively call `/logging progress`—is addressed by having the launch scripts write the start/end envelope and by encouraging existing pipeline skills (`architect`, `qa`, `refactor`) to emit phase-transition updates. Even the minimal "started at T, ended at T+N" envelope is valuable for a user monitoring a long-running `claude-yolo` job.

## Changes Required

### Files to modify

- `launch-interactive.sh` — Write a progress start event before launching Docker; write a progress end event after it exits.
- `launch-scripted.sh` — Write a progress start event before the main retry loop; write per-attempt and per-recovery events inline; write a progress end event at the conclusion (success or failure). These writes happen on the *host*, outside the container, so no Docker changes needed.
- `.claude/skills/logging/SKILL.md` — Add a new `progress` action that appends a JSONL event to `docs/progress/current.jsonl`.
- `.claude/commands/logging.md` — Update the argument-hint to document the new `progress` action.
- `.claude/settings.json` — Add `Bash(mkdir -p docs/progress)` to the logging skill's allowed-tools list (may already be covered by the existing `mkdir -p *` permission).

### Files to create

- `lib/progress-lib.sh` — Pure bash helper sourced by both launch scripts. Contains `write_progress_event` function that takes `phase`, `status`, `detail`, and `task` arguments and appends a single JSON line to `docs/progress/current.jsonl`. This keeps the event-writing logic in one place and makes it unit-testable.
- `docs/progress/` — Directory created at runtime by the first `write_progress_event` call (via `mkdir -p`). Not committed.

### Files to delete

None.

## Key Interfaces / Data Structures

### Progress event format (JSONL, one object per line)

```
{"timestamp":"<ISO-8601>","source":"<host|skill>","phase":"<string>","status":"<started|active|completed|failed|retrying|rate-limited>","detail":"<human-readable string>","task":"<truncated task slug, max 80 chars>"}
```

Fields:
- `timestamp`: ISO-8601 UTC, generated by `date -u '+%Y-%m-%dT%H:%M:%SZ'`
- `source`: `"host"` when written by a launch script; `"skill"` when written by the logging skill inside the container
- `phase`: free-form label matching the pipeline phase, e.g. `"setup"`, `"attempt-1"`, `"compact"`, `"handoff"`, `"brainstorm"`, `"decide"`, `"implement"`, `"qa-phase-1"`, `"qa-phase-2"`
- `status`: one of the enumerated values above
- `detail`: human-readable string, max 200 chars
- `task`: first 80 characters of the task prompt (for identification when multiple runs share the same log)

### `write_progress_event` function signature (in `lib/progress-lib.sh`)

```bash
write_progress_event PHASE STATUS DETAIL [TASK]
```

- `PHASE`, `STATUS`, `DETAIL` are required.
- `TASK` is optional; defaults to `""` if not provided.
- Appends one JSON line to `./docs/progress/current.jsonl` (relative to `pwd`, which is the workspace root for host-side calls).
- Creates `docs/progress/` if it does not exist.
- Is silent on success; prints a warning to stderr on write failure (non-fatal).

### Logging skill `progress` action

```
/logging progress <phase> <status> <detail>
```

Writes one event to `docs/progress/current.jsonl` with `source: "skill"` and the current timestamp. Phase and status come from the arguments; task is read from `ORIGINAL_TASK_PROMPT` environment variable if set, otherwise left empty.

## Implementation Steps

1. **Create `lib/progress-lib.sh`** — Write a new file at `/workspace/lib/progress-lib.sh`. Define `write_progress_event` as a bash function. Inside it: (a) accept positional args `$1`=PHASE, `$2`=STATUS, `$3`=DETAIL, `$4`=TASK (default `""`); (b) run `mkdir -p docs/progress`; (c) construct the JSON object using printf with proper quoting—escape any double quotes in DETAIL and TASK by replacing `"` with `\"`; (d) append the JSON line to `docs/progress/current.jsonl`; (e) if the append fails, print `"[progress-lib] warning: could not write to docs/progress/current.jsonl"` to stderr and return 0 (non-fatal). Do not use `jq` as it may not be installed on the host.

2. **Add `source` call to `launch-scripted.sh`** — In the preamble of `launch-scripted.sh`, after the existing `source lib/launch-lib.sh` line, add `source "$(dirname "$0")/lib/progress-lib.sh"`. This makes `write_progress_event` available throughout the script.

3. **Emit progress events from `launch-scripted.sh`**:
   - After `ensure_claude_md_current` and before the `while` loop, add: `write_progress_event "setup" "started" "Launching $CHOSEN_MODEL for task" "${ORIGINAL_TASK_PROMPT:0:80}"`
   - At the top of the `while` loop, after the attempt echo, add: `write_progress_event "attempt-$ATTEMPT" "active" "Running claude --dangerously-skip-permissions (model: $CHOSEN_MODEL)" "${ORIGINAL_TASK_PROMPT:0:80}"`
   - After the rate-limit detection block's `echo "🛑 [RATE LIMIT]..."` line, add: `write_progress_event "rate-limit" "rate-limited" "Quota exhausted, waiting until $TARGET_DISPLAY" "${ORIGINAL_TASK_PROMPT:0:80}"`
   - After the `echo "🧹 [RECOVERY] Attempting context compaction (Strategy A)..."` line, add: `write_progress_event "compact" "retrying" "Attempting /compact (Strategy A)" "${ORIGINAL_TASK_PROMPT:0:80}"`
   - After the `echo "⚠️  Strategy A ineffective..."` line, add: `write_progress_event "handoff" "retrying" "Strategy A ineffective — running Strategy B+C (handoff + reset)" "${ORIGINAL_TASK_PROMPT:0:80}"`
   - At `echo "✅ Task completed successfully..."`, add: `write_progress_event "done" "completed" "Task finished successfully on attempt $ATTEMPT" "${ORIGINAL_TASK_PROMPT:0:80}"`
   - At `echo "❌ [FATAL ERROR]..."`, add: `write_progress_event "done" "failed" "Task failed after $MAX_RETRIES attempts" "${ORIGINAL_TASK_PROMPT:0:80}"`

4. **Emit progress events from `launch-interactive.sh`**:
   - Source `progress-lib.sh` before the Docker run line: `source "$(dirname "$0")/lib/progress-lib.sh"`
   - Before the `docker run` call, add: `write_progress_event "session" "started" "Interactive session starting (model: $CHOSEN_MODEL)" "interactive"`
   - After the `docker run` call returns (the next line after the `docker run` block), add: `write_progress_event "session" "completed" "Interactive session ended" "interactive"`

5. **Add `progress` action to `.claude/skills/logging/SKILL.md`** — Insert a new section between `## Action: note` and `## Action: outcome`:

   ```markdown
   ## Action: `progress`

   **Usage:** `progress <phase> <status> <detail>`

   Appends a real-time progress event to `docs/progress/current.jsonl` so a user monitoring a second terminal can see what Claude is actively doing.

   1. Run `mkdir -p docs/progress`
   2. Construct the JSON event:
      - `timestamp`: run `date -u '+%Y-%m-%dT%H:%M:%SZ'`
      - `source`: `"skill"`
      - `phase`: first argument
      - `status`: second argument
      - `detail`: third argument (truncate to 200 chars if longer)
      - `task`: value of `$ORIGINAL_TASK_PROMPT` env var, truncated to 80 chars; or `""` if unset
   3. Append a single JSON line to `docs/progress/current.jsonl` using the format:
      `{"timestamp":"<val>","source":"skill","phase":"<val>","status":"<val>","detail":"<val>","task":"<val>"}`
   4. Use Bash `echo` or `printf` — do NOT require `jq`.
   ```

6. **Update `.claude/commands/logging.md`** — Find the line containing the argument-hint (which currently reads `[init|section|note|outcome|read]`) and extend it to `[init|section|note|progress|outcome|read]`.

7. **Verify `.claude/settings.json` permissions** — Read the file and check that the logging skill's `allowedTools` already includes `Bash(mkdir -p *)`. If it does not, add `"Bash(mkdir -p docs/progress)"` to the array. The existing `Bash(mkdir -p *)` glob should already cover this.

8. **Write unit tests in `tests/test_progress_lib.sh`** — Create a new test file that sources `lib/progress-lib.sh` and verifies: (a) `write_progress_event` creates `docs/progress/current.jsonl` when it does not exist; (b) calling it three times appends three lines; (c) the output is valid JSON (use `grep` or `python3 -c "import json; json.loads(line)"` to validate each line); (d) TASK argument defaults to empty string; (e) the function is non-fatal when the target directory is not writable (test with a read-only temp dir). Run from the repo root using `bash tests/test_progress_lib.sh`.

9. **Update `tests/run_tests.sh`** — Add `tests/test_progress_lib.sh` to the list of unit test files that `--unit` mode runs, alongside the existing `test_launch_lib.sh`.

## Verification

```bash
# Unit tests (no Docker, no credentials required)
./tests/run_tests.sh --unit

# Manual end-to-end verification for claude-yolo
# In terminal 1:
./launch-scripted.sh "echo hello" claude-haiku-4-5

# In terminal 2 (immediately after starting terminal 1):
tail -f docs/progress/current.jsonl

# Expected: JSON lines appear in terminal 2 as the run progresses.
# On completion, verify the file contains at least 3 events (setup, attempt-1, done).

# Manual end-to-end verification for claude-box
# In terminal 1:
./launch-interactive.sh

# In terminal 2:
cat docs/progress/current.jsonl
# Expected: one "session started" event.
# After exiting claude-box in terminal 1, recheck — expect "session completed" event.

# Human-readable view
cat docs/progress/current.jsonl | python3 -c "
import sys, json
for line in sys.stdin:
    e = json.loads(line)
    print(f\"{e['timestamp']}  [{e['phase']}] {e['status']}: {e['detail']}\")
"
```

## Outcome

**Result:** success

Implemented progress-lib.sh with write_progress_event, hooked into both launch scripts, added progress action to /logging skill, 18 new tests passing
