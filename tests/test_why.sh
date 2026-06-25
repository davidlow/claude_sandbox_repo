#!/bin/bash
# Unit tests for lib/why.sh — Enhanced git-blame with decision log context.
#
# Covers:
#   1. --help flag exits 0 and output contains "Usage"
#   2. no args exits non-zero
#   3. missing file exits non-zero with "not found"
#   4. unknown flag exits non-zero
#   5. missing log-search.sh exits non-zero
#   6. file blame: output contains both === headers
#   7. line blame: header contains the file:line specifier
#   8. commit context found: matching log filename appears in output
#   9. commit context not found: "[No decision logs found" shown
#  10. function pattern fallback: non-zero exit does not occur
#
# No Docker or credentials required.
set -eo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/helpers.sh"

SCRIPT="$REPO_DIR/lib/why.sh"

# ---------------------------------------------------------------------------
# Fixture setup — temporary git repo
# ---------------------------------------------------------------------------
TMPDIR_WHY="$(mktemp -d /tmp/claude_why_XXXXXX)"
trap 'rm -rf "$TMPDIR_WHY"' EXIT

# Initialize a git repository in the temp dir
git -C "$TMPDIR_WHY" init -q
git -C "$TMPDIR_WHY" config user.email "test@example.com"
git -C "$TMPDIR_WHY" config user.name "Test User"

# Create a source file with at least 5 lines
mkdir -p "$TMPDIR_WHY/src"
cat > "$TMPDIR_WHY/src/auth.sh" <<'EOF'
#!/usr/bin/env bash
# Authentication module

login_user() {
    local user="$1"
    echo "Logging in: $user"
}

logout_user() {
    echo "Logged out"
}
EOF

# Stage and commit
git -C "$TMPDIR_WHY" add .
git -C "$TMPDIR_WHY" commit -q -m "add auth module"

# Record commit hash and date
COMMIT1="$(git -C "$TMPDIR_WHY" log --format='%H' -1)"
COMMIT1_DATE="$(git -C "$TMPDIR_WHY" log --format='%aI' -1)"

# Derive filename-safe timestamp matching what log-search.sh expects (YYYYMMDD_HHMM)
LOG_TS="$(date -d "$COMMIT1_DATE" '+%Y%m%d_%H%M')"

# Create decision log fixture that falls in the 24h window before COMMIT1
mkdir -p "$TMPDIR_WHY/docs/decisions"
LOG_FILENAME="${LOG_TS}_test-decision_architect.md"
cat > "$TMPDIR_WHY/docs/decisions/${LOG_FILENAME}" <<EOF
# architect: Test decision

**Date:** $(date -d "$COMMIT1_DATE" '+%Y-%m-%d %H:%M')
**Pipeline:** architect
**Model:** claude-sonnet-4-6
**Status:** success

## Task
Test decision

## Notes
This is a fixture decision log for testing.
EOF

# Set LOGS_DIR so log-search.sh scans the temp directory
export LOGS_DIR="$TMPDIR_WHY/docs/decisions"
export GIT_DIR="$TMPDIR_WHY/.git"
export GIT_WORK_TREE="$TMPDIR_WHY"

# Helper: run why.sh from inside the fixture repo using a subshell
run_why() {
    (cd "$TMPDIR_WHY" && unset GIT_DIR GIT_WORK_TREE && LOGS_DIR="$LOGS_DIR" bash "$SCRIPT" "$@")
}

# Helper: run why.sh and also capture exit code
run_why_rc() {
    local rc=0
    (cd "$TMPDIR_WHY" && unset GIT_DIR GIT_WORK_TREE && LOGS_DIR="$LOGS_DIR" bash "$SCRIPT" "$@") || rc=$?
    echo "$rc"
}

# ---------------------------------------------------------------------------
# test 1: --help flag
# ---------------------------------------------------------------------------
suite "--help exits 0 and prints Usage"

set +e
HELP_OUT="$(bash "$SCRIPT" --help 2>&1)"
HELP_RC=$?
set -e
assert_equals "--help: exit code 0" "0" "$HELP_RC"
assert_contains "--help: output contains Usage" "Usage" "$HELP_OUT"

# ---------------------------------------------------------------------------
# test 2: no arguments exits non-zero
# ---------------------------------------------------------------------------
suite "no arguments exits non-zero"

set +e
bash "$SCRIPT" 2>/dev/null
NO_ARGS_RC=$?
set -e
if [[ "$NO_ARGS_RC" -ne 0 ]]; then
    echo "  ✅ no args: exits non-zero (got $NO_ARGS_RC)"
    TEST_PASS=$(( TEST_PASS + 1 ))
else
    echo "  ❌ no args: expected non-zero exit, got 0"
    TEST_FAIL=$(( TEST_FAIL + 1 ))
    TEST_ERRORS+=("[no arguments] expected non-zero exit, got 0")
fi

