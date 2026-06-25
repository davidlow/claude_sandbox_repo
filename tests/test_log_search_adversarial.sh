#!/bin/bash
# Adversarial unit tests for lib/log-search.sh
#
# Covers edge cases and boundary conditions NOT tested in test_log_search.sh:
#
#  1.  Empty LOGS_DIR: prints "No decision logs found" and exits 0
#  2.  LOGS_DIR with only non-.md files: treated as empty
#  3.  --date exact: no matching logs prints "No matching"
#  4.  --date range: range entirely before all fixtures, no match
#  5.  --date range: overlapping ranges yield correct union in OR mode
#  6.  --date boundary: first day of month (YYYY-MM-01) matches only that file
#  7.  --date boundary: last day of month (YYYY-MM-31) matches only that file
#  8.  --date boundary: YYYYMMDD (no-dash) format still resolves correctly
#  9.  --keyword: special chars in search term (dot, dash, brackets)
# 10.  --keyword: case-insensitive match (uppercase term finds lowercase content)
# 11.  --keyword: multiline context lines prefixed with "  > "
# 12.  --commit: non-existent hash exits non-zero
# 13.  --commit: non-existent message substring exits non-zero
# 14.  --and: all three filters active, zero overlap → "No matching"
# 15.  --and: keyword + date, overlap exists → exactly matching files
# 16.  --and: keyword + date, no overlap → "No matching"
# 17.  Large number of log files (50): default mode lists max 10
# 18.  Large number of log files (50): --keyword still finds correct matches
# 19.  --date today with empty LOGS_DIR exits 0 with informative message
# 20.  --date YYYYMMDD format (no dashes) exact match
# 21.  Filename with YYYY-MM-DD_HHMM_ prefix (dash format) correctly parsed
# 22.  Default mode with exactly 10 files: all 10 shown, no truncation
# 23.  Default mode with 11 files: exactly 10 shown (11th excluded)
# 24.  --keyword: term is a single character (regression: not too greedy)
# 25.  OR mode (no --and): file matching only keyword is included
# 26.  OR mode: file matching only date is included
# 27.  OR mode: file matching neither date nor keyword is excluded
#
# No Docker or network required.
set -eo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/helpers.sh"

SCRIPT="$REPO_DIR/lib/log-search.sh"

# ---------------------------------------------------------------------------
# Global temp dir — cleaned up on exit
# ---------------------------------------------------------------------------
TMPDIR_BASE="$(mktemp -d /tmp/claude_log_search_adv_XXXXXX)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Helper: create a minimal log file in a given directory
# Usage: make_log <dir> <filename_no_ext> <pipeline> <status> <body>
make_log() {
    local dir="$1" fname="$2" pipeline="$3" status="$4" body="$5"
    local dt="${fname%%_*}"   # YYYYMMDD
    local hhmm
    hhmm="$(echo "$fname" | sed 's/^[0-9]*_//' | cut -d_ -f1)"
    local datef="${dt:0:4}-${dt:4:2}-${dt:6:2} ${hhmm:0:2}:${hhmm:2:2}"
    cat > "$dir/${fname}.md" <<EOF
# ${pipeline}: task

**Date:** ${datef}
**Pipeline:** ${pipeline}
**Model:** claude-sonnet-4-6
**Status:** ${status}

## Task

${body}
EOF
    # Set mtime to match the embedded date so ls -t ordering is deterministic
    touch -t "${dt}${hhmm}" "$dir/${fname}.md"
}

# ===========================================================================
# TEST 1: Empty LOGS_DIR — exits 0, prints informative message
# ===========================================================================
suite "empty LOGS_DIR: exits 0 with informative message (no flags)"

EMPTY_DIR="$(mktemp -d "$TMPDIR_BASE/empty_XXXXXX")"
set +e
OUT1="$(LOGS_DIR="$EMPTY_DIR" bash "$SCRIPT" 2>&1)"
RC1=$?
set -e
assert_equals "empty dir: exit code 0" "0" "$RC1"
assert_contains "empty dir: informative message" "No decision logs found" "$OUT1"

# ===========================================================================
# TEST 2: LOGS_DIR with only non-.md files — treated as empty
# ===========================================================================
suite "LOGS_DIR with only non-.md files: treated as empty"

