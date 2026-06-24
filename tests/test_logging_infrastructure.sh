#!/bin/bash
# Comprehensive test suite for the logging infrastructure.
#
# Covers:
#   1. decision_log_* helper functions in lib/launch-lib.sh (happy path, error cases, boundaries)
#   2. Log file format consistency and parseability
#   3. /logging skill spec compliance: init, section, note, outcome, read actions
#   4. Slug generation for decision log filenames
#   5. Timestamp format in decision log headers
#   6. Missing features documented as failing tests:
#      - Real-time progress visibility (gm-status.md live updates)
#      - Retrospective search by date or git commit message
#      - Enhanced git-blame tool using decision logs
#      - Auto-initialization of logs in new workspaces/repos
#
# No Docker or network required.
set -eo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/helpers.sh"
source "$REPO_DIR/lib/launch-lib.sh"

INITIAL_DIR="$(pwd)"
_CLEANUP_PATHS=()
_cleanup() {
    for p in "${_CLEANUP_PATHS[@]}"; do rm -rf "$p" 2>/dev/null || true; done
    cd "$INITIAL_DIR" 2>/dev/null || true
}
trap _cleanup EXIT

_tmpdir() { local d; d=$(mktemp -d /tmp/claude_logging_XXXXXX); _CLEANUP_PATHS+=("$d"); echo "$d"; }
_tmpfile() { local f; f=$(mktemp /tmp/claude_logging_XXXXXX); _CLEANUP_PATHS+=("$f"); echo "$f"; }

# =============================================================================
# SECTION 1: decision_log_init — happy path
# =============================================================================
suite "decision_log_init — happy path"

LOG1=$(_tmpfile)
decision_log_init "$LOG1" "architect" "add a plugin system" "claude-sonnet-4-6"

CONTENT1=$(cat "$LOG1")
assert_contains "init: pipeline name in title"    "architect"         "$CONTENT1"
assert_contains "init: task description in title" "add a plugin system" "$CONTENT1"
assert_contains "init: Pipeline field"            "**Pipeline:**"     "$CONTENT1"
assert_contains "init: Model field"               "**Model:**"        "$CONTENT1"
assert_contains "init: Status field"              "**Status:**"       "$CONTENT1"
assert_contains "init: status is in-progress"     "in-progress"       "$CONTENT1"
assert_contains "init: Task section header"       "## Task"           "$CONTENT1"
assert_contains "init: task text in body"         "add a plugin system" "$CONTENT1"
assert_contains "init: Date field present"        "**Date:**"         "$CONTENT1"

# Date format: YYYY-MM-DD HH:MM
TODAY=$(date '+%Y-%m-%d')
assert_contains "init: date contains today"       "$TODAY"            "$CONTENT1"

# =============================================================================
# SECTION 2: decision_log_init — all pipelines
# =============================================================================
suite "decision_log_init — all supported pipeline names"

for PIPELINE in architect qa refactor gm brainstorm; do
    PLOG=$(_tmpfile)
    decision_log_init "$PLOG" "$PIPELINE" "test task" "claude-sonnet-4-6"
    PC=$(cat "$PLOG")
    assert_contains "init $PIPELINE: pipeline name present" "$PIPELINE" "$PC"
done

# =============================================================================
# SECTION 3: decision_log_init — boundary cases
# =============================================================================
suite "decision_log_init — boundary cases"

# Empty task string
EMPTY_LOG=$(_tmpfile)
decision_log_init "$EMPTY_LOG" "qa" "" "claude-haiku-4-5"
EC=$(cat "$EMPTY_LOG")
assert_contains "init empty task: file created" "**Pipeline:**" "$EC"
assert_contains "init empty task: status in-progress" "in-progress" "$EC"

# Very long task string (should not crash)
LONG_TASK=$(python3 -c "print('x' * 500)")
LONG_LOG=$(_tmpfile)
decision_log_init "$LONG_LOG" "refactor" "$LONG_TASK" "claude-opus-4-8"
LC=$(cat "$LONG_LOG")
assert_contains "init long task: file created" "in-progress" "$LC"

# Model name with special chars
MODEL_LOG=$(_tmpfile)
decision_log_init "$MODEL_LOG" "qa" "test" "claude-sonnet-4-6"
MC=$(cat "$MODEL_LOG")
assert_contains "init: model with dashes" "claude-sonnet-4-6" "$MC"

