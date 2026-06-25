#!/bin/bash
# Adversarial unit tests for lib/why.sh — Enhanced git-blame with decision log context.
#
# Covers edge cases and boundary conditions NOT tested in test_why.sh:
#
#  1.  Multiple distinct commits on different lines: both hashes appear in blame output
#  2.  Only the initial commit (^ prefix): ^ is stripped so context lookup succeeds
#  3.  Line number out of range: exits non-zero with a fatal git message
#  4.  Function name that doesn't exist: falls back gracefully, warning on stderr
#  5.  File exists but is not tracked by git: exits non-zero with descriptive error
#  6.  File with no corresponding decision logs: degrades gracefully, shows "[No decision logs"
#  7.  File committed before any decision logs existed: no context, no crash
#  8.  5-commit cap: file with 7 distinct blame commits only generates 5 log lookups
#
# No Docker or credentials required.
set -eo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/helpers.sh"

SCRIPT="$REPO_DIR/lib/why.sh"

# ---------------------------------------------------------------------------
# Global temp dir — cleaned up on exit
# ---------------------------------------------------------------------------
TMPDIR_BASE="$(mktemp -d /tmp/claude_why_adv_XXXXXX)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Helper: initialise a minimal git repo in a subdir
init_repo() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" config user.email "test@example.com"
    git -C "$dir" config user.name "Test User"
}

# Helper: run why.sh from inside a given repo directory
run_why_in() {
    local repo="$1"
    shift
    (cd "$repo" && LOGS_DIR="${LOGS_DIR:-}" bash "$SCRIPT" "$@")
}

# Helper: make a minimal decision log file at an exact YYYYMMDD_HHMM timestamp
make_log() {
    local dir="$1" ts="$2" slug="$3"
    cat > "$dir/${ts}_${slug}_architect.md" <<EOF
# architect: ${slug}

**Date:** $(echo "$ts" | sed 's/_/ /;s/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3/;s/ \([0-9]\{2\}\)\([0-9]\{2\}\)/ \1:\2/')
**Pipeline:** architect
**Model:** claude-sonnet-4-6
**Status:** success

## Task

${slug}
EOF
    # Stamp mtime so ls -t ordering is deterministic
    local yyyymmdd="${ts%%_*}"
    local hhmm="${ts##*_}"
    touch -t "${yyyymmdd}${hhmm}" "$dir/${ts}_${slug}_architect.md"
}

# ===========================================================================
# TEST 1: Multiple distinct commits on different lines
# ===========================================================================
suite "Multiple distinct commits: both commit hashes appear in blame output"

MULTI_DIR="$TMPDIR_BASE/multi"
init_repo "$MULTI_DIR"

# Commit 1: first line
printf 'first_commit_line\n' > "$MULTI_DIR/multi.sh"
git -C "$MULTI_DIR" add .
git -C "$MULTI_DIR" commit -q -m "first commit"
MULTI_COMMIT1="$(git -C "$MULTI_DIR" log --format='%H' -1)"

# Commit 2: add second line
printf 'second_commit_line\n' >> "$MULTI_DIR/multi.sh"
git -C "$MULTI_DIR" add .
git -C "$MULTI_DIR" commit -q -m "second commit"
MULTI_COMMIT2="$(git -C "$MULTI_DIR" log --format='%H' -1)"

# Create empty LOGS_DIR so log lookups don't crash
MULTI_LOGS="$TMPDIR_BASE/multi_logs"
mkdir -p "$MULTI_LOGS"

set +e
MULTI_OUT="$(cd "$MULTI_DIR" && LOGS_DIR="$MULTI_LOGS" bash "$SCRIPT" multi.sh 2>&1)"
MULTI_RC=$?
set -e

assert_equals "multi commit: exits 0" "0" "$MULTI_RC"
assert_contains "multi commit: first commit hash in output (prefix)" "${MULTI_COMMIT1:0:7}" "$MULTI_OUT"
assert_contains "multi commit: second commit hash in output (prefix)" "${MULTI_COMMIT2:0:7}" "$MULTI_OUT"
assert_contains "multi commit: git blame header present" "=== git blame:" "$MULTI_OUT"
assert_contains "multi commit: decision log context header present" "=== Decision log context ===" "$MULTI_OUT"

# ===========================================================================
# TEST 2: Only the initial commit (^ prefix stripping)
# ===========================================================================
suite "Initial commit only: ^ prefix stripped so context lookup succeeds (no crash)"