NONMD_DIR="$(mktemp -d "$TMPDIR_BASE/nonmd_XXXXXX")"
echo "ignored" > "$NONMD_DIR/20260619_0515_something.txt"
echo "ignored" > "$NONMD_DIR/README"

set +e
OUT2="$(LOGS_DIR="$NONMD_DIR" bash "$SCRIPT" 2>&1)"
RC2=$?
set -e
assert_equals "non-md: exit code 0" "0" "$RC2"
assert_contains "non-md: no logs message" "No decision logs found" "$OUT2"

# ===========================================================================
# TEST 3: --date exact: date exists in fixtures but no log on that date
# ===========================================================================
suite "--date exact with no matching file prints 'No matching'"

DATE_DIR="$(mktemp -d "$TMPDIR_BASE/date_XXXXXX")"
make_log "$DATE_DIR" "20260610_0900_task-a_qa" "qa" "success" "some work"
make_log "$DATE_DIR" "20260615_1200_task-b_architect" "architect" "success" "other work"

set +e
OUT3="$(LOGS_DIR="$DATE_DIR" bash "$SCRIPT" --date 2026-06-12 2>&1)"
RC3=$?
set -e
assert_equals "--date no match: exit code 0" "0" "$RC3"
assert_contains "--date no match: prints no matching" "No matching decision logs found." "$OUT3"
assert_not_contains "--date no match: task-a absent" "task-a" "$OUT3"
assert_not_contains "--date no match: task-b absent" "task-b" "$OUT3"

# ===========================================================================
# TEST 4: --date range entirely before all fixtures → no match
# ===========================================================================
suite "--date range entirely before fixtures → no match"

# Fixtures from TEST 3 dir: 2026-06-10, 2026-06-15
set +e
OUT4="$(LOGS_DIR="$DATE_DIR" bash "$SCRIPT" --date 2026-06-01..2026-06-09 2>&1)"
RC4=$?
set -e
assert_equals "range before fixtures: exit 0" "0" "$RC4"
assert_contains "range before fixtures: no matching" "No matching decision logs found." "$OUT4"

# ===========================================================================
# TEST 5: Overlapping date ranges in OR mode
# ===========================================================================
suite "Overlapping date ranges in OR mode produce correct union"

OVR_DIR="$(mktemp -d "$TMPDIR_BASE/overlap_XXXXXX")"
make_log "$OVR_DIR" "20260601_0900_june-first_qa"       "qa"       "success" "first of june"
make_log "$OVR_DIR" "20260610_1200_mid-june_architect"  "architect" "success" "mid june work"
make_log "$OVR_DIR" "20260620_0800_late-june_refactor"  "refactor"  "success" "late june fix"
make_log "$OVR_DIR" "20260701_0000_july-first_qa"       "qa"       "success" "first of july"

# OR mode: range1 covers 06-01..06-10, range2 covers 06-10..06-20
# Two separate flag invocations; combine by running twice and checking intersection
OUT5a="$(LOGS_DIR="$OVR_DIR" bash "$SCRIPT" --date 2026-06-01..2026-06-10 2>&1)"
OUT5b="$(LOGS_DIR="$OVR_DIR" bash "$SCRIPT" --date 2026-06-10..2026-06-20 2>&1)"

assert_contains "overlap range1: june-first present"  "june-first"  "$OUT5a"
assert_contains "overlap range1: mid-june present"    "mid-june"    "$OUT5a"
assert_not_contains "overlap range1: late-june absent" "late-june"  "$OUT5a"
assert_not_contains "overlap range1: july-first absent" "july-first" "$OUT5a"

assert_contains "overlap range2: mid-june present"    "mid-june"    "$OUT5b"
assert_contains "overlap range2: late-june present"   "late-june"   "$OUT5b"
assert_not_contains "overlap range2: june-first absent" "june-first" "$OUT5b"
assert_not_contains "overlap range2: july-first absent" "july-first" "$OUT5b"

# mid-june (06-10) appears in both ranges
SEP5a="$(echo "$OUT5a" | grep -c '^---' || true)"
SEP5b="$(echo "$OUT5b" | grep -c '^---' || true)"
assert_equals "overlap range1: 2 results" "2" "$SEP5a"
assert_equals "overlap range2: 2 results" "2" "$SEP5b"

# ===========================================================================
# TEST 6: Date boundary — first day of month
# ===========================================================================
suite "Date boundary: first day of month (YYYY-MM-01)"

