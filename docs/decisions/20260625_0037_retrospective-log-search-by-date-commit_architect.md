# architect: retrospective-log-search-by-date-commit-keyword

**Date:** 2026-06-25 00:37
**Pipeline:** architect
**Model:** claude-sonnet-4-6
**Status:** success

## Task

retrospective-log-search-by-date-commit-keyword

## Gemini Critique

skipped — GEMINI_API_KEY not set — Phase 2 evaluates without external critique

## Phase 1: Brainstorm

# Brainstorm: Retrospective Log Search Tool

**Generated:** 2026-06-25

## Option A: Minimal Bash Search Script

**Summary:** A lightweight, single-file `lib/log-search.sh` script using only grep, awk, and basic date parsing. Implements search by date range, keyword, and git commit lookup via direct log file iteration.

**Key design decisions:**
- Pure bash implementation with no external dependencies beyond `git` (already required)
- Flat sequential search over decision log filenames and content
- Date parsing via bash arithmetic on `YYYYMMDD_HHMM` filename timestamps
- Git integration: loop through recent commits, use `git log --format` to extract commit hash and date, match against log creation times
- Output: plain text with file paths and excerpts, no structured format
- Callable as standalone script (`./lib/log-search.sh --date "last week"`) or wrapped as `/logging search` skill
- No persistent index — searches are O(n) over the decision logs directory

**Trade-offs:**
- **Extensibility:** Limited. Adding new search types (e.g., search by pipeline stage) requires modifying the script. No plugin system.
- **Complexity:** Very low. Single script, easy to audit and understand.
- **Blast radius / risk:** Minimal. No new infrastructure, no data structures, no risk of breaking existing logging.
- **Performance:** Fine for 50-100 logs, but degrades as log volume grows. Grep over all logs on each search.
- **Maintainability:** Straightforward bash patterns; team already familiar with shell scripting style.

**Risks or prerequisites:** 
- Date range parsing requires careful bash logic to handle relative dates ("last week", "7 days ago"). Use `date -d` (GNU) or `date -v-7d` (BSD) — will need platform detection.
- Git commit lookup requires parsing `git log` output and doing timestamp comparisons, which is error-prone if logs don't have fine-grained timestamps.
- Requires users to invoke the script correctly; no interactive UI.

---

## Option B: Indexed Search with Sqlite Database

**Summary:** Build an indexing daemon that runs after each pipeline completes, storing log metadata (timestamp, keywords, git hash, pipeline stage) in a lightweight SQLite database. Implement a `/logging search` subcommand and CLI tool (`lib/log-search.sh`) that queries the index instead of grepping files.

**Key design decisions:**
- Create `.claude/log-index.db` (SQLite, git-ignored) with a simple schema: `logs(id, created_at, filename, pipeline, slug, description)` and `content(log_id, section, text)` for full-text search
- Index population: after each logging operation (`/logging outcome`), trigger an index sync that appends new logs to the database
- Date range search: use SQLite `WHERE created_at BETWEEN ? AND ?`
- Git commit search: on index creation, compute the "active logs" timeline by sorting logs by timestamp, then binary-search for logs that were created before/during a commit
- Keyword search: use SQLite FTS (full-text search) virtual table for fast substring matching
- Output: formatted markdown or JSON, with clickable file paths
- Optional UI: simple Python Flask app for web-based browsing (opt-in, not required)

**Trade-offs:**
- **Extensibility:** High. The database schema is flexible; adding new metadata (e.g., model used, retry count) is trivial.
- **Complexity:** Moderate. Requires SQLite schema design, index sync logic, and Python/Node.js FTS integration.
- **Blast radius / risk:** Low-to-moderate. The index is local, ephemeral, and can be rebuilt by re-scanning logs. Doesn't affect production logging.
- **Performance:** Excellent. O(log n) queries once indexed. Scales to 1000s of logs.
- **Maintainability:** Requires someone to maintain the schema and sync logic. SQLite knowledge helpful but not deep.

**Risks or prerequisites:**
- Requires ensuring the index is kept in sync. If logs are manually edited or deleted, the index becomes stale.
- SQLite FTS requires careful tokenization to handle long filenames and multi-word slugs.
- The "active logs for a commit" computation is complex: needs to account for pipeline stages and overlapping timelines.

---

## Option C: Git-Native Search with Procedural Queries