INIT_DIR="$TMPDIR_BASE/init_only"
init_repo "$INIT_DIR"

printf 'only_line\n' > "$INIT_DIR/only.sh"
git -C "$INIT_DIR" add .
git -C "$INIT_DIR" commit -q -m "init"
INIT_COMMIT="$(git -C "$INIT_DIR" log --format='%H' -1)"

# Verify git blame prefixes this with ^
BLAME_RAW="$(git -C "$INIT_DIR" blame --date=iso-strict only.sh)"
assert_contains "initial commit: ^ prefix present in raw blame" "^" "$BLAME_RAW"

# Create a matching decision log for the commit timestamp so context is found
INIT_COMMIT_DATE="$(git -C "$INIT_DIR" log --format='%aI' -1)"
INIT_LOG_TS="$(date -d "$INIT_COMMIT_DATE" '+%Y%m%d_%H%M')"
INIT_LOGS="$TMPDIR_BASE/init_logs"
mkdir -p "$INIT_LOGS"
make_log "$INIT_LOGS" "$INIT_LOG_TS" "initial-decision"

set +e
INIT_OUT="$(cd "$INIT_DIR" && LOGS_DIR="$INIT_LOGS" bash "$SCRIPT" only.sh 2>&1)"
INIT_RC=$?
set -e

assert_equals "initial commit: exits 0 (no crash from ^ prefix)" "0" "$INIT_RC"
# The commit context block must not produce a 'Warning: could not resolve' message,
# which would happen if the ^ prefix were NOT stripped and the lookup got the wrong hash.
assert_not_contains "initial commit: no 'could not resolve' warning" "could not resolve" "$INIT_OUT"
assert_contains "initial commit: decision log context header present" "=== Decision log context ===" "$INIT_OUT"

# ===========================================================================
# TEST 3: Line number out of range
# ===========================================================================
suite "Line number out of range: exits non-zero"

OOR_DIR="$TMPDIR_BASE/out_of_range"
init_repo "$OOR_DIR"

printf 'line1\nline2\nline3\n' > "$OOR_DIR/short.sh"
git -C "$OOR_DIR" add .
git -C "$OOR_DIR" commit -q -m "add short file"

OOR_LOGS="$TMPDIR_BASE/oor_logs"
mkdir -p "$OOR_LOGS"

set +e
OOR_OUT="$(cd "$OOR_DIR" && LOGS_DIR="$OOR_LOGS" bash "$SCRIPT" short.sh:999 2>&1)"
OOR_RC=$?
set -e

if [[ "$OOR_RC" -ne 0 ]]; then
    echo "  ✅ out-of-range line: exits non-zero (got $OOR_RC)"
    TEST_PASS=$(( TEST_PASS + 1 ))
else
    echo "  ❌ out-of-range line: expected non-zero exit, got 0"
    TEST_FAIL=$(( TEST_FAIL + 1 ))
    TEST_ERRORS+=("[out-of-range line] expected non-zero exit, got 0")
fi

# Boundary: line 3 (valid) should succeed
set +e
VALID_OUT="$(cd "$OOR_DIR" && LOGS_DIR="$OOR_LOGS" bash "$SCRIPT" short.sh:3 2>&1)"
VALID_RC=$?
set -e
assert_equals "in-range line (3): exits 0" "0" "$VALID_RC"
assert_contains "in-range line: git blame header present" "=== git blame: short.sh:3 ===" "$VALID_OUT"

# ===========================================================================
# TEST 4: Function name that doesn't exist in the file
# ===========================================================================
suite "Non-existent function name: falls back gracefully, warning on stderr"

FUNC_DIR="$TMPDIR_BASE/func_miss"
init_repo "$FUNC_DIR"

cat > "$FUNC_DIR/funcs.sh" <<'FUNCEOF'
#!/usr/bin/env bash

real_function() {
    echo "I exist"
}

another_function() {
    echo "Me too"
}
FUNCEOF
git -C "$FUNC_DIR" add .
git -C "$FUNC_DIR" commit -q -m "add functions"

FUNC_LOGS="$TMPDIR_BASE/func_logs"
mkdir -p "$FUNC_LOGS"

set +e
FUNC_OUT="$(cd "$FUNC_DIR" && LOGS_DIR="$FUNC_LOGS" bash "$SCRIPT" funcs.sh:nonexistent_xyz 2>&1)"
FUNC_RC=$?
set -e