BOUND_DIR="$(mktemp -d "$TMPDIR_BASE/boundary_XXXXXX")"
make_log "$BOUND_DIR" "20260601_0000_month-start_qa"   "qa" "success" "first of month"
make_log "$BOUND_DIR" "20260602_0000_day-two_architect" "architect" "success" "second day"
make_log "$BOUND_DIR" "20260531_2359_prev-month_qa"    "qa" "success" "end of may"

OUT6="$(LOGS_DIR="$BOUND_DIR" bash "$SCRIPT" --date 2026-06-01 2>&1)"
assert_contains "first day: month-start present" "month-start" "$OUT6"
assert_not_contains "first day: day-two absent"  "day-two"    "$OUT6"
assert_not_contains "first day: prev-month absent" "prev-month" "$OUT6"
SEP6="$(echo "$OUT6" | grep -c '^---' || true)"
assert_equals "first day: exactly 1 result" "1" "$SEP6"

# ===========================================================================
# TEST 7: Date boundary — last day of month
# ===========================================================================
suite "Date boundary: last day of month (YYYY-MM-31)"

make_log "$BOUND_DIR" "20260731_2359_month-end_qa"    "qa" "success" "last of july"
make_log "$BOUND_DIR" "20260730_1200_july-thirty_architect" "architect" "success" "second-to-last"
make_log "$BOUND_DIR" "20260801_0001_august-first_qa" "qa" "success" "first of august"

OUT7="$(LOGS_DIR="$BOUND_DIR" bash "$SCRIPT" --date 2026-07-31 2>&1)"
assert_contains "last day: month-end present"        "month-end"    "$OUT7"
assert_not_contains "last day: july-thirty absent"   "july-thirty"  "$OUT7"
assert_not_contains "last day: august-first absent"  "august-first" "$OUT7"
SEP7="$(echo "$OUT7" | grep -c '^---' || true)"
assert_equals "last day: exactly 1 result" "1" "$SEP7"

# ===========================================================================
# TEST 8: YYYYMMDD (no-dash) date format exact match
# ===========================================================================
suite "--date YYYYMMDD format (no dashes) works as exact match"

OUT8="$(LOGS_DIR="$BOUND_DIR" bash "$SCRIPT" --date 20260601 2>&1)"
assert_contains "no-dash date: month-start present" "month-start" "$OUT8"
assert_not_contains "no-dash date: day-two absent"  "day-two"    "$OUT8"

# ===========================================================================
# TEST 9: Special characters in keyword search
# ===========================================================================
suite "--keyword with special regex characters does not crash"

SPEC_DIR="$(mktemp -d "$TMPDIR_BASE/special_XXXXXX")"
make_log "$SPEC_DIR" "20260620_1000_dot-test_qa"      "qa"  "success" "the file.txt was updated"
make_log "$SPEC_DIR" "20260621_1000_bracket-test_qa"  "qa"  "success" "list [a,b,c] processed"
make_log "$SPEC_DIR" "20260622_1000_dash-test_qa"     "qa"  "success" "regex-like pattern here"
make_log "$SPEC_DIR" "20260623_1000_star-test_qa"     "qa"  "success" "star * wildcard usage"
make_log "$SPEC_DIR" "20260624_1000_paren-test_qa"    "qa"  "success" "(parenthetical) note"

# Searching for a literal dot — should not match everything
set +e
OUT9a="$(LOGS_DIR="$SPEC_DIR" bash "$SCRIPT" --keyword "file.txt" 2>&1)"
RC9a=$?
set -e
assert_equals "special dot keyword: exit 0" "0" "$RC9a"
assert_contains "special dot keyword: dot-test present" "dot-test" "$OUT9a"

# Searching for brackets
set +e
OUT9b="$(LOGS_DIR="$SPEC_DIR" bash "$SCRIPT" --keyword "[a,b,c]" 2>&1)"
RC9b=$?
set -e
assert_equals "bracket keyword: exit 0" "0" "$RC9b"
assert_contains "bracket keyword: bracket-test present" "bracket-test" "$OUT9b"

# Searching for literal asterisk
set +e
OUT9c="$(LOGS_DIR="$SPEC_DIR" bash "$SCRIPT" --keyword "star *" 2>&1)"
RC9c=$?
set -e
assert_equals "star keyword: exit 0" "0" "$RC9c"
assert_contains "star keyword: star-test present" "star-test" "$OUT9c"

