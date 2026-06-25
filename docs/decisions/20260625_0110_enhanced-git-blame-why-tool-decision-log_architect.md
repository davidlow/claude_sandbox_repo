# architect: enhanced-git-blame-why-tool-decision-logs

**Date:** 2026-06-25 01:10
**Pipeline:** architect
**Model:** claude-sonnet-4-6
**Status:** success

## Task

enhanced-git-blame-why-tool-decision-logs

## Gemini Critique

skipped — GEMINI_API_KEY not set — Phase 2 evaluates without external critique

## Phase 1: Brainstorm

# Brainstorm: Enhanced Git-Blame Command with Decision Log Context

**Generated:** 2026-06-25

## Option A: Git-Native Wrapper with Timestamp Matching

**Summary:** Thin wrapper around `git blame` that parses commit timestamps and performs a straightforward filesystem scan of decision logs to find related entries by timestamp proximity.

**Key design decisions:**
- Wraps existing `git blame` command (shell out to native git) rather than reimplementing blame logic
- Parses `git blame` output line-by-line to extract commit hash and date
- Scans decision log filenames (YYYYMMDD_HHMM format) in a chronological window around commit timestamp
- Lightweight regex matching on filenames; no full-text indexing
- Returns raw git blame output plus annotated decision log excerpts appended below
- Does not cache or persist log metadata; rescans on each query

**Trade-offs:**
- Extensibility: Very limited; each query rescans filesystem; no preprocessing or caching
- Complexity: Minimal; straightforward bash script with `git blame` pipe and simple date arithmetic
- Blast radius / risk: Zero impact on existing tools; pure wrapper with no persistence

**Risks or prerequisites:** 
- Performance degrades with large numbers of decision logs (hundreds+)
- Simple timestamp matching may miss related logs if there's a time gap between commit and log creation
- No fuzzy matching on commit message or author; relies purely on timing proximity

---

## Option B: Cached Decision Log Index with Smart Heuristics

**Summary:** Build an optional JSON/SQLite metadata index of decision logs (indexed by commit hash, phase, date range, topics) that gets lazily constructed and cached. The tool queries this index and uses multi-factor heuristics (timestamp, commit message keywords, branch name, phase context) to surface relevant decisions.

**Key design decisions:**
- Generate a `.claude/decision-log-index.json` on first run (or on-demand with `--rebuild-index`)
- Index includes commit-to-logs reverse mapping, extracted keywords/phase tags from log content, date ranges
- When querying a file:line, first identify the commit, then consult the index for logs mentioning that commit hash, phase, or keyword tokens
- Fall back to timestamp windows if no index entry matches
- Return ranked results (high confidence first) based on heuristic match score
- Use `lib/log-search.sh` as foundation; extend it with indexing capability

**Trade-offs:**
- Extensibility: High; index can be extended with new metadata (tags, topics, severity); supports incremental updates
- Complexity: Moderate; requires index generation, maintenance logic, and ranking heuristic tuning
- Blast radius / risk: Adds a `.claude/` artifact (in .gitignore) that must stay in sync with decision logs

**Risks or prerequisites:**
- Index can become stale if logs are manually edited or deleted
- Multi-factor heuristics may return false positives if keywords overlap across unrelated decisions
- Requires upfront index generation time on first run (can be mitigated with --lazy-index flag)

---

## Option C: Full-Text Search Engine with Schema-Based Extraction

**Summary:** Treat decision logs as structured documents in a lightweight search database (grep-based inverted index or SQLite FTS5 full-text search). Extract decision log schema fields (commit hashes, branch, phase, decision statement, implementation notes) and index them. Query interface supports both simple "why line 42" and advanced Boolean queries (e.g., "phase:decide AND branch:main AND keyword:auth").

**Key design decisions:**
- Parse decision log files into structured fields (date, pipeline, model, task, commits, decision, rationale, links)
- Build an FTS5 (SQLite full-text search) database or grep-based inverted index of logs
- Support both natural language "explain line 42" and structured queries ("--phase architect --commit abc123")
- Return results ranked by relevance (BM25-style scoring or pattern matching confidence)
- Offer rich output formats (JSON, markdown, YAML) for downstream consumption
- Integrate with `lib/log-search.sh` as a backend; provide unified CLI

