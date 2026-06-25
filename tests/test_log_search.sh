#!/bin/bash
# Unit tests for lib/log-search.sh — retrospective decision-log search tool.
#
# Covers:
#   1. --date exact: returns matching date only
#   2. --date range: returns logs in range (count check)
#   3. --date today: returns today's logs
#   4. --keyword authentication: returns 2 matching logs
#   5. --keyword redis: returns 2 matching logs
#   6. --keyword nonexistent: prints "No matching" message
#   7. --and mode: date AND keyword intersection
#   8. default (no flags): shows 10 most recent header
#   9. --help: exits 0, output contains "Usage"
#  10. unknown flag: exits non-zero
#
# No Docker or network required.
set -eo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/helpers.sh"

SCRIPT="$REPO_DIR/lib/log-search.sh"

# ---------------------------------------------------------------------------
# Fixture setup
# ---------------------------------------------------------------------------
TMPDIR_BASE="$(mktemp -d /tmp/claude_log_search_XXXXXX)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

export LOGS_DIR="$TMPDIR_BASE"

# Write fixture log files
cat > "$TMPDIR_BASE/20260619_0515_fix-login-bug_qa.md" <<'EOF'
# qa: Fix login bug

**Date:** 2026-06-19 05:15
**Pipeline:** qa
**Model:** claude-sonnet-4-6
**Status:** success

## Task
Fix login bug

## Notes
The authentication flow had an issue.
EOF

cat > "$TMPDIR_BASE/20260620_1400_add-caching-layer_architect.md" <<'EOF'
# architect: Add caching layer

**Date:** 2026-06-20 14:00
**Pipeline:** architect
**Model:** claude-sonnet-4-6
**Status:** success

## Task
Add caching layer

## Notes
Using redis to cache session data.
EOF

cat > "$TMPDIR_BASE/20260624_2001_refactor-database_refactor.md" <<'EOF'
# refactor: Refactor database

**Date:** 2026-06-24 20:01
**Pipeline:** refactor
**Model:** claude-sonnet-4-6
**Status:** failed

## Task
Refactor database

## Notes
The authentication module needs to be updated.
EOF

cat > "$TMPDIR_BASE/20260625_0018_new-feature_architect.md" <<'EOF'
# architect: New feature

**Date:** 2026-06-25 00:18
**Pipeline:** architect
**Model:** claude-sonnet-4-6
**Status:** in-progress

## Task
New feature

## Notes
Working on billing integration.
EOF

cat > "$TMPDIR_BASE/20260625_0037_another-task_qa.md" <<'EOF'
# qa: Another task

**Date:** 2026-06-25 00:37
**Pipeline:** qa
**Model:** claude-sonnet-4-6
**Status:** success

## Task
Another task

## Notes
Testing redis connection pool.
EOF

# Touch files in reverse chronological order so ls -t gives newest-first ordering
touch -t 202606250037 "$TMPDIR_BASE/20260625_0037_another-task_qa.md"
touch -t 202606250018 "$TMPDIR_BASE/20260625_0018_new-feature_architect.md"
touch -t 202606242001 "$TMPDIR_BASE/20260624_2001_refactor-database_refactor.md"
touch -t 202606201400 "$TMPDIR_BASE/20260620_1400_add-caching-layer_architect.md"
touch -t 202606190515 "$TMPDIR_BASE/20260619_0515_fix-login-bug_qa.md"

# ---------------------------------------------------------------------------
# test 1: --date exact
# ---------------------------------------------------------------------------
suite "--date exact date returns only matching file"

OUT="$(LOGS_DIR="$LOGS_DIR" bash "$SCRIPT" --date 2026-06-24)"
assert_contains "date exact: contains 20260624" "20260624_2001" "$OUT"
assert_not_contains "date exact: does not contain 20260619" "20260619" "$OUT"
assert_not_contains "date exact: does not contain 20260625" "20260625" "$OUT"

# ---------------------------------------------------------------------------
# test 2: --date range
# ---------------------------------------------------------------------------
suite "--date range returns logs in the range"

OUT2="$(LOGS_DIR="$LOGS_DIR" bash "$SCRIPT" --date 2026-06-19..2026-06-20)"
SEPARATOR_COUNT="$(echo "$OUT2" | grep -c '^---' || true)"
assert_equals "date range: 2 separators (2 results)" "2" "$SEPARATOR_COUNT"
assert_contains "date range: contains 20260619" "20260619_0515" "$OUT2"
assert_contains "date range: contains 20260620" "20260620_1400" "$OUT2"
assert_not_contains "date range: excludes 20260624" "20260624" "$OUT2"

# ---------------------------------------------------------------------------
# test 3: --date today
# ---------------------------------------------------------------------------
suite "--date today returns only today's logs"