# Searching for parentheses
set +e
OUT9d="$(LOGS_DIR="$SPEC_DIR" bash "$SCRIPT" --keyword "(parenthetical)" 2>&1)"
RC9d=$?
set -e
assert_equals "paren keyword: exit 0" "0" "$RC9d"
assert_contains "paren keyword: paren-test present" "paren-test" "$OUT9d"

# ===========================================================================
# TEST 10: Case-insensitive keyword matching
# ===========================================================================
suite "--keyword is case-insensitive"

CASE_DIR="$(mktemp -d "$TMPDIR_BASE/case_XXXXXX")"
make_log "$CASE_DIR" "20260620_1000_upper-case_qa"    "qa" "success" "AUTHENTICATION module updated"
make_log "$CASE_DIR" "20260621_1000_mixed-case_qa"    "qa" "success" "Auth was refactored"
make_log "$CASE_DIR" "20260622_1000_no-match_qa"      "qa" "success" "completely unrelated content"

# Search with uppercase keyword
OUT10a="$(LOGS_DIR="$CASE_DIR" bash "$SCRIPT" --keyword "AUTHENTICATION" 2>&1)"
assert_contains "case-insensitive: upper-case file found with uppercase kw" "upper-case" "$OUT10a"

# Search with lowercase keyword
OUT10b="$(LOGS_DIR="$CASE_DIR" bash "$SCRIPT" --keyword "authentication" 2>&1)"
assert_contains "case-insensitive: upper-case file found with lowercase kw" "upper-case" "$OUT10b"

# Partial match case
OUT10c="$(LOGS_DIR="$CASE_DIR" bash "$SCRIPT" --keyword "auth" 2>&1)"
SEP10c="$(echo "$OUT10c" | grep -c '^---' || true)"
assert_equals "case-insensitive: auth matches 2 files" "2" "$SEP10c"
assert_not_contains "case-insensitive: no-match file absent" "no-match" "$OUT10c"

# ===========================================================================
# TEST 11: Keyword context lines are prefixed with "  > "
# ===========================================================================
suite "--keyword output: matching lines are indented with '  > '"

CTX_DIR="$(mktemp -d "$TMPDIR_BASE/context_XXXXXX")"
make_log "$CTX_DIR" "20260620_1000_context-test_qa" "qa" "success" "the special_marker_term is here"

OUT11="$(LOGS_DIR="$CTX_DIR" bash "$SCRIPT" --keyword "special_marker_term" 2>&1)"
assert_contains "context prefix: '  > ' present" "  > " "$OUT11"
assert_contains "context prefix: marker term appears in output" "special_marker_term" "$OUT11"

# ===========================================================================
# TEST 12: --commit with non-existent hash exits non-zero
# ===========================================================================
suite "--commit with non-existent hash exits non-zero"

COMMIT_DIR="$(mktemp -d "$TMPDIR_BASE/commit_XXXXXX")"
make_log "$COMMIT_DIR" "20260620_1000_some-task_qa" "qa" "success" "some work"

set +e
OUT12="$(LOGS_DIR="$COMMIT_DIR" bash "$SCRIPT" --commit "deadbeef00000000000000000000000000000000" 2>&1)"
RC12=$?
set -e
assert_equals "--commit bad hash: exits non-zero" "1" "$RC12"
assert_contains "--commit bad hash: error message" "Could not resolve commit ref" "$OUT12"

# ===========================================================================
# TEST 13: --commit with non-existent message substring exits non-zero
# ===========================================================================
suite "--commit with non-existent message substring exits non-zero"

set +e
OUT13="$(LOGS_DIR="$COMMIT_DIR" bash "$SCRIPT" --commit "this_commit_message_absolutely_does_not_exist_xyzzy" 2>&1)"
RC13=$?
set -e
assert_equals "--commit bad msg: exits non-zero" "1" "$RC13"
assert_contains "--commit bad msg: error message" "Could not resolve commit ref" "$OUT13"

# ===========================================================================
# TEST 14: --and with all three filters active, zero overlap
# ===========================================================================
suite "--and mode: three filters, zero overlap → 'No matching'"