**Summary:** Treat decision logs as artifacts within the git history. Leverage `git log`, `git blame`, and commit metadata to reconstruct the decision context at any point in time. Implement a `/logging time-travel` subcommand that shows what decisions were in flight when a commit was made, by correlating commit timestamps with log creation times directly from git objects.

**Key design decisions:**
- No external index. Instead, synthesize search results on-demand by:
  - `git log --all --format` for commit history with author dates
  - Direct file `mtime` from git objects (if available) or parse filenames
  - Reconstruct a timeline of decision logs as they existed at a given commit timestamp
- Date range search: convert date strings to git revisions using `git rev-list --since/--until`, then map to log timestamps
- Keyword search: use `git grep` to search log content across the history (find logs that existed at commit time with matching text)
- Git commit search: given a commit hash, read its author date, then list all decision logs created before/around that timestamp
- Output: show logs alongside the commit they influenced, formatted as a narrative timeline
- Integrates tightly with git workflows: `git log` already shows commits; now show the decision context

**Trade-offs:**
- **Extensibility:** High. Leverages git's built-in query engine; adding new search types is mostly plumbing.
- **Complexity:** High. Requires deep understanding of git object model, timestamp semantics, and careful handling of timezone edge cases.
- **Blast radius / risk:** Very low. Reads from `.git/objects` only, no writes, no index to maintain.
- **Performance:** Depends on git repository size. Fast for small repos; slower as git history grows. `git log` and `git grep` are optimized by git.
- **Maintainability:** Experts-only. Git internals are not well-understood by most teams. Bug fixes can be subtle.

**Risks or prerequisites:**
- Requires that decision log filenames are reliable timestamps (they are, by design, but any renaming breaks the approach).
- Git commit timestamps are author-time, not committer-time; decisions made across timezones are tricky to reason about.
- Requires knowledge of git plumbing commands (`git rev-list`, `git cat-file`, etc.) to implement robustly.
- If logs are ever deleted from git history (rebase, filter-branch), search results become inconsistent.

## Phase 2: Approved Design

# Approved Plan: Retrospective Log Search Tool

**Date:** 2026-06-25
**Selected:** Option A — Minimal Bash Search Script

## Rationale

Option A is selected over B and C for the following reasons.

**Why not Option B (SQLite Index):** The indexing approach is over-engineered for the current scale. There are 24 decision logs today. Even at 10x growth (240 logs), grep across markdown files is sub-second. The SQLite index introduces a stale-data failure mode (manually edited or deleted logs silently diverge from the database), requires schema maintenance, and adds FTS tokenization complexity for no practical performance benefit at this log volume. The requirement to trigger index sync after each `/logging outcome` call would also couple the logging skill to an external database dependency, increasing blast radius. SQLite itself is not guaranteed present in the Docker container without explicit installation.

**Why not Option C (Git-Native Search):** Option C conflates two separate concerns: "when was this log written" (answered by the filename timestamp) and "what was in the git tree at that moment" (answered by git object history). Decision logs are tracked in git; `git log` history and file `mtime` inside git objects are not the same as the log's filename timestamp. The git plumbing approach requires expertise that is not proportionate to the task and introduces fragility if the git history is ever rebased or filtered. The "git grep across history" feature would search log content as it existed at prior commits — which is not what a user wants when they ask "why was this change made." They want to read the log that was active at the time, not to reconstruct it from object storage.

**Why Option A:** The filename schema (`YYYYMMDD_HHMM_description_stage.md`) encodes all the metadata needed for date-range and pipeline-stage filtering without any external index. Grep handles keyword search natively. Git commit lookup is achievable by: (a) resolving a commit hash or message to an author-date via `git log`, then (b) filtering log filenames by comparing that timestamp to the filename prefix. This is 30 lines of bash, not 300. The entire feature is a single script in `lib/` that fits the project's existing bash-first, zero-dependency philosophy. It is also immediately testable with the existing `tests/run_tests.sh --unit` harness. Integration with `/logging search` is a thin wrapper that passes `$ARGUMENTS` to the script.

The one genuine weakness of Option A — date arithmetic portability between GNU `date -d` (Linux/container) and BSD `date -r` (macOS) — is addressed in the implementation steps by using `date -d` exclusively, since the Docker container is Debian Linux and the host install requirement already specifies Debian/ChromeOS.

## Changes Required

### Files to create

- `lib/log-search.sh` — The main search script. Implements `--date`, `--commit`, and `--keyword` flags with human-readable output.
- `tests/test_log_search.sh` — Unit tests for `lib/log-search.sh` using fixture log content in a temp directory.