**Trade-offs:**
- Extensibility: Very high; can extend query language, add new indexed fields, add output formats; supports programmatic query from other tools
- Complexity: High; requires schema definition, index maintenance, query parser, ranking algorithm
- Blast radius / risk: Database file artifact; more moving parts to maintain; potential for index corruption

**Risks or prerequisites:**
- Requires consistent schema in decision log files (may need migrations if format changes)
- SQLite dependency (or complex grep-based index maintenance)
- Query parser may be confusing for users if not well-documented
- Schema extraction may fail on malformed or legacy logs

## Phase 2: Approved Design

# Approved Plan: Enhanced Git-Blame Command with Decision Log Context

**Date:** 2026-06-25
**Selected:** Option A — Git-Native Wrapper with Timestamp Matching

## Rationale

Option A is selected over B and C for the following reasons.

**Why not Option B (Cached Index with Heuristics):** The indexing approach introduces stale-data failure modes and an in-sync requirement against a `.claude/decision-log-index.json` artifact. Given the repository already has `lib/log-search.sh` with proven timestamp-based filtering and keyword search, a JSON index duplicates that logic while adding cache invalidation complexity. Multi-factor heuristics (keyword overlap across unrelated decisions) would increase false positives without meaningful precision gain at current log volume (under 50 logs). The implementation cost is disproportionate.

**Why not Option C (Full-Text Search / SQLite FTS5):** The Dockerfile does not install SQLite, and adding it as a dependency introduces container-size and maintenance overhead. Option C also over-engineers the query interface — a Boolean query language (`--phase decide AND --commit abc123`) exceeds what users need for answering "why was this line written." The existing `lib/log-search.sh` already handles keyword search via grep; building a parallel FTS index would be redundant. Schema-based extraction also requires decision logs to be consistently structured, which is a fragile assumption for legacy entries.

**Why Option A:** The project already ships `lib/log-search.sh`, which does exactly the timestamp-based and keyword-based log lookup that Option A describes. The `why` tool is a thin composition layer: run `git blame` on a file/line, extract the commit's author timestamp, then delegate to `lib/log-search.sh --commit <hash>` to surface decision log context for that commit window. This approach:
- Reuses proven, tested infrastructure (81 adversarial tests pass on `log-search.sh`)
- Requires no new dependencies
- Is a single new bash script of approximately 80 lines
- Produces human-readable output that is more useful than raw `git blame`
- Fits the project's bash-first, zero-dependency philosophy

The commit-to-log window heuristic (24 hours before the commit) is already implemented in `log-search.sh --commit`. The only new work is the `git blame` invocation, argument parsing for `file:line` / `file:function` syntax, and output formatting.

## Changes Required

### Files to create

- `lib/why.sh` — The standalone CLI. Accepts `<file>[:<line>|:<function>]` syntax. Runs `git blame` to identify the relevant commit(s), then delegates to `lib/log-search.sh --commit <hash>` for each distinct commit found. Prints a human-readable composite output: git blame summary, followed by decision log context.

### Files to modify

- `tests/run_tests.sh` — Register `tests/test_why.sh` in the unit test list.

### Files to create (tests)

- `tests/test_why.sh` — Unit tests for `lib/why.sh`. Uses a temporary git repository fixture and synthetic decision log files to test the full flow without Docker or credentials.

### Files to delete

None. `lib/log-search.sh` is retained and reused unchanged.

## Key Interfaces / Data Structures

### `lib/why.sh` invocation

```
lib/why.sh <file>[:<line>]
lib/why.sh <file>[:<function-name>]
lib/why.sh --help
```