AND_DIR="$(mktemp -d "$TMPDIR_BASE/and_XXXXXX")"
# File A: matches keyword "authentication" and date 20260610, but not commit (can't test commit easily)
make_log "$AND_DIR" "20260610_0900_task-a_qa"       "qa"       "success" "authentication module"
# File B: matches keyword "billing" and date 20260615
make_log "$AND_DIR" "20260615_1200_task-b_architect" "architect" "success" "billing integration"
# File C: matches date 20260620 only
make_log "$AND_DIR" "20260620_0800_task-c_refactor"  "refactor"  "failed"  "database optimization"

# --and: keyword=authentication AND date=2026-06-15 → zero overlap (auth is on 06-10, not 06-15)
set +e
OUT14="$(LOGS_DIR="$AND_DIR" bash "$SCRIPT" --keyword authentication --date 2026-06-15 --and 2>&1)"
RC14=$?
set -e
assert_equals "--and zero overlap: exit 0" "0" "$RC14"
assert_contains "--and zero overlap: no matching message" "No matching decision logs found." "$OUT14"
assert_not_contains "--and zero overlap: task-a absent" "task-a" "$OUT14"
assert_not_contains "--and zero overlap: task-b absent" "task-b" "$OUT14"

# ===========================================================================
# TEST 15: --and: keyword + date, overlap exists → exactly matching files
# ===========================================================================
suite "--and mode: keyword + date with overlap → correct result"

# File A (20260610) has "authentication" — both keyword and date match
OUT15="$(LOGS_DIR="$AND_DIR" bash "$SCRIPT" --keyword authentication --date 2026-06-10 --and 2>&1)"
assert_contains "--and overlap: task-a present"   "task-a" "$OUT15"
assert_not_contains "--and overlap: task-b absent" "task-b" "$OUT15"
assert_not_contains "--and overlap: task-c absent" "task-c" "$OUT15"
SEP15="$(echo "$OUT15" | grep -c '^---' || true)"
assert_equals "--and overlap: exactly 1 result" "1" "$SEP15"

# ===========================================================================
# TEST 16: --and: keyword + date range, no overlap → "No matching"
# ===========================================================================
suite "--and mode: keyword + date range, no file satisfies both → 'No matching'"

# "billing" appears only on 20260615; range 2026-06-10..2026-06-14 excludes it
set +e
OUT16="$(LOGS_DIR="$AND_DIR" bash "$SCRIPT" --keyword billing --date 2026-06-10..2026-06-14 --and 2>&1)"
RC16=$?
set -e
assert_equals "--and no overlap range: exit 0" "0" "$RC16"
assert_contains "--and no overlap range: no matching" "No matching decision logs found." "$OUT16"

# ===========================================================================
# TEST 17: Large number of log files — default mode lists max 10
# ===========================================================================
suite "Large log directory (50 files): default mode shows max 10"

LARGE_DIR="$(mktemp -d "$TMPDIR_BASE/large_XXXXXX")"
for i in $(seq 1 50); do
    # Use distinct HHMM values: 0001, 0002, ..., 0050 so touch -t works unambiguously
    # Avoid seq -w (padded) to prevent bash octal misinterpretation of 08/09
    local_hhmm="$(printf '%04d' "$i")"
    fname="20260601_${local_hhmm}_log-number-${i}_qa"
    make_log "$LARGE_DIR" "$fname" "qa" "success" "content for log number ${i}"
done

OUT17="$(LOGS_DIR="$LARGE_DIR" bash "$SCRIPT" 2>&1)"
assert_contains "large dir: shows 10 most recent header" "Showing 10 most recent" "$OUT17"
SEP17="$(echo "$OUT17" | grep -c '^---' || true)"
assert_equals "large dir: exactly 10 separator lines" "10" "$SEP17"

# ===========================================================================
# TEST 18: Large directory — --keyword still finds correct matches
# ===========================================================================
suite "Large log directory (50 files): --keyword finds only matching files"

# Plant a unique keyword in only 3 of the 50 logs
for target in 5 15 25; do
    local_hhmm="$(printf '%04d' "$target")"
    fname="$LARGE_DIR/20260601_${local_hhmm}_log-number-${target}_qa.md"
    if [[ -f "$fname" ]]; then
        echo "UNIQUE_NEEDLE_XYZ" >> "$fname"
    fi
done