assert_equals "nonexistent function: exits 0 (graceful fallback)" "0" "$FUNC_RC"
assert_contains "nonexistent function: Warning in output" "Warning" "$FUNC_OUT"
assert_contains "nonexistent function: fallback blame header present" "=== git blame:" "$FUNC_OUT"

# A real function name should NOT produce a Warning
set +e
REAL_FUNC_OUT="$(cd "$FUNC_DIR" && LOGS_DIR="$FUNC_LOGS" bash "$SCRIPT" funcs.sh:real_function 2>&1)"
REAL_FUNC_RC=$?
set -e
assert_equals "real function: exits 0" "0" "$REAL_FUNC_RC"
assert_not_contains "real function: no fallback Warning" "Warning" "$REAL_FUNC_OUT"
assert_contains "real function: blame header present" "=== git blame:" "$REAL_FUNC_OUT"

# ===========================================================================
# TEST 5: File not tracked by git
# ===========================================================================
suite "File not tracked by git: exits non-zero with descriptive error"

UNTRACKED_DIR="$TMPDIR_BASE/untracked"
init_repo "$UNTRACKED_DIR"

# Create a committed file so the repo is not empty
printf 'committed\n' > "$UNTRACKED_DIR/committed.sh"
git -C "$UNTRACKED_DIR" add .
git -C "$UNTRACKED_DIR" commit -q -m "initial"

# Create a file that exists on disk but is NOT added to git
printf 'untracked content\n' > "$UNTRACKED_DIR/untracked.sh"

UNTRACKED_LOGS="$TMPDIR_BASE/untracked_logs"
mkdir -p "$UNTRACKED_LOGS"

set +e
UNTRACKED_OUT="$(cd "$UNTRACKED_DIR" && LOGS_DIR="$UNTRACKED_LOGS" bash "$SCRIPT" untracked.sh 2>&1)"
UNTRACKED_RC=$?
set -e

if [[ "$UNTRACKED_RC" -ne 0 ]]; then
    echo "  ✅ untracked file: exits non-zero (got $UNTRACKED_RC)"
    TEST_PASS=$(( TEST_PASS + 1 ))
else
    echo "  ❌ untracked file: expected non-zero exit, got 0"
    TEST_FAIL=$(( TEST_FAIL + 1 ))
    TEST_ERRORS+=("[untracked file] expected non-zero exit, got 0")
fi

# The error should come from git, not from why.sh's file-not-found check
# (why.sh only checks if the path exists as a file — untracked.sh does exist)
assert_not_contains "untracked file: not a file-not-found error from why.sh" "Error: file not found" "$UNTRACKED_OUT"

# ===========================================================================
# TEST 6: File with no corresponding decision logs (degrade gracefully)
# ===========================================================================
suite "No decision logs available: degrades gracefully with '[No decision logs found'"

NODECISION_DIR="$TMPDIR_BASE/no_decision"
init_repo "$NODECISION_DIR"

printf 'some content\n' > "$NODECISION_DIR/source.sh"
git -C "$NODECISION_DIR" add .
git -C "$NODECISION_DIR" commit -q -m "add source"

# Point LOGS_DIR to empty directory — no logs at all
NODECISION_LOGS="$TMPDIR_BASE/no_decision_logs"
mkdir -p "$NODECISION_LOGS"

set +e
NODECISION_OUT="$(cd "$NODECISION_DIR" && LOGS_DIR="$NODECISION_LOGS" bash "$SCRIPT" source.sh 2>&1)"
NODECISION_RC=$?
set -e

assert_equals "no decision logs: exits 0 (graceful degradation)" "0" "$NODECISION_RC"
assert_contains "no decision logs: '[No decision logs found' message present" "[No decision logs found" "$NODECISION_OUT"
assert_contains "no decision logs: blame output header still printed" "=== git blame:" "$NODECISION_OUT"
assert_contains "no decision logs: decision log context header still printed" "=== Decision log context ===" "$NODECISION_OUT"

# ===========================================================================
# TEST 7: File committed before any decision logs existed
# ===========================================================================
suite "File committed before decision logs existed: no context found, no crash"

PREDATE_DIR="$TMPDIR_BASE/predate"
init_repo "$PREDATE_DIR"

printf 'old content\n' > "$PREDATE_DIR/old.sh"
git -C "$PREDATE_DIR" add .
git -C "$PREDATE_DIR" commit -q -m "old commit"