### Files to modify

- `.claude/skills/logging/SKILL.md` — Add a `search` action section that delegates to `lib/log-search.sh`.
- `.claude/commands/logging.md` — Extend the argument-hint to include `search`.
- `tests/run_tests.sh` — Register the new test file in the unit test list.

### Files to delete

None.

## Key Interfaces / Data Structures

### `lib/log-search.sh` invocation

```
lib/log-search.sh [--date <date-spec>] [--commit <hash-or-msg>] [--keyword <term>] [--and] [--help]
```

Flags:
- `--date <date-spec>` — Filter logs by date. Accepts:
  - Absolute date: `2026-06-19` (matches logs with filename prefix `20260619`)
  - Week offset: `last week` (logs from the 7-day window ending yesterday)
  - Range: `2026-06-19..2026-06-24` (inclusive on both ends)
  - Named shortcuts: `today`, `yesterday`
- `--commit <ref>` — Find logs that were "active" when a commit was made. Accepts a full or partial commit hash, or a substring of a commit message. Resolves to the commit's author-date, then lists logs whose filename timestamp falls within a 24-hour window before that commit.
- `--keyword <term>` — Case-insensitive grep over log file content. Prints the matching log filename and the matching lines with 2 lines of context.
- `--and` — When multiple flags are provided, require all to match (default: any flag match counts as a result).
- `--help` — Print usage and exit 0.

When no flags are given, print the 10 most recent logs (same behavior as `/logging read`).

### Output format

For each matching log, print a human-readable block:

```
--- docs/decisions/20260624_2014_real-time-progress-logging-claude-box-yolo_architect.md
Date:     2026-06-24 20:14
Pipeline: architect
Status:   success
Task:     real-time-progress-logging-claude-box-yolo
  > [matching line context, if --keyword was used]
```

A `---` separator precedes each result. Keyword match lines are indented with `  > ` to distinguish them from metadata.

### LOGS_DIR environment variable

The script resolves its search directory as:
```bash
LOGS_DIR="${LOGS_DIR:-$(cd "$(dirname "$0")/.." && pwd)/docs/decisions}"
```
This allows the test harness to override it without patching the script.

### `/logging search` skill action

Resolves `lib/log-search.sh` relative to the workspace root via `git rev-parse --show-toplevel`, then passes all remaining arguments to it via Bash.

## Implementation Steps