Positional argument: `TARGET` — a file path with optional colon-delimited specifier:
- `lib/why.sh src/auth.js` — blame the entire file; surface decision logs for all distinct commits found in the blame output (capped at 5 most recent distinct commits to avoid noise on large files)
- `lib/why.sh src/auth.js:42` — blame only line 42; surface decision logs for that specific commit
- `lib/why.sh src/auth.js:login_user` — blame lines matching the function/identifier `login_user`; uses `git blame -L /<pattern>/,+10` syntax to blame the first match

Flags:
- `--help` — Print usage and exit 0
- `--window <hours>` — Override the look-back window passed to `log-search.sh` (default 24 hours, expressed via the commit-window date arithmetic in `log-search.sh`)

### Output format

```
=== git blame: src/auth.js:42 ===
<raw git blame output for the relevant lines>

=== Decision log context ===
Commit abc1234 (2026-06-19 05:15 UTC) — searching decision logs within 24h before this commit...

--- docs/decisions/20260619_0515_fix-login-bug_qa.md
Date:     2026-06-19 05:15
Pipeline: qa
Status:   success
Task:     fix-login-bug

[No decision logs found for commit def5678 — no logs in the 24h window before 2026-06-20 14:00 UTC]
```

Each section is separated by a blank line. The `=== ... ===` headers delimit the blame section from the context section. When no decision logs are found for a commit, a single explanatory line is printed in square brackets (no error exit).

### Environment variables

- `LOGS_DIR` — Passed through to `lib/log-search.sh`; defaults to `docs/decisions/` relative to the repo root. Allows test harness to override.

### Dependency on `lib/log-search.sh`

`why.sh` resolves `log-search.sh` as:
```bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_SEARCH="${SCRIPT_DIR}/log-search.sh"
```

This ensures portability whether called as `lib/why.sh`, `bash lib/why.sh`, or symlinked.

## Implementation Steps