OLD_COMMIT_DATE="$(git -C "$PREDATE_DIR" log --format='%aI' -1)"

# Create a LOGS_DIR with a decision log timestamped 99 days in the future
# (i.e., well after the commit — outside the 24h look-back window)
PREDATE_LOGS="$TMPDIR_BASE/predate_logs"
mkdir -p "$PREDATE_LOGS"
FUTURE_TS="$(date -d '+99 days' '+%Y%m%d_%H%M')"
make_log "$PREDATE_LOGS" "$FUTURE_TS" "future-decision"

set +e
PREDATE_OUT="$(cd "$PREDATE_DIR" && LOGS_DIR="$PREDATE_LOGS" bash "$SCRIPT" old.sh 2>&1)"
PREDATE_RC=$?
set -e

assert_equals "pre-date commit: exits 0 (no crash)" "0" "$PREDATE_RC"
assert_contains "pre-date commit: '[No decision logs found' message present" "[No decision logs found" "$PREDATE_OUT"
assert_not_contains "pre-date commit: future log does not appear" "future-decision" "$PREDATE_OUT"
assert_contains "pre-date commit: blame output header still printed" "=== git blame:" "$PREDATE_OUT"

# ===========================================================================
# TEST 8: 5-commit cap when file has more than 5 distinct blame authors
# ===========================================================================
suite "5-commit cap: file with 7 distinct commits generates at most 5 log lookups"

CAP_DIR="$TMPDIR_BASE/cap"
init_repo "$CAP_DIR"

# Build a file with 7 lines, each from a separate commit
CAP_COMMITS=()
for i in 1 2 3 4 5 6 7; do
    printf "line%d_from_commit%d\n" "$i" "$i" >> "$CAP_DIR/many.sh"
    git -C "$CAP_DIR" add .
    git -C "$CAP_DIR" commit -q -m "commit number ${i}"
    CAP_COMMITS+=("$(git -C "$CAP_DIR" log --format='%H' -1)")
done

# Verify blame really shows 7 distinct hashes
BLAME_LINES="$(git -C "$CAP_DIR" blame --date=iso-strict many.sh | awk '{print $1}' | sed 's/^\^//' | sort -u | wc -l)"
assert_equals "cap setup: 7 distinct commits confirmed" "7" "$BLAME_LINES"

# Create a LOGS_DIR with one log per commit (all 7)
CAP_LOGS="$TMPDIR_BASE/cap_logs"
mkdir -p "$CAP_LOGS"
for commit in "${CAP_COMMITS[@]}"; do
    CDATE="$(git -C "$CAP_DIR" log --format='%aI' -1 "$commit")"
    CTS="$(date -d "$CDATE" '+%Y%m%d_%H%M')"
    # Use the commit short hash as slug to make each log uniquely identifiable
    make_log "$CAP_LOGS" "$CTS" "commit-${commit:0:7}"
done

set +e
CAP_OUT="$(cd "$CAP_DIR" && LOGS_DIR="$CAP_LOGS" bash "$SCRIPT" many.sh 2>&1)"
CAP_RC=$?
set -e

assert_equals "5-commit cap: exits 0" "0" "$CAP_RC"

# Count how many "Commit <hash>" lines appear in the decision log context section
# (one per lookup) — should be exactly 5
LOOKUP_COUNT="$(echo "$CAP_OUT" | grep -c '^Commit ' || true)"
assert_equals "5-commit cap: exactly 5 commit lookups performed" "5" "$LOOKUP_COUNT"

# Verify that exactly 5 of the 7 commits were looked up in the context section.
# "Commit <hash> commit number N" lines are the per-commit lookup headers.
LOOKUP_COUNT2="$(echo "$CAP_OUT" | grep -c '^Commit ' || true)"
assert_equals "5-commit cap: exactly 5 hashes processed" "5" "$LOOKUP_COUNT2"

# Verify the git blame section contains all 7 blame lines (one per file line).
# The raw blame output has exactly 7 lines for a 7-line file.
BLAME_LINE_COUNT="$(echo "$CAP_OUT" | awk '/^=== git blame:/{found=1; next} /^$/{if(found){found=0}} found && /\(Test User/{count++} END{print count}' || true)"
assert_equals "5-commit cap: all 7 lines in blame output" "7" "$BLAME_LINE_COUNT"

# ---------------------------------------------------------------------------
print_results