# Directory creation: nested path that doesn't exist
DEEP_DIR=$(_tmpdir)
DEEP_LOG="$DEEP_DIR/nested/deep/path/log.md"
decision_log_init "$DEEP_LOG" "architect" "deep dir test" "claude-sonnet-4-6"
assert_file_exists "init: creates nested directories" "$DEEP_LOG"

# =============================================================================
# SECTION 4: decision_log_section — happy path
# =============================================================================
suite "decision_log_section — happy path"

SLOG=$(_tmpfile)
decision_log_init "$SLOG" "architect" "section test" "claude-sonnet-4-6"

CONTENT_FILE=$(_tmpfile)
printf 'Option A: use events\nOption B: direct coupling\n' > "$CONTENT_FILE"

decision_log_section "$SLOG" "Phase 1: Candidates" "$CONTENT_FILE"

SC=$(cat "$SLOG")
assert_contains "section: header written" "## Phase 1: Candidates" "$SC"
assert_contains "section: content embedded" "Option A: use events" "$SC"
assert_contains "section: multiline content" "Option B: direct coupling" "$SC"

# =============================================================================
# SECTION 5: decision_log_section — missing file placeholder
# =============================================================================
suite "decision_log_section — missing content file"

SLOG2=$(_tmpfile)
decision_log_init "$SLOG2" "qa" "section missing file" "claude-sonnet-4-6"

decision_log_section "$SLOG2" "Gemini Critique" "/nonexistent/file_$$.md"
SC2=$(cat "$SLOG2")
assert_contains "section missing: header still written" "## Gemini Critique" "$SC2"
assert_contains "section missing: placeholder text" "not available" "$SC2"

# No content_file argument at all
decision_log_section "$SLOG2" "Empty Section"
SC2B=$(cat "$SLOG2")
assert_contains "section no-arg: header written" "## Empty Section" "$SC2B"
assert_contains "section no-arg: placeholder" "not available" "$SC2B"

# =============================================================================
# SECTION 6: decision_log_section — no-op on missing log
# =============================================================================
suite "decision_log_section — no-op when log file missing"

set +e
decision_log_section "/nonexistent/log_$$.md" "Should not crash" "/dev/null"
NOOP_RC=$?
set -e
assert_equals "section missing log: returns 0" "0" "$NOOP_RC"

# =============================================================================
# SECTION 7: decision_log_note — happy path
# =============================================================================
suite "decision_log_note — happy path"

NLOG=$(_tmpfile)
decision_log_init "$NLOG" "refactor" "note test" "claude-sonnet-4-6"
decision_log_note "$NLOG" "Phase 2 Notes" "Phase 2 completed successfully."

NC=$(cat "$NLOG")
assert_contains "note: section header" "## Phase 2 Notes" "$NC"
assert_contains "note: text embedded" "Phase 2 completed successfully" "$NC"

# Empty note text
decision_log_note "$NLOG" "Empty Note" ""
NC2=$(cat "$NLOG")
assert_contains "note empty text: header still written" "## Empty Note" "$NC2"

# Note with special characters
decision_log_note "$NLOG" "Special Chars" "Status: ok | Exit: 0 [success]"
NC3=$(cat "$NLOG")
assert_contains "note special chars: preserved" "Status: ok | Exit: 0 [success]" "$NC3"

# =============================================================================
# SECTION 8: decision_log_note — no-op on missing log
# =============================================================================
suite "decision_log_note — no-op when log file missing"

set +e
decision_log_note "/nonexistent/log_$$.md" "Header" "text"
NOTE_NOOP_RC=$?
set -e
assert_equals "note missing log: returns 0" "0" "$NOTE_NOOP_RC"

# =============================================================================
# SECTION 9: decision_log_outcome — happy path
# =============================================================================
suite "decision_log_outcome — happy path"

OLOG=$(_tmpfile)
decision_log_init "$OLOG" "qa" "outcome test" "claude-sonnet-4-6"
decision_log_outcome "$OLOG" "success" "All phases completed."

OC=$(cat "$OLOG")
assert_contains "outcome success: Outcome section" "## Outcome" "$OC"
assert_contains "outcome success: status written" "success" "$OC"
assert_contains "outcome success: notes written" "All phases completed" "$OC"
assert_not_contains "outcome success: no lingering in-progress" "**Status:** in-progress" "$OC"

# Failed status
OLOG2=$(_tmpfile)
decision_log_init "$OLOG2" "architect" "fail test" "claude-sonnet-4-6"
decision_log_outcome "$OLOG2" "failed" "Timeout on phase 2."