1. **Create `lib/why.sh`** — Write the script at `/workspace/lib/why.sh` with `#!/usr/bin/env bash` and `set -eo pipefail`.

   a. **Resolve sibling dependency** — At the top of the script, after the shebang:
      ```bash
      SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
      LOG_SEARCH="${SCRIPT_DIR}/log-search.sh"
      ```
      Immediately check: if `$LOG_SEARCH` does not exist or is not executable, print an error to stderr and exit 1.

   b. **Parse arguments** — Use a `while [[ $# -gt 0 ]]` loop:
      - `--help` → print usage block and exit 0
      - `--window <hours>` → set `WINDOW_HOURS="$2"`, shift twice (store for informational output; `log-search.sh` controls its own window via its own default of 24h — this flag is surfaced in the help text for future extension)
      - First unrecognized non-flag argument → set `TARGET="$1"`, shift
      - Unknown flags → print error to stderr and exit 1
      After the loop, if `TARGET` is empty, print usage to stderr and exit 1.

   c. **Parse TARGET** — Split `TARGET` on the first `:`:
      - `FILE="${TARGET%%:*}"`
      - `SPECIFIER` is non-empty only when `TARGET` contains a `:`: use `[[ "$TARGET" == *:* ]] && SPECIFIER="${TARGET#*:}"` 
      - Validate `FILE` exists as a regular file: if not, print `"Error: file not found: $FILE"` to stderr and exit 1.
      - Determine `SPEC_TYPE`:
        - If `SPECIFIER` is empty → `SPEC_TYPE=file`
        - If `SPECIFIER` matches `^[0-9]+$` → `SPEC_TYPE=line`, `LINE="$SPECIFIER"`
        - Otherwise → `SPEC_TYPE=function`, `FUNC_PATTERN="$SPECIFIER"`

   d. **Run `git blame`** — Build the blame command based on `SPEC_TYPE`:
      - `file`: `BLAME_OUT=$(git blame --date=iso-strict "$FILE")`
      - `line`: `BLAME_OUT=$(git blame --date=iso-strict -L "${LINE},${LINE}" "$FILE")`
      - `function`: attempt `BLAME_OUT=$(git blame --date=iso-strict -L "/^[[:space:]]*${FUNC_PATTERN}/,+20" "$FILE" 2>/dev/null)`. If the command exits non-zero or produces empty output, print a warning to stderr (`"Warning: function pattern '${FUNC_PATTERN}' not matched, falling back to full file blame"`) and fall back to blaming the full file.

      If `git blame` itself exits non-zero (e.g., file is not tracked), print its error and exit with the same code.

   e. **Print blame section** — Output:
      ```
      === git blame: ${TARGET} ===
      ```
      Followed by `$BLAME_OUT` verbatim, then a blank line.

   f. **Extract distinct commits** — From `BLAME_OUT`, extract commit hashes using awk on the first field:
      ```bash
      mapfile -t COMMITS < <(echo "$BLAME_OUT" | awk '{print $1}' | grep -v '^0\{8\}' | sort -u | head -5)
      ```
      The `grep -v '^0\{8\}'` removes the "not yet committed" sentinel (`00000000`). `head -5` caps at 5 commits to avoid excessive output on large files.

   g. **Print context section header** — Output:
      ```
      === Decision log context ===
      ```
      If `COMMITS` is empty (e.g., all lines are uncommitted), print `[File has no committed lines — no decision log context available]` and exit 0.

   h. **For each commit, look up decision logs** — Iterate `COMMITS`. For each commit hash:
      - Get the commit's author date: `COMMIT_DATE=$(git log --format='%aI' -1 "$COMMIT" 2>/dev/null)`. If empty, print `[Warning: could not resolve commit ${COMMIT:0:7}]` and continue.
      - Get a short description: `COMMIT_MSG=$(git log --format='%h %s' -1 "$COMMIT" 2>/dev/null)`
      - Print: `Commit ${COMMIT_MSG} (${COMMIT_DATE}) — searching decision logs within ${WINDOW_HOURS:-24}h before this commit...`
      - Run: `SEARCH_OUT=$(LOGS_DIR="${LOGS_DIR:-}" bash "$LOG_SEARCH" --commit "$COMMIT" 2>&1)` and capture exit code in `SEARCH_RC`.
      - If `SEARCH_OUT` contains "No matching decision logs found" or `SEARCH_RC` is non-zero: print `[No decision logs found for commit ${COMMIT:0:7} — no logs in the ${WINDOW_HOURS:-24}h window before ${COMMIT_DATE}]`
      - Otherwise: print `SEARCH_OUT` verbatim.
      - Print a blank line between commits.

   i. **Make executable** — Ensure the file is created with executable permissions (`chmod +x`).