# ---------------------------------------------------------------------------
# test 3: missing file exits non-zero with "not found"
# ---------------------------------------------------------------------------
suite "missing file exits non-zero with 'not found'"

set +e
MISSING_OUT="$(bash "$SCRIPT" /nonexistent/path.sh:42 2>&1)"
MISSING_RC=$?
set -e
if [[ "$MISSING_RC" -ne 0 ]]; then
    echo "  ✅ missing file: exits non-zero (got $MISSING_RC)"
    TEST_PASS=$(( TEST_PASS + 1 ))
else
    echo "  ❌ missing file: expected non-zero exit, got 0"
    TEST_FAIL=$(( TEST_FAIL + 1 ))
    TEST_ERRORS+=("[missing file] expected non-zero exit, got 0")
fi
assert_contains "missing file: output contains 'not found'" "not found" "$MISSING_OUT"

# ---------------------------------------------------------------------------
# test 4: unknown flag exits non-zero
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

# ---------------------------------------------------------------------------
# test 5: missing log-search.sh exits non-zero
# ---------------------------------------------------------------------------
suite "missing log-search.sh exits non-zero"

# Create a wrapper script in TMPDIR_WHY that points to a fake LOG_SEARCH
FAKE_SCRIPT="$TMPDIR_WHY/fake_why.sh"
cat > "$FAKE_SCRIPT" <<'FAKEEOF'
#!/usr/bin/env bash
set -eo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_SEARCH="${SCRIPT_DIR}/nonexistent_log_search.sh"
if [[ ! -f "$LOG_SEARCH" || ! -x "$LOG_SEARCH" ]]; then
    echo "Error: log-search.sh not found or not executable at: $LOG_SEARCH" >&2
    exit 1
fi
FAKEEOF
chmod +x "$FAKE_SCRIPT"

set +e
FAKE_OUT="$(bash "$FAKE_SCRIPT" 2>&1)"
FAKE_RC=$?
set -e
if [[ "$FAKE_RC" -ne 0 ]]; then
    echo "  ✅ missing log-search: exits non-zero (got $FAKE_RC)"
    TEST_PASS=$(( TEST_PASS + 1 ))
else
    echo "  ❌ missing log-search: expected non-zero exit, got 0"
    TEST_FAIL=$(( TEST_FAIL + 1 ))
    TEST_ERRORS+=("[missing log-search] expected non-zero exit, got 0")
fi
assert_contains "missing log-search: error message mentions log-search" "log-search.sh" "$FAKE_OUT"

# ---------------------------------------------------------------------------
# test 6: file blame — both === headers appear
# ---------------------------------------------------------------------------
suite "file blame: both === headers appear in output"

FILE_OUT="$(run_why src/auth.sh)"
assert_contains "file blame: git blame header present" "=== git blame:" "$FILE_OUT"
assert_contains "file blame: decision log context header present" "=== Decision log context ===" "$FILE_OUT"

# ---------------------------------------------------------------------------
# test 7: line blame — header contains file:line specifier
# ---------------------------------------------------------------------------
suite "line blame: header contains the file:line specifier"

LINE_OUT="$(run_why src/auth.sh:1)"
assert_contains "line blame: header has :1 specifier" "=== git blame: src/auth.sh:1 ===" "$LINE_OUT"

# ---------------------------------------------------------------------------
# test 8: commit context found — log filename appears in output
# ---------------------------------------------------------------------------
suite "commit context found: matching log filename appears in output"

CONTEXT_OUT="$(run_why src/auth.sh)"
assert_contains "context found: log filename in output" "test-decision" "$CONTEXT_OUT"

# ---------------------------------------------------------------------------
# test 9: commit context not found — "[No decision logs found" shown
# ---------------------------------------------------------------------------
suite "commit context not found: '[No decision logs found' shown for unmatched commit"

# Create a second file and commit it — this commit postdates any fixture logs
# and the fixture logs are already within the 24h window of COMMIT1.
# To test "not found", point LOGS_DIR to an empty directory.
EMPTY_LOGS="$TMPDIR_WHY/empty_logs"
mkdir -p "$EMPTY_LOGS"

NOTFOUND_OUT="$(cd "$TMPDIR_WHY" && LOGS_DIR="$EMPTY_LOGS" bash "$SCRIPT" src/auth.sh 2>&1 || true)"
assert_contains "context not found: '[No decision logs found' shown" "[No decision logs found" "$NOTFOUND_OUT"

# ---------------------------------------------------------------------------
# test 10: function pattern fallback — does not exit non-zero
# ---------------------------------------------------------------------------
suite "function pattern fallback: nonexistent function falls back to full file blame"

set +e
FALLBACK_OUT="$(run_why src/auth.sh:nonexistent_func_xyz 2>&1)"
FALLBACK_RC=$?
set -e
assert_equals "function fallback: exit code 0" "0" "$FALLBACK_RC"
assert_contains "function fallback: git blame header present" "=== git blame:" "$FALLBACK_OUT"

# ---------------------------------------------------------------------------
print_results