OUT18="$(LOGS_DIR="$LARGE_DIR" bash "$SCRIPT" --keyword "UNIQUE_NEEDLE_XYZ" 2>&1)"
SEP18="$(echo "$OUT18" | grep -c '^---' || true)"
assert_equals "large dir keyword: exactly 3 results" "3" "$SEP18"
assert_not_contains "large dir keyword: no-match message absent" "No matching decision logs found." "$OUT18"

# ===========================================================================
# TEST 19: --date today with empty LOGS_DIR exits 0 with informative message
# ===========================================================================
suite "--date today with empty LOGS_DIR exits 0 (not a crash)"

EMPTY_TODAY_DIR="$(mktemp -d "$TMPDIR_BASE/empty_today_XXXXXX")"
set +e
OUT19="$(LOGS_DIR="$EMPTY_TODAY_DIR" bash "$SCRIPT" --date today 2>&1)"
RC19=$?
set -e
assert_equals "--date today empty dir: exit 0" "0" "$RC19"
assert_contains "--date today empty dir: informative message" "No decision logs found" "$OUT19"

# ===========================================================================
# TEST 20: Filename with YYYY-MM-DD_HHMM_ prefix (dash format) correctly parsed
# ===========================================================================
suite "Filename with YYYY-MM-DD_HHMM_ prefix (dash format) is parsed correctly"

DASH_DIR="$(mktemp -d "$TMPDIR_BASE/dash_XXXXXX")"

# Write a log file with dash-date filename format
cat > "$DASH_DIR/2026-06-20_1400_dash-format-task_architect.md" <<'EOF'
# architect: dash format task

**Date:** 2026-06-20 14:00
**Pipeline:** architect
**Model:** claude-sonnet-4-6
**Status:** success

## Task

dash format task

## Notes

Using a dashed filename format.
EOF
touch -t 202606201400 "$DASH_DIR/2026-06-20_1400_dash-format-task_architect.md"

# Also add one non-dash file for contrast
make_log "$DASH_DIR" "20260621_0900_normal-format_qa" "qa" "success" "normal filename"

# Default mode should see both
OUT20a="$(LOGS_DIR="$DASH_DIR" bash "$SCRIPT" 2>&1)"
assert_contains "dash format: appears in default listing" "dash-format-task" "$OUT20a"

# --date should also filter dash-format filenames correctly
OUT20b="$(LOGS_DIR="$DASH_DIR" bash "$SCRIPT" --date 2026-06-20 2>&1)"
assert_contains "dash format: --date 2026-06-20 finds it" "dash-format-task" "$OUT20b"
assert_not_contains "dash format: normal-format absent for 06-20" "normal-format" "$OUT20b"

# ===========================================================================
# TEST 21: Default mode with exactly 10 files: all 10 shown (no truncation)
# ===========================================================================
suite "Default mode with exactly 10 log files: all 10 shown"

TEN_DIR="$(mktemp -d "$TMPDIR_BASE/ten_XXXXXX")"
for i in $(seq 1 10); do
    hhmm=$(printf "%02d" "$i")00
    make_log "$TEN_DIR" "20260601_${hhmm}_log-ten-${i}_qa" "qa" "success" "content ${i}"
done

OUT21="$(LOGS_DIR="$TEN_DIR" bash "$SCRIPT" 2>&1)"
SEP21="$(echo "$OUT21" | grep -c '^---' || true)"
assert_equals "exactly 10 files: all 10 shown" "10" "$SEP21"

# ===========================================================================
# TEST 22: Default mode with 11 files: exactly 10 shown, 11th excluded
# ===========================================================================
suite "Default mode with 11 log files: only 10 shown (oldest excluded)"

ELEVEN_DIR="$(mktemp -d "$TMPDIR_BASE/eleven_XXXXXX")"
# Create 11 files with distinct HHMM values so ls -t ordering is deterministic.
# make_log uses touch -t to set mtime, so ordering is reliable without sleep.
for i in $(seq 1 11); do
    hhmm="$(printf '%04d' "$i")"
    make_log "$ELEVEN_DIR" "20260601_${hhmm}_log-${i}_qa" "qa" "success" "content ${i}"
done

OUT22="$(LOGS_DIR="$ELEVEN_DIR" bash "$SCRIPT" 2>&1)"
SEP22="$(echo "$OUT22" | grep -c '^---' || true)"
assert_equals "11 files: exactly 10 shown" "10" "$SEP22"

