#!/bin/bash
# Unit tests for lib/gm-status.sh
# No Docker or network required. Uses a temp directory.
set -eo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/helpers.sh"

new_workspace() {
    mktemp -d
}
run_status() {
    local ws="$1"; shift
    (cd "$ws" && bash "$REPO_DIR/lib/gm-status.sh" "$@")
}

# ---------------------------------------------------------------------------
suite "gm-status.sh init — creates correct table structure"
# ---------------------------------------------------------------------------
WS=$(new_workspace)
run_status "$WS" init master 3 "2026-06-28 10:00"

CONTENT=$(cat "$WS/gm-status.md")
assert_contains "init: header title" "# GM Status" "$CONTENT"
assert_contains "init: base branch" "**Base branch:** master" "$CONTENT"
assert_contains "init: progress line" "**Progress:** 0 / 3 tasks complete" "$CONTENT"
assert_contains "init: started timestamp" "**Started:** 2026-06-28 10:00" "$CONTENT"
assert_contains "init: table header" "| # | Skill | Task | Branch | Status |" "$CONTENT"

# Count data rows (lines starting with | N |) — use [|] not \| since GNU grep BRE treats \| as alternation
ROW_COUNT=$(grep -c '^[|] [0-9]' "$WS/gm-status.md" || echo 0)
assert_equals "init: 3 rows created" "3" "$ROW_COUNT"

# All rows should be pending
PENDING_COUNT=$(grep -c '⏳ pending' "$WS/gm-status.md" || echo 0)
assert_equals "init: all 3 rows pending" "3" "$PENDING_COUNT"

rm -rf "$WS"

# ---------------------------------------------------------------------------
suite "gm-status.sh set-task — fills skill and task text for a row"
# ---------------------------------------------------------------------------
WS=$(new_workspace)
run_status "$WS" init master 2 "2026-06-28 10:00"
run_status "$WS" set-task 1 architect "Add user authentication"
run_status "$WS" set-task 2 refactor "Fix login session timeout"

CONTENT=$(cat "$WS/gm-status.md")
assert_contains "set-task: row 1 skill" "architect" "$CONTENT"
assert_contains "set-task: row 1 task text" "Add user authentication" "$CONTENT"
assert_contains "set-task: row 2 skill" "refactor" "$CONTENT"
assert_contains "set-task: row 2 task text" "Fix login session timeout" "$CONTENT"

rm -rf "$WS"

# ---------------------------------------------------------------------------
suite "gm-status.sh update — sets branch and status, updates progress"
# ---------------------------------------------------------------------------
WS=$(new_workspace)
run_status "$WS" init master 3 "2026-06-28 10:00"
run_status "$WS" set-task 1 architect "Add user auth"
run_status "$WS" set-task 2 refactor "Fix login bug"
run_status "$WS" set-task 3 qa "Write tests"

run_status "$WS" update 1 "gm/20260628-add-user-auth" "✅ merged"
CONTENT=$(cat "$WS/gm-status.md")
assert_contains "update: branch filled in" "gm/20260628-add-user-auth" "$CONTENT"
assert_contains "update: status set to merged" "✅ merged" "$CONTENT"
assert_contains "update: progress updated" "1 / 3" "$CONTENT"

run_status "$WS" update 2 "gm/20260628-fix-login" "❌ failed"
CONTENT=$(cat "$WS/gm-status.md")
assert_contains "update: second row branch" "gm/20260628-fix-login" "$CONTENT"
assert_contains "update: second row status" "❌ failed" "$CONTENT"
assert_contains "update: progress shows 2 done" "2 / 3" "$CONTENT"

rm -rf "$WS"

# ---------------------------------------------------------------------------
suite "gm-status.sh update — preserves skill and task text from set-task"
# ---------------------------------------------------------------------------
WS=$(new_workspace)
run_status "$WS" init master 2 "2026-06-28 10:00"
run_status "$WS" set-task 1 architect "Add user auth"
run_status "$WS" update 1 "gm/branch-123" "⚙️ running architect"

CONTENT=$(cat "$WS/gm-status.md")
assert_contains "update: skill preserved" "architect" "$CONTENT"
assert_contains "update: task text preserved" "Add user auth" "$CONTENT"
assert_contains "update: branch set" "gm/branch-123" "$CONTENT"

rm -rf "$WS"

# ---------------------------------------------------------------------------
suite "gm-status.sh done — replaces progress line with COMPLETE"
# ---------------------------------------------------------------------------
WS=$(new_workspace)
run_status "$WS" init master 3 "2026-06-28 10:00"
run_status "$WS" update 1 "branch-1" "✅ merged"
run_status "$WS" update 2 "branch-2" "❌ failed"
run_status "$WS" done 1 1

CONTENT=$(cat "$WS/gm-status.md")
assert_contains "done: COMPLETE status" "**Status: COMPLETE**" "$CONTENT"
assert_contains "done: merged count" "1 merged" "$CONTENT"
assert_contains "done: failed count" "1 failed" "$CONTENT"
assert_not_contains "done: no Progress line" "**Progress:**" "$CONTENT"

rm -rf "$WS"

# ---------------------------------------------------------------------------
suite "gm-status.sh — row N update does not affect other rows"
# ---------------------------------------------------------------------------
WS=$(new_workspace)
run_status "$WS" init master 3 "2026-06-28 10:00"
run_status "$WS" set-task 1 architect "Task one"
run_status "$WS" set-task 2 qa "Task two"
run_status "$WS" set-task 3 refactor "Task three"

run_status "$WS" update 2 "branch-two" "✅ merged"
CONTENT=$(cat "$WS/gm-status.md")

# Row 1 and row 3 should still be pending
assert_contains "isolation: row 1 still pending" "⏳ pending" "$(grep '^[|] 1 ' "$WS/gm-status.md")"
assert_contains "isolation: row 3 still pending" "⏳ pending" "$(grep '^[|] 3 ' "$WS/gm-status.md")"
assert_contains "isolation: row 2 updated" "✅ merged" "$(grep '^[|] 2 ' "$WS/gm-status.md")"

rm -rf "$WS"