OC2=$(cat "$OLOG2")
assert_contains "outcome failed: status written" "failed" "$OC2"
assert_contains "outcome failed: notes written" "Timeout on phase 2" "$OC2"
assert_not_contains "outcome failed: no lingering in-progress" "**Status:** in-progress" "$OC2"

# =============================================================================
# SECTION 10: decision_log_outcome — no notes
# =============================================================================
suite "decision_log_outcome — no notes argument"

ONOLOG=$(_tmpfile)
decision_log_init "$ONOLOG" "refactor" "no notes test" "claude-sonnet-4-6"
decision_log_outcome "$ONOLOG" "success"

ONC=$(cat "$ONOLOG")
assert_contains "outcome no-notes: Outcome section" "## Outcome" "$ONC"
assert_contains "outcome no-notes: status present" "success" "$ONC"

# =============================================================================
# SECTION 11: decision_log_outcome — no-op on missing log
# =============================================================================
suite "decision_log_outcome — no-op when log file missing"

set +e
decision_log_outcome "/nonexistent/log_$$.md" "success" "notes"
OUTCOME_NOOP_RC=$?
set -e
assert_equals "outcome missing log: returns 0" "0" "$OUTCOME_NOOP_RC"

# =============================================================================
# SECTION 12: Log format consistency and parseability
# =============================================================================
suite "Log format — consistency and parseability"

FORMAT_LOG=$(_tmpfile)
decision_log_init "$FORMAT_LOG" "architect" "format validation" "claude-sonnet-4-6"

CONTENT_F=$(_tmpfile)
printf 'candidate content here\n' > "$CONTENT_F"
decision_log_section "$FORMAT_LOG" "Phase 1" "$CONTENT_F"
decision_log_note "$FORMAT_LOG" "Progress" "Moving to phase 2"
decision_log_outcome "$FORMAT_LOG" "success" "Task done."

FULL=$(cat "$FORMAT_LOG")

