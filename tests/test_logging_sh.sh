#!/bin/bash
# Unit tests for lib/logging.sh
# No Docker or network required. Uses a temp directory as workspace.
set -eo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/helpers.sh"

# Each test runs in its own temp workspace with docs/ pre-created
new_workspace() {
    local tmp
    tmp=$(mktemp -d)
    mkdir -p "$tmp/docs/decisions" "$tmp/docs/progress"
    echo "$tmp"
}
run_log() {
    # run logging.sh from the given workspace dir
    local ws="$1"; shift
    (cd "$ws" && bash "$REPO_DIR/lib/logging.sh" "$@")
}

# ---------------------------------------------------------------------------
suite "logging.sh init — creates log file and sentinels"
# ---------------------------------------------------------------------------
WS=$(new_workspace)
LOG=$(run_log "$WS" init architect "add user auth" claude-sonnet-4-6)

assert_contains "init: log path contains pipeline" "_architect.md" "$LOG"
assert_contains "init: log path contains decisions dir" "docs/decisions/" "$LOG"

FILE_EXISTS="no"
[[ -f "$LOG" ]] && FILE_EXISTS="yes"
assert_equals "init: log file exists" "yes" "$FILE_EXISTS"

CURRENT=$(cat "$WS/docs/.logging-current")
assert_equals "init: .logging-current matches printed path" "$LOG" "$CURRENT"

LAST=$(cat "$WS/docs/.logging-architect-last")
assert_equals "init: .logging-architect-last matches" "$LOG" "$LAST"

HEADER=$(head -1 "$LOG")
assert_equals "init: log header starts with pipeline name" "# architect: add user auth" "$HEADER"

STATUS=$(grep '\*\*Status:\*\*' "$LOG")
assert_contains "init: status is in-progress" "in-progress" "$STATUS"

rm -rf "$WS"

# ---------------------------------------------------------------------------
suite "logging.sh note — appends titled section with text"
# ---------------------------------------------------------------------------
WS=$(new_workspace)
LOG=$(run_log "$WS" init qa "write tests" claude-sonnet-4-6)

run_log "$WS" note "$LOG" "Phase 1 Result" "Tests written and passing"
CONTENT=$(cat "$LOG")
assert_contains "note: section heading present" "## Phase 1 Result" "$CONTENT"
assert_contains "note: text present" "Tests written and passing" "$CONTENT"

rm -rf "$WS"

# ---------------------------------------------------------------------------
suite "logging.sh section — appends content file"
# ---------------------------------------------------------------------------
WS=$(new_workspace)
LOG=$(run_log "$WS" init refactor "fix bug" claude-sonnet-4-6)

echo "candidate 1: minimal patch" > "$WS/candidates.md"
run_log "$WS" section "$LOG" "Phase 1: Diagnosis" "$WS/candidates.md"
CONTENT=$(cat "$LOG")
assert_contains "section: heading present" "## Phase 1: Diagnosis" "$CONTENT"
assert_contains "section: file content appended" "candidate 1: minimal patch" "$CONTENT"

rm -rf "$WS"

# ---------------------------------------------------------------------------
suite "logging.sh section — missing content file uses placeholder"
# ---------------------------------------------------------------------------
WS=$(new_workspace)
LOG=$(run_log "$WS" init architect "task" claude-sonnet-4-6)

run_log "$WS" section "$LOG" "Missing Section" "/nonexistent/file.md"
CONTENT=$(cat "$LOG")
assert_contains "section: placeholder when file missing" "*(not available)*" "$CONTENT"

rm -rf "$WS"

# ---------------------------------------------------------------------------
suite "logging.sh outcome — finalizes log and manages sentinels"
# ---------------------------------------------------------------------------
WS=$(new_workspace)
LOG=$(run_log "$WS" init architect "finalize test" claude-sonnet-4-6)

run_log "$WS" outcome "$LOG" success "all phases complete"

STATUS=$(grep '\*\*Status:\*\*' "$LOG" | head -1)
assert_contains "outcome: status updated from in-progress" "success" "$STATUS"
assert_not_contains "outcome: in-progress removed" "in-progress" "$STATUS"

CONTENT=$(cat "$LOG")
assert_contains "outcome: Outcome section present" "## Outcome" "$CONTENT"
assert_contains "outcome: notes appended" "all phases complete" "$CONTENT"

LAST_COMPLETED=$(cat "$WS/docs/.logging-last-completed" 2>/dev/null || echo "missing")
assert_equals "outcome: .logging-last-completed written" "$LOG" "$LAST_COMPLETED"

ACTIVE_EXISTS="yes"
[[ -f "$WS/docs/.logging-current" ]] || ACTIVE_EXISTS="no"
assert_equals "outcome: .logging-current deleted" "no" "$ACTIVE_EXISTS"

rm -rf "$WS"

# ---------------------------------------------------------------------------
suite "logging.sh progress — writes JSONL event"
# ---------------------------------------------------------------------------
WS=$(new_workspace)
run_log "$WS" progress "brainstorm" "running" "generating 3 candidates"

JSONL="$WS/docs/progress/current.jsonl"
FILE_EXISTS="no"
[[ -f "$JSONL" ]] && FILE_EXISTS="yes"
assert_equals "progress: current.jsonl created" "yes" "$FILE_EXISTS"

LINE=$(cat "$JSONL")
assert_contains "progress: phase field" '"phase":"brainstorm"' "$LINE"
assert_contains "progress: status field" '"status":"running"' "$LINE"
assert_contains "progress: detail field" '"detail":"generating 3 candidates"' "$LINE"
assert_contains "progress: source field" '"source":"skill"' "$LINE"

rm -rf "$WS"

# ---------------------------------------------------------------------------
suite "logging.sh outcome — auto-resolve from .logging-current when '-' passed"
# ---------------------------------------------------------------------------
WS=$(new_workspace)
LOG=$(run_log "$WS" init gm "some task" claude-sonnet-4-6)

run_log "$WS" outcome "-" success
STATUS=$(grep '\*\*Status:\*\*' "$LOG" | head -1)
assert_contains "auto-resolve: status updated" "success" "$STATUS"

rm -rf "$WS"

# ---------------------------------------------------------------------------
suite "logging.sh init — slug truncated to 40 chars"
# ---------------------------------------------------------------------------
WS=$(new_workspace)
LONG_TASK="This is a very long task description that should be truncated in the filename slug"
LOG=$(run_log "$WS" init architect "$LONG_TASK" claude-sonnet-4-6)
FILENAME=$(basename "$LOG")
SLUG=$(echo "$FILENAME" | sed 's/^[0-9_]*//; s/_architect\.md$//')
LEN=${#SLUG}
assert_equals "init: slug is exactly 40 chars" "40" "$LEN"
rm -rf "$WS"