1. **Create `lib/log-search.sh`** — Write the script at `/workspace/lib/log-search.sh` with `#!/usr/bin/env bash` and `set -eo pipefail`. Structure as follows:

   a. **LOGS_DIR resolution** — At the top, set:
      ```bash
      LOGS_DIR="${LOGS_DIR:-$(cd "$(dirname "$0")/.." && pwd)/docs/decisions}"
      ```

   b. **Parse arguments** — Use a `while [[ $# -gt 0 ]]` loop handling `--date`, `--commit`, `--keyword`, `--and`, `--help`. Store values in `DATE_SPEC`, `COMMIT_REF`, `KEYWORD`, `AND_MODE` variables. After the loop, if no recognized flags were given, enter default mode (10 most recent logs).

   c. **Define `parse_date_range`** — A function that sets two variables `DATE_FROM` and `DATE_TO` (both `YYYYMMDD`, no dashes) based on `DATE_SPEC`:
      - `today` → `DATE_FROM=DATE_TO=$(date '+%Y%m%d')`
      - `yesterday` → `DATE_FROM=DATE_TO=$(date -d yesterday '+%Y%m%d')`
      - `last week` → `DATE_FROM=$(date -d '7 days ago' '+%Y%m%d')`, `DATE_TO=$(date -d yesterday '+%Y%m%d')`
      - `YYYY-MM-DD` → strip dashes, set both `DATE_FROM` and `DATE_TO` to the result
      - `YYYY-MM-DD..YYYY-MM-DD` → split on `..`, strip dashes from each part
      If the input matches none of these patterns, print an error to stderr and exit 1.

   d. **Define `resolve_commit_window`** — A function that sets `COMMIT_FROM` and `COMMIT_TO` (both `YYYYMMDD_HHMM` strings) given `COMMIT_REF`:
      - First try: `git log --all --format='%H %aI' | grep -m1 "^${COMMIT_REF}"` (hash prefix match). Extract the ISO-8601 author date from the second field.
      - If no hash match: `git log --all --grep="${COMMIT_REF}" --format='%aI' -1` (message substring match).
      - If still no result, print `"Could not resolve commit ref: ${COMMIT_REF}"` to stderr and exit 1.
      - Convert the author date to `YYYYMMDD_HHMM`: `date -d "<author-date>" '+%Y%m%d_%H%M'` → `COMMIT_TO`
      - Compute `COMMIT_FROM`: `date -d "<author-date> - 1 day" '+%Y%m%d_%H%M'`

   e. **Define `format_log_header`** — Takes a log filepath. Uses grep to extract `**Date:**`, `**Pipeline:**`, `**Status:**` values from the first 15 lines. Derives the task slug from the filename (strip `YYYYMMDD_HHMM_` prefix and `_<pipeline>.md` suffix). Prints the formatted block described in the output format section.

   f. **Build candidate list** — `mapfile -t ALL_LOGS < <(ls -t "$LOGS_DIR"/*.md 2>/dev/null)`. If the array is empty, print `"No decision logs found in docs/decisions/"` and exit 0.

   g. **Apply date filter** — If `DATE_SPEC` is set, call `parse_date_range`. Filter `ALL_LOGS` keeping only files whose basename prefix (chars 1-8) satisfies `>= DATE_FROM` and `<= DATE_TO` (lexicographic comparison works because the format is `YYYYMMDD`).

   h. **Apply commit filter** — If `COMMIT_REF` is set, call `resolve_commit_window`. Filter `ALL_LOGS` keeping files whose basename prefix `YYYYMMDD_HHMM` (chars 1-13) satisfies `>= COMMIT_FROM` and `<= COMMIT_TO`.

   i. **Apply keyword filter** — If `KEYWORD` is set and `AND_MODE` is true, remove any candidate from the list that does not match `grep -qil "${KEYWORD}" "$file"`. If `AND_MODE` is false (the default), union the keyword-matching files with whatever the date/commit filters produced (i.e., a file qualifies if it passed the date or commit filter, OR if it contains the keyword).

   j. **Print results** — Iterate the surviving list in the order produced by `ls -t` (newest first). For each file, call `format_log_header`. If `--keyword` was set, also print the matching lines: `grep -in --color=never -A2 -B2 "${KEYWORD}" "$file" | sed 's/^/  > /'`. Prepend a `---` separator before each result block. If the list is empty, print `"No matching decision logs found."` and exit 0.

   k. **Default mode** — If no flags were given, print a header `"Showing 10 most recent decision logs:"` then iterate `"${ALL_LOGS[@]:0:10}"` and call `format_log_header` for each.

   l. **`--help`** — Print a usage block and exit 0.

   m. **Make executable** — The script file should be committed with executable bit (`chmod +x lib/log-search.sh` as part of creation).

2. **Add `search` action to `.claude/skills/logging/SKILL.md`** — Append a new section after `## Action: read` (the last action in the file):

   ```markdown
   ## Action: `search`

   **Usage:** `search [--date <date-spec>] [--commit <hash-or-msg>] [--keyword <term>] [--and]`

   Searches decision logs in `docs/decisions/` and prints human-readable results.

   1. Resolve the workspace root: run `git rev-parse --show-toplevel` and store as `REPO_ROOT`
   2. Run: `bash "${REPO_ROOT}/lib/log-search.sh" <all remaining arguments after "search">`
   3. Print the output verbatim.

   Supported flags (passed through to the script):
   - `--date <date-spec>` — filter by date (`today`, `yesterday`, `last week`, `2026-06-19`, `2026-06-01..2026-06-30`)
   - `--commit <ref>` — show logs active when a commit was made (accepts hash prefix or message substring)
   - `--keyword <term>` — search log content for a keyword
   - `--and` — when multiple flags are given, require all to match (default is OR)
   ```

   The `allowed-tools` line in the SKILL.md frontmatter already includes `Bash(...)` patterns; verify it covers `Bash(git rev-parse *)` and `Bash(bash *)`. If not, add them.

3. **Update `.claude/commands/logging.md`** — Find the `argument-hint` value and extend it: change `[init|section|note|progress|outcome|read]` to `[init|section|note|progress|outcome|read|search]`. Also update the `description` field to mention `search` alongside the other actions.