2. **Write `tests/test_why.sh`** — Create `/workspace/tests/test_why.sh`.

   a. **Test harness** — Follow the same `PASS`/`FAIL` counting pattern used in `tests/test_log_search.sh`.

   b. **Fixture setup** — In setup:
      - Create a temp directory `TMPDIR=$(mktemp -d)`
      - Initialize a fake git repo in `$TMPDIR`: `git init`, set `user.email` and `user.name` via `git -C "$TMPDIR" config`
      - Create a file `$TMPDIR/src/auth.sh` with at least 5 lines of content, `mkdir -p "$TMPDIR/src"`
      - Stage and commit: `git -C "$TMPDIR" add . && git -C "$TMPDIR" commit -m 'add auth module'`
      - Record: `COMMIT1=$(git -C "$TMPDIR" log --format='%H' -1)` and `COMMIT1_DATE=$(git -C "$TMPDIR" log --format='%aI' -1)`
      - Derive filename-safe timestamp: `LOG_TS=$(date -d "$COMMIT1_DATE" '+%Y%m%d_%H%M')`
      - Create decision log fixture: `mkdir -p "$TMPDIR/docs/decisions"` and write a file named `${LOG_TS}_test-decision_architect.md` with minimal content including `**Pipeline:** architect` and `**Status:** success`
      - Export `LOGS_DIR="$TMPDIR/docs/decisions"` so `log-search.sh` scans the temp directory
      - `trap 'rm -rf "$TMPDIR"' EXIT`

   c. **Tests to write (run `why.sh` with `-C`-style by setting `GIT_DIR` and `GIT_WORK_TREE`, or by using absolute paths to the fixture files):**
      - `test_help_flag`: `bash lib/why.sh --help` exits 0; output contains "Usage"
      - `test_no_args`: `bash lib/why.sh` exits non-zero
      - `test_missing_file`: `bash lib/why.sh /nonexistent/path.sh:42` exits non-zero; output contains "not found"
      - `test_unknown_flag`: `bash lib/why.sh --badflag` exits non-zero
      - `test_log_search_not_found`: invoke `why.sh` with `LOG_SEARCH=/nonexistent.sh` somehow — simplest approach is to temporarily rename `lib/log-search.sh`. Skip this test if renaming is too fragile; use a wrapper script in `$TMPDIR` instead.
      - `test_file_blame_headers`: on a tracked file in the test repo fixture, both `=== git blame:` and `=== Decision log context ===` appear in output
      - `test_line_blame`: `file:1` produces output containing `=== git blame: ${FILE}:1 ===`
      - `test_commit_context_found`: running `why.sh` on the fixture file whose commit has a matching fixture decision log shows the log filename in output (requires running from inside `$TMPDIR` or passing absolute path and setting `GIT_DIR`)
      - `test_commit_context_not_found`: a file in a fresh commit with no matching log file shows `[No decision logs found`
      - `test_function_pattern_fallback`: `bash lib/why.sh <fixture-file>:nonexistent_func` does not exit non-zero; falls back to full-file blame

   d. **Cleanup** — Handled by `trap`.

   e. **Summary line** — Print `"PASS: N tests passed"` or `"FAIL: X tests failed"` and exit 1 on any failure.

   **Important implementation note for the test fixture:** `git blame` requires the file to be inside a git repository. When using a temp directory, tests must either (a) `cd` into `$TMPDIR` before calling `why.sh` on a relative path, or (b) set `GIT_DIR="$TMPDIR/.git"` and `GIT_WORK_TREE="$TMPDIR"` in the environment when invoking `why.sh`. Prefer option (b) to avoid changing the working directory of the test runner process; use a wrapper like `(cd "$TMPDIR" && bash "$REPO_ROOT/lib/why.sh" src/auth.sh)`.

3. **Update `tests/run_tests.sh`** — Find the section that enumerates unit test files (the list alongside `test_launch_lib.sh`, `test_progress_lib.sh`, `test_log_search.sh`, `test_log_search_adversarial.sh`). Add `tests/test_why.sh` to the same list.

4. **Verify executable bit on `lib/log-search.sh`** — Confirm `lib/log-search.sh` is executable (`ls -la lib/log-search.sh`). If not, `chmod +x lib/log-search.sh`. This is a prerequisite for `why.sh`'s dependency check at startup.

## Verification

```bash
# Unit tests (no Docker, no credentials required)
./tests/run_tests.sh --unit

# Manual smoke tests (run from workspace root)

# Help output
bash lib/why.sh --help

# Blame an entire file (shows up to 5 distinct commits)
bash lib/why.sh lib/log-search.sh

# Blame a specific line
bash lib/why.sh lib/log-search.sh:1

# Blame by function name
bash lib/why.sh lib/log-search.sh:parse_date_range

# Error case: missing file
bash lib/why.sh nonexistent.sh:10   # should exit non-zero

# Error case: no arguments
bash lib/why.sh                     # should exit non-zero with usage
```

Expected outcomes:
- All `--unit` tests pass with zero failures
- `why.sh` on any tracked file prints both `=== git blame ===` and `=== Decision log context ===` sections
- When a matching decision log exists (commit timestamp within 24h of a log's filename timestamp), the log header is shown
- When no log matches, a clear `[No decision logs found ...]` message is printed and the tool exits 0
- Missing file, no args, and unknown flags all exit non-zero with an explanatory error message
- Function pattern fallback (unknown function name) falls back gracefully to full-file blame with a warning to stderr

## Outcome

**Result:** success

Implemented lib/why.sh — thin wrapper over git blame + lib/log-search.sh. Parses file:line and file:function syntax. 15 new tests passing.