TODAY="$(date '+%Y%m%d')"
OUT3="$(LOGS_DIR="$LOGS_DIR" bash "$SCRIPT" --date today)"

if [[ "$TODAY" == "20260619" || "$TODAY" == "20260620" || "$TODAY" == "20260624" || "$TODAY" == "20260625" ]]; then
    assert_contains "date today: contains today prefix" "$TODAY" "$OUT3"
else
    assert_contains "date today: no matching when today not in fixtures" "No matching" "$OUT3"
fi

# ---------------------------------------------------------------------------
# test 4: --keyword authentication returns 2 files
# ---------------------------------------------------------------------------
suite "--keyword authentication returns 2 matching logs"

OUT4="$(LOGS_DIR="$LOGS_DIR" bash "$SCRIPT" --keyword authentication)"
assert_contains "keyword auth: fix-login-bug present" "fix-login-bug" "$OUT4"
assert_contains "keyword auth: refactor-database present" "refactor-database" "$OUT4"
SEP4="$(echo "$OUT4" | grep -c '^---' || true)"
assert_equals "keyword auth: exactly 2 results" "2" "$SEP4"

# ---------------------------------------------------------------------------
# test 5: --keyword redis returns 2 files
# ---------------------------------------------------------------------------
suite "--keyword redis returns 2 matching logs"

OUT5="$(LOGS_DIR="$LOGS_DIR" bash "$SCRIPT" --keyword redis)"
assert_contains "keyword redis: add-caching-layer present" "add-caching-layer" "$OUT5"
assert_contains "keyword redis: another-task present" "another-task" "$OUT5"
SEP5="$(echo "$OUT5" | grep -c '^---' || true)"
assert_equals "keyword redis: exactly 2 results" "2" "$SEP5"

# Also verify matching lines are indented with "  > "
assert_contains "keyword redis: lines indented with  > " "  > " "$OUT5"

# ---------------------------------------------------------------------------
# test 6: --keyword nonexistent prints no match message
# ---------------------------------------------------------------------------
suite "--keyword nonexistent prints no-match message"

OUT6="$(LOGS_DIR="$LOGS_DIR" bash "$SCRIPT" --keyword nonexistent_term_zzz)"
assert_contains "keyword none: no match message" "No matching decision logs found." "$OUT6"

# ---------------------------------------------------------------------------
# test 7: --and mode: keyword AND date intersection
# ---------------------------------------------------------------------------
suite "--and mode: date AND keyword intersection"

# authentication appears in both 20260619 and 20260624 files.
# With --date 2026-06-19 --keyword authentication --and, only 20260619 should match.
OUT7="$(LOGS_DIR="$LOGS_DIR" bash "$SCRIPT" --keyword authentication --date 2026-06-19 --and)"
assert_contains "and mode: fix-login-bug present" "fix-login-bug" "$OUT7"
assert_not_contains "and mode: refactor-database excluded" "refactor-database" "$OUT7"
SEP7="$(echo "$OUT7" | grep -c '^---' || true)"
assert_equals "and mode: exactly 1 result" "1" "$SEP7"

# ---------------------------------------------------------------------------
# test 8: no flags — default mode shows 10 most recent header
# ---------------------------------------------------------------------------
suite "no flags: default mode prints 'Showing 10 most recent' header"

OUT8="$(LOGS_DIR="$LOGS_DIR" bash "$SCRIPT")"
assert_contains "default: header line present" "Showing 10 most recent" "$OUT8"

# ---------------------------------------------------------------------------
# test 9: --help exits 0 and contains Usage
# ---------------------------------------------------------------------------
suite "--help exits 0 and prints usage"

set +e
HELP_OUT="$(LOGS_DIR="$LOGS_DIR" bash "$SCRIPT" --help 2>&1)"
HELP_RC=$?
set -e
assert_equals "--help: exit code 0" "0" "$HELP_RC"
assert_contains "--help: output contains Usage" "Usage" "$HELP_OUT"

# ---------------------------------------------------------------------------
# test 10: unknown flag exits non-zero
# ---------------------------------------------------------------------------
suite "unknown flag exits non-zero"

set +e
bash "$SCRIPT" --badflag 2>/dev/null
UNKNOWN_RC=$?
set -e
if [[ "$UNKNOWN_RC" -ne 0 ]]; then
    echo "  ✅ unknown flag: exits non-zero (got $UNKNOWN_RC)"
    TEST_PASS=$(( TEST_PASS + 1 ))
else
    echo "  ❌ unknown flag: expected non-zero exit, got 0"
    TEST_FAIL=$(( TEST_FAIL + 1 ))
    TEST_ERRORS+=("[unknown flag] expected non-zero exit, got 0")
fi

print_results