4. **Write `tests/test_log_search.sh`** — Create `/workspace/tests/test_log_search.sh`:

   a. **Test harness** — Follow the same pattern as `tests/test_launch_lib.sh` (inspect that file first to reuse any shared helper functions).

   b. **Fixture setup** — In `setUp` or at the top, create a temp directory (`TMPDIR=$(mktemp -d)`) and set `export LOGS_DIR="$TMPDIR"`. Write 5 fixture log files into `$TMPDIR`:
      - `20260619_0515_fix-login-bug_qa.md` — contains `**Pipeline:** qa`, `**Status:** success`, body contains "authentication"
      - `20260620_1400_add-caching-layer_architect.md` — contains `**Pipeline:** architect`, `**Status:** success`, body contains "redis"
      - `20260624_2001_refactor-database_refactor.md` — contains `**Pipeline:** refactor`, `**Status:** failed`, body contains "authentication"
      - `20260625_0018_new-feature_architect.md` — contains `**Pipeline:** architect`, `**Status:** success`, body contains "billing"
      - `20260625_0037_another-task_qa.md` — contains `**Pipeline:** qa`, `**Status:** success`, body contains "redis"

   c. **Cleanup** — `trap 'rm -rf "$TMPDIR"' EXIT`

   d. **Tests to write:**
      - `test_date_exact`: `--date 2026-06-24` returns exactly the `20260624_` file; assert output contains `20260624_2001` and does not contain `20260619`
      - `test_date_range`: `--date 2026-06-19..2026-06-20` returns 2 files (the `20260619` and `20260620` ones); assert count via `grep -c '^---'`
      - `test_date_today`: `--date today` returns only files with today's `YYYYMMDD` prefix; if today is not `20260619`-`20260625`, expect "No matching"
      - `test_keyword_authentication`: `--keyword authentication` returns 2 files; assert output contains both `fix-login-bug` and `refactor-database`
      - `test_keyword_redis`: `--keyword redis` returns 2 files; assert output contains both `add-caching-layer` and `another-task`
      - `test_keyword_none`: `--keyword nonexistent` prints "No matching decision logs found."
      - `test_and_mode`: `--keyword authentication --date 2026-06-19 --and` returns only the `20260619` file
      - `test_default_no_flags`: no flags returns up to 10 logs; assert output contains "Showing 10 most recent"
      - `test_help`: `--help` exits with code 0 and output contains "Usage"
      - `test_unknown_flag`: `--badflag` exits with non-zero code

   e. **Summary** — Print `"PASS: N tests passed"` or `"FAIL: N failed"` and exit 1 on any failure.

5. **Update `tests/run_tests.sh`** — Find the section where unit test files are enumerated (the list alongside `test_launch_lib.sh` and `test_progress_lib.sh`). Add `tests/test_log_search.sh` to the same list.

6. **Verify `.claude/settings.json` permissions** — Read the file. Confirm the logging skill's `allowedTools` (or project-level Bash allowlist) includes `Bash(git rev-parse *)` and `Bash(bash *)`. If missing, add them. The existing broad `Bash(*)` entries may already cover this — do not add redundant entries.

## Verification

```bash
# Unit tests (no Docker, no credentials required)
./tests/run_tests.sh --unit

# Manual smoke tests (run from workspace root)

# List 10 most recent logs (no flags)
bash lib/log-search.sh

# Search by exact date
bash lib/log-search.sh --date 2026-06-24

# Search by relative date
bash lib/log-search.sh --date "last week"

# Search by keyword
bash lib/log-search.sh --keyword "authentication"

# Search by date range
bash lib/log-search.sh --date 2026-06-19..2026-06-25

# Combined: keyword AND date (--and)
bash lib/log-search.sh --keyword "authentication" --date 2026-06-24 --and

# Commit search (uses the most recent commit in the repo)
bash lib/log-search.sh --commit "$(git log --format='%h' -1)"

# Via the logging skill (inside a claude-box session)
/logging search --keyword "rate limit"
/logging search --date "last week"
/logging search --commit abc1234
/logging search --date 2026-06-24 --keyword "architect" --and
```

Expected outcomes:
- All `--unit` tests pass with zero failures
- `--date today` returns logs whose filename starts with today's date in `YYYYMMDD` format
- `--keyword` output shows matching lines indented with `  > `
- `--commit` with a valid hash returns logs created in the 24-hour window before that commit
- Unknown flag prints usage and exits with a non-zero code
- Empty result set prints "No matching decision logs found." and exits 0

## Outcome

**Result:** success

Implemented lib/log-search.sh with --date, --commit, --keyword, --and flags. Added /logging search action. 23 new tests passing.