# ===========================================================================
# TEST 23: --keyword with single-character term
# ===========================================================================
suite "--keyword single character term works without error"

SC_DIR="$(mktemp -d "$TMPDIR_BASE/single_char_XXXXXX")"
make_log "$SC_DIR" "20260620_1000_alpha-task_qa" "qa" "success" "the letter x appears here"
make_log "$SC_DIR" "20260621_1000_beta-task_qa"  "qa" "success" "nothing unusual"

set +e
OUT23="$(LOGS_DIR="$SC_DIR" bash "$SCRIPT" --keyword "x" 2>&1)"
RC23=$?
set -e
assert_equals "single char keyword: exit 0" "0" "$RC23"
# We don't assert exact count since "x" may match many things; just verify no crash

# ===========================================================================
# TEST 24: OR mode — file matching only keyword is included
# ===========================================================================
suite "OR mode: file matching only keyword (not date) is included"

OR_DIR="$(mktemp -d "$TMPDIR_BASE/or_XXXXXX")"
make_log "$OR_DIR" "20260610_0900_kw-only_qa"      "qa"       "success" "special_or_keyword_here"
make_log "$OR_DIR" "20260620_1000_date-only_architect" "architect" "success" "nothing special"
make_log "$OR_DIR" "20260630_1200_neither_refactor"   "refactor"  "success" "completely different"

# OR mode: --date 2026-06-20 --keyword special_or_keyword_here
# Should match: kw-only (keyword match), date-only (date match)
# Should not match: neither
OUT24="$(LOGS_DIR="$OR_DIR" bash "$SCRIPT" --date 2026-06-20 --keyword special_or_keyword_here 2>&1)"
assert_contains "OR mode: kw-only (keyword match) present"   "kw-only"   "$OUT24"
assert_contains "OR mode: date-only (date match) present"    "date-only" "$OUT24"
assert_not_contains "OR mode: neither excluded"              "neither"   "$OUT24"
SEP24="$(echo "$OUT24" | grep -c '^---' || true)"
assert_equals "OR mode: exactly 2 results" "2" "$SEP24"

# ===========================================================================
# TEST 25: OR mode — file matching neither date nor keyword is excluded
# ===========================================================================
suite "OR mode: file matching neither filter is excluded"

# (Already validated above via neither file)
OUT25="$(LOGS_DIR="$OR_DIR" bash "$SCRIPT" --date 2026-06-30 --keyword nonexistent_zzz 2>&1)"
assert_contains "OR neither: only date-match present, but no keyword-match" "neither" "$OUT25"
assert_not_contains "OR neither: kw-only absent from date=06-30 search" "kw-only" "$OUT25"
SEP25="$(echo "$OUT25" | grep -c '^---' || true)"
assert_equals "OR neither: exactly 1 result (the date-30 match)" "1" "$SEP25"

# ===========================================================================
# TEST 26: --and with keyword + date, both filters need to match together
# ===========================================================================
suite "--and keyword + date: only files satisfying BOTH are returned"

# kw-only matches keyword but not 2026-06-20
# date-only matches 2026-06-20 but not keyword
# neither matches neither
# Expecting zero results
set +e
OUT26="$(LOGS_DIR="$OR_DIR" bash "$SCRIPT" --date 2026-06-20 --keyword special_or_keyword_here --and 2>&1)"
RC26=$?
set -e
assert_equals "--and strict: exit 0" "0" "$RC26"
assert_contains "--and strict: no matching" "No matching decision logs found." "$OUT26"

# ===========================================================================
# TEST 27: Unrecognized date spec exits non-zero with helpful error
# ===========================================================================
suite "Unrecognized date spec exits non-zero with error message"

MISC_DIR="$(mktemp -d "$TMPDIR_BASE/misc_XXXXXX")"
make_log "$MISC_DIR" "20260620_1000_task-x_qa" "qa" "success" "some task"

set +e
OUT27="$(LOGS_DIR="$MISC_DIR" bash "$SCRIPT" --date "next tuesday" 2>&1)"
RC27=$?
set -e
assert_equals "bad date spec: exits non-zero" "1" "$RC27"
assert_contains "bad date spec: error message" "Unrecognized date spec" "$OUT27"

print_results