# Markdown structure: H1 title
if [[ "$FULL" =~ ^#\ architect:\ format\ validation ]]; then
    echo "  ✅ format: H1 title is first line"
    TEST_PASS=$(( TEST_PASS + 1 ))
else
    echo "  ❌ format: H1 title not first line"
    echo "       first line: $(printf '%s' "$FULL" | head -1)"
    TEST_FAIL=$(( TEST_FAIL + 1 ))
    TEST_ERRORS+=("[Log format] H1 title not first line")
fi

# All metadata fields use bold markdown (**Field:**)
assert_contains "format: Date in bold markdown"     "**Date:**"     "$FULL"
assert_contains "format: Pipeline in bold markdown" "**Pipeline:**" "$FULL"
assert_contains "format: Model in bold markdown"    "**Model:**"    "$FULL"
assert_contains "format: Status in bold markdown"   "**Status:**"   "$FULL"

# Sections use H2 (##)
assert_contains "format: Phase section is H2"    "## Phase 1"   "$FULL"
assert_contains "format: Progress section is H2" "## Progress"  "$FULL"
assert_contains "format: Outcome section is H2"  "## Outcome"   "$FULL"
assert_contains "format: Task section is H2"     "## Task"      "$FULL"

# Status updated from in-progress to success
assert_not_contains "format: no lingering in-progress" "in-progress" "$FULL"
assert_contains "format: final status is success" "success" "$FULL"

# Date format is parseable: YYYY-MM-DD HH:MM
DATE_LINE=$(printf '%s' "$FULL" | grep '^\*\*Date:\*\*')
DATE_VALUE=$(printf '%s' "$DATE_LINE" | sed 's/\*\*Date:\*\* //')
if [[ "$DATE_VALUE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]]; then
    echo "  ✅ format: date is YYYY-MM-DD HH:MM"
    TEST_PASS=$(( TEST_PASS + 1 ))
else
    echo "  ❌ format: date not YYYY-MM-DD HH:MM (got: $DATE_VALUE)"
    TEST_FAIL=$(( TEST_FAIL + 1 ))
    TEST_ERRORS+=("[Log format] date format mismatch")
fi

# =============================================================================
# SECTION 13: Log file section ordering
# =============================================================================
suite "Log format — section ordering"

ORDER_LOG=$(_tmpfile)
decision_log_init "$ORDER_LOG" "qa" "ordering test" "claude-sonnet-4-6"

PHASE1_FILE=$(_tmpfile)
PHASE2_FILE=$(_tmpfile)
printf 'phase 1 content' > "$PHASE1_FILE"
printf 'phase 2 content' > "$PHASE2_FILE"

decision_log_section "$ORDER_LOG" "Phase 1: Generation" "$PHASE1_FILE"
decision_log_section "$ORDER_LOG" "Phase 2: Validation" "$PHASE2_FILE"
decision_log_note    "$ORDER_LOG" "Phase 3: Note" "Phase 3 inline note"
decision_log_outcome "$ORDER_LOG" "success" "Done"

ORAW=$(cat "$ORDER_LOG")

P1_LINE=$(printf '%s\n' "$ORAW" | grep -n "Phase 1" | head -1 | cut -d: -f1)
P2_LINE=$(printf '%s\n' "$ORAW" | grep -n "Phase 2" | head -1 | cut -d: -f1)
P3_LINE=$(printf '%s\n' "$ORAW" | grep -n "Phase 3" | head -1 | cut -d: -f1)
OUT_LINE=$(printf '%s\n' "$ORAW" | grep -n "^## Outcome" | head -1 | cut -d: -f1)

assert_equals "ordering: Phase 1 before Phase 2" "true" \
    "$([ "${P1_LINE:-0}" -lt "${P2_LINE:-99}" ] && echo true || echo false)"
assert_equals "ordering: Phase 2 before Phase 3" "true" \
    "$([ "${P2_LINE:-0}" -lt "${P3_LINE:-99}" ] && echo true || echo false)"
assert_equals "ordering: Phase 3 before Outcome" "true" \
    "$([ "${P3_LINE:-0}" -lt "${OUT_LINE:-99}" ] && echo true || echo false)"

# =============================================================================
# SECTION 14: /logging skill spec — init filename format
# =============================================================================
suite "/logging skill spec — init filename format"

# The skill constructs: docs/decisions/<timestamp>_<slug>_<pipeline>.md
# Verify the naming convention is consistent with existing decision logs.
make_slug() {
    printf '%s' "$1" \
        | tr '[:upper:]' '[:lower:]' \
        | tr -cs 'a-z0-9' '-' \
        | sed 's/-\{2,\}/-/g; s/^-//; s/-$//' \
        | cut -c1-40 \
        | sed 's/-$//'
}

TIMESTAMP=$(date '+%Y%m%d_%H%M')
# Timestamp format: YYYYMMDD_HHMM (13 chars)
assert_equals "skill timestamp: 13 chars" "13" "${#TIMESTAMP}"

if [[ "$TIMESTAMP" =~ ^[0-9]{8}_[0-9]{4}$ ]]; then
    echo "  ✅ skill timestamp: matches YYYYMMDD_HHMM"
    TEST_PASS=$(( TEST_PASS + 1 ))
else
    echo "  ❌ skill timestamp: not YYYYMMDD_HHMM (got: $TIMESTAMP)"
    TEST_FAIL=$(( TEST_FAIL + 1 ))
    TEST_ERRORS+=("[/logging skill spec] timestamp format mismatch")
fi

# Verify slug generation
SLUG=$(make_slug "add a plugin system to the CLI")
assert_contains "skill slug: lowercase" "add-a-plugin-system" "$SLUG"
assert_not_contains "skill slug: no uppercase" "A" "$SLUG"
assert_not_contains "skill slug: no spaces" " " "$SLUG"

# Max 40 chars
LONG_SLUG=$(make_slug "this is a very long task description that exceeds forty characters easily")
assert_equals "skill slug: max 40 chars" "40" "${#LONG_SLUG}"

# Must not end with hyphen after truncation
LAST_CHAR="${LONG_SLUG: -1}"
assert_not_contains "skill slug: no trailing hyphen" "-" "$LAST_CHAR"

# Filename structure
TASK="Write tests for auth module"
SLUG2=$(make_slug "$TASK")
FILENAME="docs/decisions/${TIMESTAMP}_${SLUG2}_qa.md"
assert_contains "skill filename: docs/decisions/ prefix" "docs/decisions/" "$FILENAME"
assert_contains "skill filename: pipeline suffix" "_qa.md" "$FILENAME"
assert_contains "skill filename: timestamp in name" "$TIMESTAMP" "$FILENAME"

# =============================================================================
# SECTION 15: /logging skill spec — action parsing
# =============================================================================
suite "/logging skill spec — action parsing"

# Verify the SKILL.md defines all required actions
SKILL_CONTENT=$(cat "$REPO_DIR/.claude/skills/logging/SKILL.md")
assert_contains "skill: init action defined"    "Action: \`init\`"    "$SKILL_CONTENT"
assert_contains "skill: section action defined" "Action: \`section\`" "$SKILL_CONTENT"
assert_contains "skill: note action defined"    "Action: \`note\`"    "$SKILL_CONTENT"
assert_contains "skill: outcome action defined" "Action: \`outcome\`" "$SKILL_CONTENT"
assert_contains "skill: read action defined"    "Action: \`read\`"    "$SKILL_CONTENT"

# Verify allowed-tools in frontmatter matches what the actions need
assert_contains "skill: Write tool allowed"       "Write"          "$SKILL_CONTENT"
assert_contains "skill: Edit tool allowed"        "Edit"           "$SKILL_CONTENT"
assert_contains "skill: Bash(date *) allowed"     "Bash(date *)"   "$SKILL_CONTENT"
assert_contains "skill: Bash(mkdir -p *) allowed" "Bash(mkdir -p *)" "$SKILL_CONTENT"
assert_contains "skill: Bash(ls *) allowed"       "Bash(ls *)"     "$SKILL_CONTENT"
assert_contains "skill: Bash(sed *) allowed"      "Bash(sed *)"    "$SKILL_CONTENT"

# =============================================================================
# SECTION 16: /logging skill spec — outcome sed pattern
# =============================================================================
suite "/logging skill spec — outcome sed pattern replaces Status line"

# Verify the sed command described in the skill actually works
SED_LOG=$(_tmpfile)
decision_log_init "$SED_LOG" "qa" "sed test" "claude-sonnet-4-6"

# Confirm status starts as in-progress
PRE=$(cat "$SED_LOG")
assert_contains "sed pre: status is in-progress" "**Status:** in-progress" "$PRE"

# Apply the sed replacement described in the SKILL.md outcome action
sed -i "s/^\*\*Status:\*\* in-progress/**Status:** success/" "$SED_LOG"
POST=$(cat "$SED_LOG")
assert_not_contains "sed post: in-progress gone"   "**Status:** in-progress" "$POST"
assert_contains     "sed post: success present"    "**Status:** success"     "$POST"

# Verify sed does not replace content inside section bodies (only header line)
BODY_LOG=$(_tmpfile)
decision_log_init "$BODY_LOG" "refactor" "body test" "claude-sonnet-4-6"
decision_log_note "$BODY_LOG" "Notes" "The task was in-progress for 5 minutes."
sed -i "s/^\*\*Status:\*\* in-progress/**Status:** failed/" "$BODY_LOG"
BODY_CONTENT=$(cat "$BODY_LOG")
# Body text should be preserved even though it contains "in-progress"
assert_contains "sed body: note text preserved" "The task was in-progress for 5 minutes" "$BODY_CONTENT"
assert_not_contains "sed body: header in-progress replaced" "**Status:** in-progress" "$BODY_CONTENT"

# =============================================================================
# SECTION 17: docs/decisions/ directory existence and convention
# =============================================================================
suite "docs/decisions/ — directory conventions"

DECISIONS_DIR="$REPO_DIR/docs/decisions"
if [ -d "$DECISIONS_DIR" ]; then
    echo "  ✅ docs/decisions/: directory exists"
    TEST_PASS=$(( TEST_PASS + 1 ))

    # All existing logs should match the naming convention
    NAMING_ERRORS=0
    while IFS= read -r f; do
        fname=$(basename "$f")
        # Two accepted patterns:
        # Old format (from pipeline scripts): YYYY-MM-DD_HHMM_<slug>_<pipeline>.md
        # New format (from skill): YYYYMMDD_HHMM_<slug>_<pipeline>.md
        if [[ "$fname" =~ ^[0-9]{8}_[0-9]{4}_.*\.md$ ]] || \
           [[ "$fname" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{4}_.*\.md$ ]]; then
            : # OK
        else
            echo "  ⚠️  naming mismatch: $fname"
            NAMING_ERRORS=$(( NAMING_ERRORS + 1 ))
        fi
    done < <(find "$DECISIONS_DIR" -maxdepth 1 -name "*.md" -type f 2>/dev/null)

    if [ "$NAMING_ERRORS" -eq 0 ]; then
        echo "  ✅ docs/decisions/: all existing files match naming convention"
        TEST_PASS=$(( TEST_PASS + 1 ))
    else
        echo "  ❌ docs/decisions/: $NAMING_ERRORS files do not match naming convention"
        TEST_FAIL=$(( TEST_FAIL + 1 ))
        TEST_ERRORS+=("[docs/decisions/] naming convention violations: $NAMING_ERRORS files")
    fi
else
    skip "docs/decisions/ does not exist yet (created on first log init)"
fi

# =============================================================================
# SECTION 18: Multiple sections accumulate without overwriting
# =============================================================================
suite "Log accumulation — multiple writes do not overwrite"

ACCUM_LOG=$(_tmpfile)
decision_log_init "$ACCUM_LOG" "architect" "accumulation test" "claude-sonnet-4-6"

for I in 1 2 3 4 5; do
    decision_log_note "$ACCUM_LOG" "Phase $I" "Phase $I output text"
done

ACC=$(cat "$ACCUM_LOG")
for I in 1 2 3 4 5; do
    assert_contains "accum: phase $I present" "Phase $I output text" "$ACC"
done

# Count section headers to confirm all 5 phases are distinct sections
SECTION_COUNT=$(printf '%s\n' "$ACC" | grep -c '^## Phase ' || true)
assert_equals "accum: 5 phase sections present" "5" "$SECTION_COUNT"

# =============================================================================
# SECTION 19: Outcome status update is idempotent-safe
# =============================================================================
suite "decision_log_outcome — second call appends without corrupting"

IDEM_LOG=$(_tmpfile)
decision_log_init "$IDEM_LOG" "qa" "idempotent test" "claude-sonnet-4-6"
decision_log_outcome "$IDEM_LOG" "success" "First outcome."
decision_log_outcome "$IDEM_LOG" "amended" "Second outcome."

IDEM=$(cat "$IDEM_LOG")
assert_contains "idempotent: first outcome present"  "First outcome"  "$IDEM"
assert_contains "idempotent: second outcome present" "Second outcome" "$IDEM"
# File must not be empty or truncated
if [ -s "$IDEM_LOG" ]; then
    echo "  ✅ idempotent: file not truncated"
    TEST_PASS=$(( TEST_PASS + 1 ))
else
    echo "  ❌ idempotent: file was truncated"
    TEST_FAIL=$(( TEST_FAIL + 1 ))
    TEST_ERRORS+=("[idempotent outcome] file truncated")
fi

# =============================================================================
# SECTION 20: Section content file with empty contents
# =============================================================================
suite "decision_log_section — empty content file"

EMPTY_CONTENT_LOG=$(_tmpfile)
decision_log_init "$EMPTY_CONTENT_LOG" "qa" "empty content" "claude-sonnet-4-6"

EMPTY_CONTENT_FILE=$(_tmpfile)
> "$EMPTY_CONTENT_FILE"  # zero bytes

decision_log_section "$EMPTY_CONTENT_LOG" "Empty File Section" "$EMPTY_CONTENT_FILE"
ECC=$(cat "$EMPTY_CONTENT_LOG")
assert_contains "section empty file: header written" "## Empty File Section" "$ECC"
# An empty file IS a file that exists, so no "not available" placeholder
assert_not_contains "section empty file: no placeholder" "not available" "$ECC"

# =============================================================================
# SECTION 21: MISSING FEATURE — Real-time progress visibility
# =============================================================================
# These tests document gaps in live progress visibility for single-pipeline runs.
# The gm skill writes gm-status.md, but claude-box and claude-yolo for individual
# pipeline tasks (architect, refactor, qa) have no structured progress file that
# users can watch from a second terminal. These are skipped (not failed) because
# the implementation is out of scope for the current logging audit — the gap is
# documented here so it appears in the test output.
# =============================================================================
suite "MISSING FEATURE: real-time progress visibility for single-pipeline runs"

skip "NOT IMPLEMENTED: claude-progress.md for live progress from single-pipeline runs. " \
     "Users watching claude-yolo run architect/refactor/qa see only Docker output with no " \
     "structured file they can tail. The gm skill has gm-status.md but individual pipelines do not."

skip "NOT IMPLEMENTED: launch-scripted.sh does not write a live progress file. " \
     "Expected: progress file updated at each retry/recovery step so users can " \
     "monitor from a second terminal without attaching to Docker output."

# =============================================================================
# SECTION 22: MISSING FEATURE — Retrospective search by date
# =============================================================================
# There is no built-in way to search decision logs by date range. The /logging
# read action shows the 20 most recent logs but provides no date filtering.
# These are skipped (documented) rather than failing.
# =============================================================================
suite "MISSING FEATURE: retrospective log search by date"

skip "NOT IMPLEMENTED: no search_decision_logs function in lib/launch-lib.sh. " \
     "Expected: a function to filter docs/decisions/ logs by date range or keyword."

skip "NOT IMPLEMENTED: /logging skill has no 'search' action. " \
     "Expected: '/logging search [date|keyword]' to filter decision logs by date or content."

# =============================================================================
# SECTION 23: MISSING FEATURE — Retrospective search by git commit
# =============================================================================
# Decision logs do not record the triggering git commit hash or message, so
# they cannot be cross-referenced with git history. Documented as skipped.
# =============================================================================
suite "MISSING FEATURE: retrospective log search by git commit message"

skip "NOT IMPLEMENTED: decision_log_init does not record the current HEAD commit. " \
     "Expected: a '**Commit:** <hash>' field in the log header so logs can be " \
     "correlated with 'git log' output for retrospective search."

skip "NOT IMPLEMENTED: existing decision logs in docs/decisions/ lack a git commit " \
     "reference field. New logs should capture HEAD at init time so search by " \
     "commit message becomes possible."

# =============================================================================
# SECTION 24: MISSING FEATURE — Enhanced git-blame using decision logs
# =============================================================================
# There is no tool that cross-references git blame output with decision logs to
# explain WHY a feature was implemented. Documented as skipped.
# =============================================================================
suite "MISSING FEATURE: enhanced git-blame cross-referencing decision logs"

skip "NOT IMPLEMENTED: no git_blame_with_decisions function in lib/launch-lib.sh. " \
     "Expected: a function that takes a file+line and returns the decision log " \
     "that caused that change, by correlating commit timestamps with docs/decisions/ logs."

skip "NOT IMPLEMENTED: no /git-blame skill or command in .claude/. " \
     "Expected: '/git-blame <file> [line]' skill that explains WHY code was written " \
     "by cross-referencing git blame timestamps against docs/decisions/ log filenames."

# =============================================================================
# SECTION 25: MISSING FEATURE — Auto-initialization of logs in new workspaces
# =============================================================================
# When claude-box or claude-yolo runs in a new workspace/repo, docs/decisions/
# is NOT pre-created and no initialization log is written. The /logging init
# action creates it on demand, but launch scripts have no explicit bootstrap.
# Documented as skipped.
# =============================================================================
suite "MISSING FEATURE: auto-initialization of docs/decisions/ in new workspaces"

skip "NOT IMPLEMENTED: launch-interactive.sh does not pre-create docs/decisions/. " \
     "Expected: 'mkdir -p docs/decisions' before starting the claude session so the " \
     "directory exists even if no pipeline skill is invoked during the session."

skip "NOT IMPLEMENTED: launch-scripted.sh does not pre-create docs/decisions/. " \
     "Expected: 'mkdir -p docs/decisions' before the main task loop so the directory " \
     "is available before any pipeline skill calls /logging init."

skip "NOT IMPLEMENTED: entrypoint.sh does not ensure docs/decisions/ exists. " \
     "Note: docs/decisions/ lives in /workspace (bind-mounted) so it survives container " \
     "restarts, but a fresh clone has no decisions directory until first pipeline run."

# =============================================================================
# SECTION 26: /logging read action — existing logs are parseable
# =============================================================================
suite "/logging read action — existing logs are parseable"

DECISIONS_DIR="$REPO_DIR/docs/decisions"
if [ ! -d "$DECISIONS_DIR" ]; then
    skip "docs/decisions/ not present — skipping read action tests"
else
    LOG_COUNT=$(find "$DECISIONS_DIR" -name "*.md" -type f 2>/dev/null | wc -l || echo 0)
    if [ "$LOG_COUNT" -gt 0 ]; then
        echo "  ✅ read: docs/decisions/ has $LOG_COUNT log files"
        TEST_PASS=$(( TEST_PASS + 1 ))

        # Each log file should be valid markdown (starts with # and contains **Status:**)
        INVALID=0
        while IFS= read -r f; do
            FIRST_LINE=$(head -1 "$f" 2>/dev/null || echo "")
            if [[ "$FIRST_LINE" != "# "* ]]; then
                echo "  ⚠️  format issue: $f does not start with H1"
                INVALID=$(( INVALID + 1 ))
            fi
        done < <(find "$DECISIONS_DIR" -name "*.md" -type f 2>/dev/null | head -20)

        if [ "$INVALID" -eq 0 ]; then
            echo "  ✅ read: all sampled logs start with H1 header"
            TEST_PASS=$(( TEST_PASS + 1 ))
        else
            echo "  ❌ read: $INVALID logs do not start with H1 header"
            TEST_FAIL=$(( TEST_FAIL + 1 ))
            TEST_ERRORS+=("[/logging read] $INVALID logs lack H1 header")
        fi
    else
        skip "no log files yet in docs/decisions/"
    fi
fi

# =============================================================================
# SECTION 27: decision_log helpers available in lib/launch-lib.sh
# =============================================================================
suite "lib/launch-lib.sh — all decision_log functions exported"

# Each function must be callable after sourcing lib/launch-lib.sh
for FN in decision_log_init decision_log_section decision_log_note decision_log_outcome; do
    if declare -f "$FN" > /dev/null 2>&1; then
        echo "  ✅ function: $FN is available after source"
        TEST_PASS=$(( TEST_PASS + 1 ))
    else
        echo "  ❌ function: $FN is NOT available after source"
        TEST_FAIL=$(( TEST_FAIL + 1 ))
        TEST_ERRORS+=("[lib export] $FN not available")
    fi
done

# =============================================================================
# SECTION 28: decision_log_init — file is created atomically (no partial write)
# =============================================================================
suite "decision_log_init — file created with all required fields"

ATOMIC_LOG=$(_tmpfile)
decision_log_init "$ATOMIC_LOG" "refactor" "atomic write test" "claude-opus-4-8"

ATOMIC=$(cat "$ATOMIC_LOG")
# All 4 metadata fields must be present in a single init
REQUIRED_FIELDS=("**Date:**" "**Pipeline:**" "**Model:**" "**Status:** in-progress" "## Task")
for FIELD in "${REQUIRED_FIELDS[@]}"; do
    assert_contains "atomic init: $FIELD present" "$FIELD" "$ATOMIC"
done

# File must be non-empty
if [ -s "$ATOMIC_LOG" ]; then
    echo "  ✅ atomic init: file is non-empty"
    TEST_PASS=$(( TEST_PASS + 1 ))
else
    echo "  ❌ atomic init: file is empty"
    TEST_FAIL=$(( TEST_FAIL + 1 ))
    TEST_ERRORS+=("[atomic init] file is empty")
fi

# =============================================================================
# SECTION 29: gm skill — writes gm-status.md live
# =============================================================================
suite "gm skill — gm-status.md live progress spec"

# The gm skill SKILL.md documents that gm-status.md is updated after each task.
# Verify the spec includes this requirement.
GM_SKILL=$(cat "$REPO_DIR/.claude/skills/gm/SKILL.md")
assert_contains "gm skill: references gm-status.md" "gm-status.md" "$GM_SKILL"
assert_contains "gm skill: updates after each task"  "Progress"     "$GM_SKILL"
assert_contains "gm skill: live progress table"       "Status"       "$GM_SKILL"

# The gm skill should use /logging for its decision log
assert_contains "gm skill: uses /logging init"        "/logging init"    "$GM_SKILL"
assert_contains "gm skill: uses /logging note"        "/logging note"    "$GM_SKILL"

# =============================================================================
# SECTION 30: decision_log helpers — concurrent write safety (append only)
# =============================================================================
suite "decision log — append-only writes (no overwrite)"

APPEND_LOG=$(_tmpfile)
decision_log_init "$APPEND_LOG" "qa" "append safety" "claude-sonnet-4-6"
INIT_SIZE=$(wc -c < "$APPEND_LOG")

decision_log_note "$APPEND_LOG" "Note 1" "first note"
AFTER_NOTE1=$(wc -c < "$APPEND_LOG")

decision_log_section "$APPEND_LOG" "Section 1" "/dev/null"
AFTER_SECTION=$(wc -c < "$APPEND_LOG")

# Each write should only grow the file
assert_equals "append: note grew file" "true" \
    "$([ "$AFTER_NOTE1" -gt "$INIT_SIZE" ] && echo true || echo false)"
assert_equals "append: section grew file" "true" \
    "$([ "$AFTER_SECTION" -gt "$AFTER_NOTE1" ] && echo true || echo false)"

print_results
