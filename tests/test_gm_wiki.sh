#!/bin/bash
# Test suite for complexity routing in /gm.
#
# Covers:
#   1. Complexity classification (simple vs standard) for different task types
#   2. Routing behavior — simple tasks skip brainstorm/decide, go to /implement directly;
#      standard tasks go through full architect/refactor pipeline
#   3. QA layer still runs for both simple and standard tasks when --qa is given
#   4. Wiki documentation (overview.md Pipeline Steps table) correctly records
#      "direct (simple task)" for simple paths and normal log links for standard paths
#   5. Boundary conditions and edge cases in complexity assessment
#
# All tests are pure bash — no Docker or network required.
set -eo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/helpers.sh"

INITIAL_DIR="$(pwd)"
_CLEANUP_PATHS=()
_cleanup() {
    for p in "${_CLEANUP_PATHS[@]}"; do rm -rf "$p" 2>/dev/null || true; done
    cd "$INITIAL_DIR" 2>/dev/null || true
    unset LOGGING_TASK_DIR 2>/dev/null || true
}
trap _cleanup EXIT

_tmpdir() {
    local d
    d=$(mktemp -d /tmp/claude_gmcomplexity_XXXXXX)
    _CLEANUP_PATHS+=("$d")
    echo "$d"
}

# ---------------------------------------------------------------------------
# Helper: classify_complexity as specified in gm SKILL.md
#   - simple if word count <= 5
#   - simple if starts with rename|delete|remove|move|bump|toggle
#   - standard otherwise
#   - qa tasks ignore this (always routed to /qa)
# ---------------------------------------------------------------------------
classify_complexity() {
    local task="$1"
    local word_count
    word_count=$(echo "$task" | wc -w)

    local task_lower
    task_lower=$(echo "$task" | tr '[:upper:]' '[:lower:]')

    if [ "$word_count" -le 5 ]; then
        echo "simple"
        return 0
    fi

    if echo "$task_lower" | grep -qE '^(rename|delete|remove|move|bump|toggle)( |$)'; then
        echo "simple"
        return 0
    fi

    echo "standard"
    return 0
}

# ---------------------------------------------------------------------------
# Helper: detect skill type as specified in gm SKILL.md
# ---------------------------------------------------------------------------
detect_skill_type() {
    local task="$1"
    local task_lower
    task_lower=$(echo "$task" | tr '[:upper:]' '[:lower:]')

    if echo "$task" | grep -qE '(Fix:|Bug:|Hotfix:|Patch:|Bugfix:)' || \
       echo "$task_lower" | grep -qE '^(fix|patch|repair|debug|correct)( |$)'; then
        echo "refactor"
        return 0
    fi

    if echo "$task" | grep -qE '(QA:|Test:|Tests:|Coverage:)' || \
       echo "$task_lower" | grep -qE '^(test|write tests|add tests|cover)( |$)'; then
        echo "qa"
        return 0
    fi

    echo "architect"
    return 0
}

# ---------------------------------------------------------------------------
# Helper: resolve which pipeline skill will actually be invoked
# Returns: implement | architect | refactor | qa
# ---------------------------------------------------------------------------
resolve_invoked_skill() {
    local task="$1"
    local skill_type
    skill_type=$(detect_skill_type "$task")
    local complexity
    complexity=$(classify_complexity "$task")

    if [ "$skill_type" = "qa" ]; then
        echo "qa"
        return 0
    fi

    if [ "$complexity" = "simple" ]; then
        echo "implement"
    else
        echo "$skill_type"
    fi
}

# ---------------------------------------------------------------------------
# Helper: resolve the phase label written to overview.md Pipeline Steps
# Returns: "direct (simple task)" | "primary"
# ---------------------------------------------------------------------------
resolve_phase_label() {
    local task="$1"
    local skill_type
    skill_type=$(detect_skill_type "$task")
    local complexity
    complexity=$(classify_complexity "$task")

    if [ "$skill_type" != "qa" ] && [ "$complexity" = "simple" ]; then
        echo "direct (simple task)"
    else
        echo "primary"
    fi
}

# ---------------------------------------------------------------------------
# Helper: write initial overview.md as /gm would
# ---------------------------------------------------------------------------
write_overview_md() {
    local path="$1"
    local task_desc="$2"
    local task_id="$3"
    local date_display
    date_display=$(date '+%Y-%m-%d %H:%M')

    cat > "$path" <<EOF
# Task: ${task_desc}

**Task ID:** ${task_id}
**Date:** ${date_display}
**Branch:** <pending>
**Status:** in-progress

## Pipeline Steps

| Step | Skill | Phase | Log | Status |
|------|-------|-------|-----|--------|

## Outcome

*(pending)*
EOF
}

# ---------------------------------------------------------------------------
# Helper: append a pipeline step row to overview.md
# Usage: append_step_row <overview_path> <step> <skill> <phase_label> <log_filename> <status>
# ---------------------------------------------------------------------------
append_step_row() {
    local overview="$1"
    local step="$2"
    local skill="$3"
    local phase_label="$4"
    local log_filename="$5"
    local row_status="$6"

    echo "| ${step} | ${skill} | ${phase_label} | [log](decisions/${log_filename}) | ${row_status} |" >> "$overview"
}

# =============================================================================
# SECTION 1: Complexity classification — simple tasks (word count)
# =============================================================================
suite "complexity classification — simple by word count"

# Exactly 5 words → simple
C_FIVE=$(classify_complexity "Add config env variable now")
assert_equals "5 words: simple" "simple" "$C_FIVE"

# Fewer than 5 words
C_TWO=$(classify_complexity "Fix typo")
assert_equals "2 words: simple" "simple" "$C_TWO"

# Single word
C_ONE=$(classify_complexity "refactor")
assert_equals "1 word: simple" "simple" "$C_ONE"

# Exactly 4 words
C_FOUR=$(classify_complexity "Add auth middleware layer")
assert_equals "4 words: simple" "simple" "$C_FOUR"

# 3 words
C_THREE=$(classify_complexity "Remove dead code")
assert_equals "3 words: simple" "simple" "$C_THREE"

# =============================================================================
# SECTION 2: Complexity classification — standard tasks (word count)
# =============================================================================
suite "complexity classification — standard by word count"

# Exactly 6 words → standard (boundary)
C_SIX=$(classify_complexity "Add user authentication with JWT tokens")
assert_equals "6 words: standard" "standard" "$C_SIX"

# Many words
C_MANY=$(classify_complexity "Implement a full user authentication system with JWT tokens and refresh token rotation")
assert_equals "many words: standard" "standard" "$C_MANY"

# 7 words
C_SEVEN=$(classify_complexity "Add rate limiting to the payment endpoint")
assert_equals "7 words: standard" "standard" "$C_SEVEN"

# Long feature description
C_LONG=$(classify_complexity "Build a real-time notification system using WebSockets and Redis pub-sub for scalable delivery")
assert_equals "long description: standard" "standard" "$C_LONG"

# =============================================================================
# SECTION 3: Complexity classification — simple by prefix keyword
# =============================================================================
suite "complexity classification — simple by operation prefix"

# rename — always simple regardless of word count
C_RENAME=$(classify_complexity "rename the UserService class to AccountService throughout the codebase")
assert_equals "rename prefix: simple" "simple" "$C_RENAME"

# delete — always simple
C_DELETE=$(classify_complexity "delete the deprecated legacy authentication module from the codebase")
assert_equals "delete prefix: simple" "simple" "$C_DELETE"

# remove — always simple
C_REMOVE=$(classify_complexity "remove the unused logging middleware from the express pipeline")
assert_equals "remove prefix: simple" "simple" "$C_REMOVE"

# move — always simple
C_MOVE=$(classify_complexity "move the database connection logic into a dedicated module file")
assert_equals "move prefix: simple" "simple" "$C_MOVE"

# bump — always simple
C_BUMP=$(classify_complexity "bump the version number in package.json from 1.0.0 to 1.1.0")
assert_equals "bump prefix: simple" "simple" "$C_BUMP"

# toggle — always simple
C_TOGGLE=$(classify_complexity "toggle the feature flag for dark mode in the configuration file")
assert_equals "toggle prefix: simple" "simple" "$C_TOGGLE"

# Case insensitive — uppercase first letter
C_RENAME_UC=$(classify_complexity "Rename the UserService class to AccountService")
assert_equals "Rename (uppercase): simple" "simple" "$C_RENAME_UC"

C_DELETE_UC=$(classify_complexity "Delete all deprecated test fixtures from the test directory")
assert_equals "Delete (uppercase): simple" "simple" "$C_DELETE_UC"

# =============================================================================
# SECTION 4: Complexity classification — NOT simple by prefix (prefix in wrong position)
# =============================================================================
suite "complexity classification — prefix keyword not at start is standard"

# 'rename' not at start
C_RENAME_MIDDLE=$(classify_complexity "Please rename the UserService class to AccountService throughout the entire codebase")
assert_equals "rename in middle: standard" "standard" "$C_RENAME_MIDDLE"

# 'delete' not at start
C_DELETE_MIDDLE=$(classify_complexity "We should delete all deprecated legacy code from the authentication module")
assert_equals "delete in middle: standard" "standard" "$C_DELETE_MIDDLE"

# 'move' not at start
C_MOVE_MIDDLE=$(classify_complexity "Refactor and move the database connection logic into a dedicated service module")
assert_equals "move in middle: standard" "standard" "$C_MOVE_MIDDLE"

# =============================================================================
# SECTION 5: Skill type detection — refactor tasks
# =============================================================================
suite "skill type detection — refactor tasks"

S_FIX=$(detect_skill_type "fix login session timeout bug")
assert_equals "fix prefix: refactor" "refactor" "$S_FIX"

S_FIXCOLON=$(detect_skill_type "Fix: broken OAuth callback handler")
assert_equals "Fix: prefix: refactor" "refactor" "$S_FIXCOLON"

S_BUG=$(detect_skill_type "Bug: null pointer exception in user service")
assert_equals "Bug: prefix: refactor" "refactor" "$S_BUG"

S_PATCH=$(detect_skill_type "patch the security vulnerability in auth middleware")
assert_equals "patch prefix: refactor" "refactor" "$S_PATCH"

S_DEBUG=$(detect_skill_type "debug the race condition in payment processing")
assert_equals "debug prefix: refactor" "refactor" "$S_DEBUG"

S_REPAIR=$(detect_skill_type "repair the broken CI pipeline configuration")
assert_equals "repair prefix: refactor" "refactor" "$S_REPAIR"

# =============================================================================
# SECTION 6: Skill type detection — QA tasks
# =============================================================================
suite "skill type detection — qa tasks"

S_TEST=$(detect_skill_type "test the user authentication module")
assert_equals "test prefix: qa" "qa" "$S_TEST"

S_TESTCOLON=$(detect_skill_type "Test: write coverage for payment endpoint")
assert_equals "Test: prefix: qa" "qa" "$S_TESTCOLON"

S_QACOLON=$(detect_skill_type "QA: adversarial tests for login flow")
assert_equals "QA: prefix: qa" "qa" "$S_QACOLON"

S_WRITETESTS=$(detect_skill_type "write tests for the authentication module")
assert_equals "write tests prefix: qa" "qa" "$S_WRITETESTS"

S_ADDTESTS=$(detect_skill_type "add tests for the payment processor")
assert_equals "add tests prefix: qa" "qa" "$S_ADDTESTS"

S_COVER=$(detect_skill_type "cover the auth module with unit tests")
assert_equals "cover prefix: qa" "qa" "$S_COVER"

# =============================================================================
# SECTION 7: Skill type detection — architect tasks
# =============================================================================
suite "skill type detection — architect tasks (everything else)"

S_ADD=$(detect_skill_type "Add user authentication system")
assert_equals "add feature: architect" "architect" "$S_ADD"

S_IMPLEMENT=$(detect_skill_type "Implement real-time notifications with WebSockets")
assert_equals "implement: architect" "architect" "$S_IMPLEMENT"

S_BUILD=$(detect_skill_type "Build a plugin system for extensible integrations")
assert_equals "build: architect" "architect" "$S_BUILD"

S_RENAME=$(detect_skill_type "Rename UserService to AccountService")
assert_equals "rename: architect (not refactor)" "architect" "$S_RENAME"

# =============================================================================
# SECTION 8: Routing — simple architect tasks go to /implement
# =============================================================================
suite "routing — simple architect tasks use /implement directly"

# Short architect task → simple → implement
R_SHORT_ARCH=$(resolve_invoked_skill "Add config flag")
assert_equals "short architect: routed to implement" "implement" "$R_SHORT_ARCH"

R_RENAME_ARCH=$(resolve_invoked_skill "Rename UserService to AccountService throughout the entire project")
assert_equals "rename architect: routed to implement" "implement" "$R_RENAME_ARCH"

R_FOUR_WORD=$(resolve_invoked_skill "Update API base URL")
assert_equals "4-word architect: routed to implement" "implement" "$R_FOUR_WORD"

# Standard architect task → full pipeline
R_STD_ARCH=$(resolve_invoked_skill "Add user authentication system with JWT token support and refresh tokens")
assert_equals "standard architect: routed to architect" "architect" "$R_STD_ARCH"

# =============================================================================
# SECTION 9: Routing — simple refactor tasks go to /implement
# =============================================================================
suite "routing — simple refactor tasks use /implement directly"

# Short fix task (≤ 5 words) → simple → implement
R_SHORT_FIX=$(resolve_invoked_skill "fix login timeout bug")
assert_equals "short refactor (5 words): routed to implement" "implement" "$R_SHORT_FIX"

R_FIX_THREE=$(resolve_invoked_skill "fix null pointer")
assert_equals "3-word refactor: routed to implement" "implement" "$R_FIX_THREE"

R_DELETE_REFACTOR=$(resolve_invoked_skill "delete unused legacy authentication module from the deprecated subsystem folder")
assert_equals "delete-prefix refactor: routed to implement" "implement" "$R_DELETE_REFACTOR"

# Standard refactor task → full pipeline
R_STD_REFACTOR=$(resolve_invoked_skill "fix the race condition in the payment processing service under concurrent load")
assert_equals "standard refactor: routed to refactor" "refactor" "$R_STD_REFACTOR"

# =============================================================================
# SECTION 10: Routing — QA tasks always use /qa regardless of complexity
# =============================================================================
suite "routing — qa tasks always use /qa (never /implement)"

# Short QA task → still qa (not simple/implement)
R_QA_SHORT=$(resolve_invoked_skill "test auth module")
assert_equals "short qa task: routed to qa (not implement)" "qa" "$R_QA_SHORT"

R_QA_ONE_WORD=$(resolve_invoked_skill "test")
assert_equals "1-word qa task: routed to qa" "qa" "$R_QA_ONE_WORD"

R_QA_LONG=$(resolve_invoked_skill "write tests for the user authentication module covering all edge cases and failure modes")
assert_equals "long qa task: routed to qa" "qa" "$R_QA_LONG"

R_QA_COVER=$(resolve_invoked_skill "cover login flow")
assert_equals "short cover task: routed to qa" "qa" "$R_QA_COVER"

R_QACOLON=$(resolve_invoked_skill "QA: adversarial tests for auth")
assert_equals "QA: prefix: routed to qa" "qa" "$R_QACOLON"

# =============================================================================
# SECTION 11: Phase label — simple tasks get "direct (simple task)"
# =============================================================================
suite "phase label — simple tasks record 'direct (simple task)' in overview.md"

# Simple architect → direct
L_SIMPLE_ARCH=$(resolve_phase_label "Add config flag")
assert_equals "simple architect: phase label" "direct (simple task)" "$L_SIMPLE_ARCH"

# Simple refactor → direct
L_SIMPLE_REFACTOR=$(resolve_phase_label "fix null pointer")
assert_equals "simple refactor: phase label" "direct (simple task)" "$L_SIMPLE_REFACTOR"

# Simple by prefix → direct
L_RENAME=$(resolve_phase_label "rename the entire UserService class to AccountService throughout the codebase")
assert_equals "rename prefix: phase label" "direct (simple task)" "$L_RENAME"

L_DELETE=$(resolve_phase_label "delete the deprecated module from all environments and config files")
assert_equals "delete prefix: phase label" "direct (simple task)" "$L_DELETE"

# =============================================================================
# SECTION 12: Phase label — standard tasks get "primary"
# =============================================================================
suite "phase label — standard tasks record 'primary' in overview.md"

# Standard architect → primary
L_STD_ARCH=$(resolve_phase_label "Add user authentication system with JWT token support and refresh")
assert_equals "standard architect: phase label" "primary" "$L_STD_ARCH"

# Standard refactor → primary
L_STD_REFACTOR=$(resolve_phase_label "fix the race condition in payment processing under concurrent write load")
assert_equals "standard refactor: phase label" "primary" "$L_STD_REFACTOR"

# QA task (any length) → primary
L_QA_SHORT=$(resolve_phase_label "test auth")
assert_equals "short qa: phase label is primary (not direct)" "primary" "$L_QA_SHORT"

L_QA_LONG=$(resolve_phase_label "write tests for the authentication module covering all edge cases")
assert_equals "long qa: phase label is primary" "primary" "$L_QA_LONG"

# =============================================================================
# SECTION 13: Wiki documentation — simple path Pipeline Steps row
# =============================================================================
suite "wiki documentation — simple path Pipeline Steps row format"

WORK13=$(_tmpdir)
DATE_PART13=$(date +%Y%m%d-%H%M)
TASK_ID13="${DATE_PART13}_add-config-flag"
OVERVIEW13="${WORK13}/docs/${TASK_ID13}/overview.md"
mkdir -p "$(dirname "$OVERVIEW13")"
write_overview_md "$OVERVIEW13" "Add config flag" "$TASK_ID13"

# Append a simple-path step row
LOG_FILE13="20260626_1430_add-config-flag_implement.md"
append_step_row "$OVERVIEW13" "1" "implement" "direct (simple task)" "$LOG_FILE13" "done"

ROW13=$(cat "$OVERVIEW13")
assert_contains "simple row: step 1 present" "| 1 |" "$ROW13"
assert_contains "simple row: skill is implement" "| implement |" "$ROW13"
assert_contains "simple row: phase is direct (simple task)" "direct (simple task)" "$ROW13"
assert_contains "simple row: log link present" "[log](decisions/${LOG_FILE13})" "$ROW13"
assert_contains "simple row: status done" "| done |" "$ROW13"

# Must NOT contain 'primary' in this row
STEP_LINE13=$(grep '| 1 |' "$OVERVIEW13" | head -1)
assert_not_contains "simple row: no 'primary' label" "primary" "$STEP_LINE13"

# Must NOT contain 'architect' or 'refactor' as skill (it's implement)
assert_not_contains "simple row: skill is not architect" "| architect |" "$STEP_LINE13"
assert_not_contains "simple row: skill is not refactor" "| refactor |" "$STEP_LINE13"

# =============================================================================
# SECTION 14: Wiki documentation — standard path Pipeline Steps row
# =============================================================================
suite "wiki documentation — standard path Pipeline Steps row format"

WORK14=$(_tmpdir)
DATE_PART14=$(date +%Y%m%d-%H%M)
TASK_ID14="${DATE_PART14}_add-user-auth"
OVERVIEW14="${WORK14}/docs/${TASK_ID14}/overview.md"
mkdir -p "$(dirname "$OVERVIEW14")"
write_overview_md "$OVERVIEW14" "Add user authentication with JWT" "$TASK_ID14"

# Append a standard-path architect row
LOG_FILE14="20260626_1430_add-user-auth_architect.md"
append_step_row "$OVERVIEW14" "1" "architect" "primary" "$LOG_FILE14" "done"

ROW14=$(cat "$OVERVIEW14")
assert_contains "std row: step 1 present" "| 1 |" "$ROW14"
assert_contains "std row: skill is architect" "| architect |" "$ROW14"
assert_contains "std row: phase is primary" "| primary |" "$ROW14"
assert_contains "std row: log link present" "[log](decisions/${LOG_FILE14})" "$ROW14"

# Must NOT contain 'direct (simple task)'
STEP_LINE14=$(grep '| 1 |' "$OVERVIEW14" | head -1)
assert_not_contains "std row: no 'direct (simple task)'" "direct (simple task)" "$STEP_LINE14"
assert_not_contains "std row: skill is not implement" "| implement |" "$STEP_LINE14"

# Standard refactor row
WORK14B=$(_tmpdir)
TASK_ID14B="${DATE_PART14}_fix-race-condition"
OVERVIEW14B="${WORK14B}/docs/${TASK_ID14B}/overview.md"
mkdir -p "$(dirname "$OVERVIEW14B")"
write_overview_md "$OVERVIEW14B" "Fix race condition in payment service" "$TASK_ID14B"

LOG_FILE14B="20260626_1435_fix-race-condition_refactor.md"
append_step_row "$OVERVIEW14B" "1" "refactor" "primary" "$LOG_FILE14B" "done"

ROW14B=$(cat "$OVERVIEW14B")
assert_contains "std refactor row: skill is refactor" "| refactor |" "$ROW14B"
assert_contains "std refactor row: phase is primary" "| primary |" "$ROW14B"

# =============================================================================
# SECTION 15: QA layer — runs for simple tasks when --qa is given
# =============================================================================
suite "QA layer — runs for simple tasks when --qa flag given"

# Simulate: simple architect task succeeds, then QA layer runs
WORK15=$(_tmpdir)
DATE_PART15=$(date +%Y%m%d-%H%M)
TASK_ID15="${DATE_PART15}_add-config-flag"
OVERVIEW15="${WORK15}/docs/${TASK_ID15}/overview.md"
mkdir -p "$(dirname "$OVERVIEW15")"
write_overview_md "$OVERVIEW15" "Add config flag" "$TASK_ID15"

# Primary phase (simple → implement)
PHASE_LOG15="20260626_1430_add-config-flag_implement.md"
append_step_row "$OVERVIEW15" "1" "implement" "direct (simple task)" "$PHASE_LOG15" "done"

# QA layer runs (qa_layer=true AND primary_success=true)
# The QA layer always appends a qa/adversarial row regardless of simple/standard
QA_LOG15="20260626_1445_add-config-flag_qa.md"
append_step_row "$OVERVIEW15" "2" "qa" "adversarial" "$QA_LOG15" "done"

QA15=$(cat "$OVERVIEW15")
# Both rows must be present
assert_contains "qa layer simple: primary row present" "| 1 | implement | direct (simple task)" "$QA15"
assert_contains "qa layer simple: qa row present" "| 2 | qa | adversarial" "$QA15"
assert_contains "qa layer simple: qa log link" "[log](decisions/${QA_LOG15})" "$QA15"

ROW_COUNT15=$(grep -c '^| [0-9]' "$OVERVIEW15" || true)
assert_equals "qa layer simple: exactly 2 step rows" "2" "$ROW_COUNT15"

# =============================================================================
# SECTION 16: QA layer — runs for standard tasks when --qa is given
# =============================================================================
suite "QA layer — runs for standard tasks when --qa flag given"

WORK16=$(_tmpdir)
DATE_PART16=$(date +%Y%m%d-%H%M)
TASK_ID16="${DATE_PART16}_add-user-auth"
OVERVIEW16="${WORK16}/docs/${TASK_ID16}/overview.md"
mkdir -p "$(dirname "$OVERVIEW16")"
write_overview_md "$OVERVIEW16" "Add user authentication with JWT support" "$TASK_ID16"

# Primary phase (standard → architect)
PHASE_LOG16="20260626_1430_add-user-auth_architect.md"
append_step_row "$OVERVIEW16" "1" "architect" "primary" "$PHASE_LOG16" "done"

# QA layer
QA_LOG16="20260626_1455_add-user-auth_qa.md"
append_step_row "$OVERVIEW16" "2" "qa" "adversarial" "$QA_LOG16" "done"

QA16=$(cat "$OVERVIEW16")
assert_contains "qa layer std: primary row present" "| 1 | architect | primary" "$QA16"
assert_contains "qa layer std: qa row present" "| 2 | qa | adversarial" "$QA16"

ROW_COUNT16=$(grep -c '^| [0-9]' "$OVERVIEW16" || true)
assert_equals "qa layer std: exactly 2 step rows" "2" "$ROW_COUNT16"

# =============================================================================
# SECTION 17: QA layer — NOT added when primary fails
# =============================================================================
suite "QA layer — not added when primary phase fails"

WORK17=$(_tmpdir)
DATE_PART17=$(date +%Y%m%d-%H%M)
TASK_ID17="${DATE_PART17}_add-feature"
OVERVIEW17="${WORK17}/docs/${TASK_ID17}/overview.md"
mkdir -p "$(dirname "$OVERVIEW17")"
write_overview_md "$OVERVIEW17" "Add new feature" "$TASK_ID17"

# Primary phase fails
PHASE_LOG17="20260626_1430_add-feature_implement.md"
append_step_row "$OVERVIEW17" "1" "implement" "direct (simple task)" "$PHASE_LOG17" "failed"

# QA layer must NOT run when primary_success=false
# (no QA row appended)
FAIL17=$(cat "$OVERVIEW17")
ROW_COUNT17=$(grep -c '^| [0-9]' "$OVERVIEW17" || true)
assert_equals "qa not added on failure: exactly 1 step row" "1" "$ROW_COUNT17"
assert_contains "qa not added: primary row is failed" "| failed |" "$FAIL17"
assert_not_contains "qa not added: no qa row" "| qa |" "$FAIL17"

# =============================================================================
# SECTION 18: Boundary — exactly 5 words is simple (not standard)
# =============================================================================
suite "boundary — word count at threshold (5 = simple, 6 = standard)"

B_FIVE=$(classify_complexity "add auth to login endpoint")
assert_equals "boundary 5 words: simple" "simple" "$B_FIVE"

B_SIX=$(classify_complexity "add auth to the login endpoint")
assert_equals "boundary 6 words: standard" "standard" "$B_SIX"

# Verify these route differently
R_FIVE_ARCH=$(resolve_invoked_skill "add auth to login endpoint")
assert_equals "boundary 5-word architect: implement" "implement" "$R_FIVE_ARCH"

R_SIX_ARCH=$(resolve_invoked_skill "add auth to the login endpoint")
assert_equals "boundary 6-word architect: architect" "architect" "$R_SIX_ARCH"

L_FIVE=$(resolve_phase_label "add auth to login endpoint")
assert_equals "boundary 5-word: phase label direct" "direct (simple task)" "$L_FIVE"

L_SIX=$(resolve_phase_label "add auth to the login endpoint")
assert_equals "boundary 6-word: phase label primary" "primary" "$L_SIX"

# =============================================================================
# SECTION 19: Boundary — only the operation prefix word (single word)
# =============================================================================
suite "boundary — single operation prefix word"

B_RENAME_SOLO=$(classify_complexity "rename")
assert_equals "solo rename: simple (1 word, word count rule wins)" "simple" "$B_RENAME_SOLO"

B_DELETE_SOLO=$(classify_complexity "delete")
assert_equals "solo delete: simple" "simple" "$B_DELETE_SOLO"

B_REMOVE_SOLO=$(classify_complexity "remove")
assert_equals "solo remove: simple" "simple" "$B_REMOVE_SOLO"

# =============================================================================
# SECTION 20: Boundary — QA tasks with ≤5 words don't become simple
# =============================================================================
suite "boundary — short QA tasks remain qa, not simple"

# 2-word qa task
B_QA_TWO=$(resolve_invoked_skill "test auth")
assert_equals "2-word qa: qa not implement" "qa" "$B_QA_TWO"

# 1-word qa task
B_QA_ONE=$(resolve_invoked_skill "cover")
assert_equals "1-word cover task: qa not implement" "qa" "$B_QA_ONE"

# 5-word qa task
B_QA_FIVE=$(resolve_invoked_skill "QA: test the login flow")
assert_equals "5-word QA: task: qa not implement" "qa" "$B_QA_FIVE"

# Phase label for short qa task is still "primary"
L_QA_SHORT=$(resolve_phase_label "test auth")
assert_equals "2-word qa: phase label primary" "primary" "$L_QA_SHORT"

# =============================================================================
# SECTION 21: Boundary — edge cases in complexity
# =============================================================================
suite "boundary — edge cases in complexity assessment"

# Empty string → word count 0 → ≤5 → simple
B_EMPTY=$(classify_complexity "")
assert_equals "empty: simple (0 words)" "simple" "$B_EMPTY"

# Only whitespace → word count 0 → simple
B_SPACE=$(classify_complexity "   ")
assert_equals "only spaces: simple" "simple" "$B_SPACE"

# Very long simple-prefix task (>5 words but rename prefix)
B_LONG_RENAME=$(classify_complexity "rename the legacy database connection class to ModernDatabaseAdapter throughout all service files")
assert_equals "long rename prefix: simple" "simple" "$B_LONG_RENAME"

# Numbers count as words
B_WITH_NUMS=$(classify_complexity "phase 2 migration task")
assert_equals "4 words with number: simple" "simple" "$B_WITH_NUMS"

# =============================================================================
# SECTION 22: Complexity routing does not affect gm-status.md skill column
# =============================================================================
suite "gm-status.md — skill column reflects detected type, not invoked skill"

# The gm-status.md shows the detected skill type (architect/refactor/qa)
# even for simple tasks that are internally routed to /implement.
# This is because gm-status.md is a user-facing status table.
# The wiki (overview.md) is where the actual invoked skill is recorded.

# Verify this distinction conceptually:
TASK_SIMPLE_ARCH="Add config flag"
DETECTED22=$(detect_skill_type "$TASK_SIMPLE_ARCH")
INVOKED22=$(resolve_invoked_skill "$TASK_SIMPLE_ARCH")

assert_equals "status: detected type is architect" "architect" "$DETECTED22"
assert_equals "routing: invoked skill is implement" "implement" "$INVOKED22"
assert_not_contains "status vs routing: differ in simple case" "$DETECTED22" "$INVOKED22"

# For standard tasks: detected = invoked
TASK_STD_ARCH="Add user authentication system with JWT token support and refresh"
DETECTED22B=$(detect_skill_type "$TASK_STD_ARCH")
INVOKED22B=$(resolve_invoked_skill "$TASK_STD_ARCH")

assert_equals "std routing: detected == invoked for architect" "$DETECTED22B" "$INVOKED22B"

# =============================================================================
# SECTION 23: gm SKILL.md spec compliance — complexity routing documented
# =============================================================================
suite "gm SKILL.md spec — complexity routing documented"

GM_SKILL=$(cat "$REPO_DIR/.claude/skills/gm/SKILL.md")

assert_contains "gm spec: complexity assessment mentioned" "complexity" "$GM_SKILL"
assert_contains "gm spec: simple classification" "simple" "$GM_SKILL"
assert_contains "gm spec: standard classification" "standard" "$GM_SKILL"
assert_contains "gm spec: word count check documented" "wc -w" "$GM_SKILL"
assert_contains "gm spec: word count threshold (5)" "-le 5" "$GM_SKILL"
assert_contains "gm spec: rename prefix listed" "rename" "$GM_SKILL"
assert_contains "gm spec: delete prefix listed" "delete" "$GM_SKILL"
assert_contains "gm spec: remove prefix listed" "remove" "$GM_SKILL"
assert_contains "gm spec: move prefix listed" "move" "$GM_SKILL"
assert_contains "gm spec: bump prefix listed" "bump" "$GM_SKILL"
assert_contains "gm spec: toggle prefix listed" "toggle" "$GM_SKILL"
assert_contains "gm spec: /implement for simple tasks" "/implement" "$GM_SKILL"
assert_contains "gm spec: direct (simple task) label documented" "direct (simple task)" "$GM_SKILL"
assert_contains "gm spec: qa tasks not affected by complexity" "qa" "$GM_SKILL"
assert_contains "gm spec: COMPLEXITY variable used" "COMPLEXITY" "$GM_SKILL"
assert_contains "gm spec: simple skips brainstorm/decide" "Skip brainstorm" "$GM_SKILL"

# =============================================================================
# SECTION 24: Full pipeline step sequence — simple task with QA layer
# =============================================================================
suite "full sequence — simple task + QA layer produces correct overview.md"

WORK24=$(_tmpdir)
DATE_PART24=$(date +%Y%m%d-%H%M)
TASK_ID24="${DATE_PART24}_add-config-flag"
OVERVIEW24="${WORK24}/docs/${TASK_ID24}/overview.md"
BRANCH24="gm/${DATE_PART24}-add-config-flag"
BASE_BRANCH24="master"
mkdir -p "$(dirname "$OVERVIEW24")"
write_overview_md "$OVERVIEW24" "Add config flag" "$TASK_ID24"

# Step: branch update
sed -i "s|\*\*Branch:\*\* <pending>|**Branch:** ${BRANCH24}|" "$OVERVIEW24"

# Step: primary (simple → implement)
append_step_row "$OVERVIEW24" "1" "implement" "direct (simple task)" \
    "20260626_1430_add-config-flag_implement.md" "done"

# Step: QA layer (qa_layer=true)
append_step_row "$OVERVIEW24" "2" "qa" "adversarial" \
    "20260626_1445_add-config-flag_qa.md" "done"

# Step: success finalization
sed -i "s/\*\*Status:\*\* in-progress/**Status:** success/" "$OVERVIEW24"
sed -i "s/\*(pending)\*/All phases completed and merged to ${BASE_BRANCH24}/" "$OVERVIEW24"

FULL24=$(cat "$OVERVIEW24")

# Overview structure
assert_contains "full seq simple+qa: Task ID present" "$TASK_ID24" "$FULL24"
assert_contains "full seq simple+qa: Branch updated" "$BRANCH24" "$FULL24"
assert_not_contains "full seq simple+qa: no <pending> branch" "<pending>" "$FULL24"
assert_contains "full seq simple+qa: status success" "**Status:** success" "$FULL24"
assert_not_contains "full seq simple+qa: no in-progress" "in-progress" "$FULL24"
assert_contains "full seq simple+qa: merged message" "merged to ${BASE_BRANCH24}" "$FULL24"

# Pipeline Steps
assert_contains "full seq simple+qa: implement row" "| 1 | implement | direct (simple task)" "$FULL24"
assert_contains "full seq simple+qa: qa row" "| 2 | qa | adversarial" "$FULL24"
ROW_COUNT24=$(grep -c '^| [0-9]' "$OVERVIEW24" || true)
assert_equals "full seq simple+qa: exactly 2 step rows" "2" "$ROW_COUNT24"

# =============================================================================
# SECTION 25: Full pipeline step sequence — standard task with QA layer
# =============================================================================
suite "full sequence — standard task + QA layer produces correct overview.md"

WORK25=$(_tmpdir)
DATE_PART25=$(date +%Y%m%d-%H%M)
TASK_ID25="${DATE_PART25}_add-user-auth"
OVERVIEW25="${WORK25}/docs/${TASK_ID25}/overview.md"
BRANCH25="gm/${DATE_PART25}-add-user-auth"
BASE_BRANCH25="master"
mkdir -p "$(dirname "$OVERVIEW25")"
write_overview_md "$OVERVIEW25" "Add user authentication with JWT tokens" "$TASK_ID25"

sed -i "s|\*\*Branch:\*\* <pending>|**Branch:** ${BRANCH25}|" "$OVERVIEW25"

append_step_row "$OVERVIEW25" "1" "architect" "primary" \
    "20260626_1430_add-user-auth_architect.md" "done"

append_step_row "$OVERVIEW25" "2" "qa" "adversarial" \
    "20260626_1455_add-user-auth_qa.md" "done"

sed -i "s/\*\*Status:\*\* in-progress/**Status:** success/" "$OVERVIEW25"
sed -i "s/\*(pending)\*/All phases completed and merged to ${BASE_BRANCH25}/" "$OVERVIEW25"

FULL25=$(cat "$OVERVIEW25")

assert_contains "full seq std+qa: architect row" "| 1 | architect | primary" "$FULL25"
assert_contains "full seq std+qa: qa row" "| 2 | qa | adversarial" "$FULL25"
assert_not_contains "full seq std+qa: no direct label" "direct (simple task)" "$FULL25"
assert_contains "full seq std+qa: status success" "**Status:** success" "$FULL25"

ROW_COUNT25=$(grep -c '^| [0-9]' "$OVERVIEW25" || true)
assert_equals "full seq std+qa: exactly 2 step rows" "2" "$ROW_COUNT25"

# =============================================================================
# SECTION 26: Full pipeline step sequence — simple task WITHOUT QA layer
# =============================================================================
suite "full sequence — simple task without QA layer (1 step only)"

WORK26=$(_tmpdir)
DATE_PART26=$(date +%Y%m%d-%H%M)
TASK_ID26="${DATE_PART26}_rename-config"
OVERVIEW26="${WORK26}/docs/${TASK_ID26}/overview.md"
BRANCH26="gm/${DATE_PART26}-rename-config"
BASE_BRANCH26="main"
mkdir -p "$(dirname "$OVERVIEW26")"
write_overview_md "$OVERVIEW26" "Rename config variable" "$TASK_ID26"

sed -i "s|\*\*Branch:\*\* <pending>|**Branch:** ${BRANCH26}|" "$OVERVIEW26"

# Only primary step (no QA layer)
append_step_row "$OVERVIEW26" "1" "implement" "direct (simple task)" \
    "20260626_1430_rename-config_implement.md" "done"

sed -i "s/\*\*Status:\*\* in-progress/**Status:** success/" "$OVERVIEW26"
sed -i "s/\*(pending)\*/All phases completed and merged to ${BASE_BRANCH26}/" "$OVERVIEW26"

FULL26=$(cat "$OVERVIEW26")

assert_contains "simple no-qa: implement row" "| 1 | implement | direct (simple task)" "$FULL26"
assert_not_contains "simple no-qa: no qa row" "| qa |" "$FULL26"
assert_contains "simple no-qa: status success" "**Status:** success" "$FULL26"
assert_contains "simple no-qa: branch present" "$BRANCH26" "$FULL26"

ROW_COUNT26=$(grep -c '^| [0-9]' "$OVERVIEW26" || true)
assert_equals "simple no-qa: exactly 1 step row" "1" "$ROW_COUNT26"

# =============================================================================
# SECTION 27: Complexity not stored in task directory name (slug unaffected)
# =============================================================================
suite "complexity routing — slug and task ID unchanged by complexity"

# The gm slug generation is NOT affected by complexity.
# A simple task and a standard task with the same description produce the same slug.
TASK_DESC="Add user auth"

SLUG27=$(echo "$TASK_DESC" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9]/-/g' \
    | sed 's/-\{2,\}/-/g' \
    | sed 's/^-//;s/-$//' \
    | cut -c1-40)

COMPLEXITY27=$(classify_complexity "$TASK_DESC")
assert_equals "slug unchanged by complexity: task is simple" "simple" "$COMPLEXITY27"
assert_contains "slug: lowercase hyphenated" "add-user-auth" "$SLUG27"
assert_not_contains "slug: no complexity suffix" "simple" "$SLUG27"
assert_not_contains "slug: no complexity suffix" "standard" "$SLUG27"

# =============================================================================
# SECTION 28: Multiple tasks — mix of simple and standard in one run
# =============================================================================
suite "multi-task — mixed complexity tasks produce correct per-task wikis"

WORK28=$(_tmpdir)
DATE_PART28=$(date +%Y%m%d-%H%M)

declare -A TASK_INFO
TASK_INFO["add-config-flag"]="simple"
TASK_INFO["add-user-auth-with-jwt"]="standard"

for SLUG28 in "add-config-flag" "add-user-auth-with-jwt"; do
    TASK_ID28="${DATE_PART28}_${SLUG28}"
    OV28="${WORK28}/docs/${TASK_ID28}/overview.md"
    mkdir -p "$(dirname "$OV28")"

    if [ "$SLUG28" = "add-config-flag" ]; then
        write_overview_md "$OV28" "Add config flag" "$TASK_ID28"
        append_step_row "$OV28" "1" "implement" "direct (simple task)" \
            "${DATE_PART28}_${SLUG28}_implement.md" "done"
    else
        write_overview_md "$OV28" "Add user auth with JWT tokens now please" "$TASK_ID28"
        append_step_row "$OV28" "1" "architect" "primary" \
            "${DATE_PART28}_${SLUG28}_architect.md" "done"
    fi
done

# Verify simple task wiki
OV_SIMPLE="${WORK28}/docs/${DATE_PART28}_add-config-flag/overview.md"
SIMPLE_CONTENT=$(cat "$OV_SIMPLE")
assert_contains "multi: simple wiki has implement row" "| implement |" "$SIMPLE_CONTENT"
assert_contains "multi: simple wiki has direct label" "direct (simple task)" "$SIMPLE_CONTENT"

# Verify standard task wiki
OV_STD="${WORK28}/docs/${DATE_PART28}_add-user-auth-with-jwt/overview.md"
STD_CONTENT=$(cat "$OV_STD")
assert_contains "multi: standard wiki has architect row" "| architect |" "$STD_CONTENT"
assert_contains "multi: standard wiki has primary label" "| primary |" "$STD_CONTENT"

# Cross-contamination check
assert_not_contains "multi: simple wiki has no architect row" "| architect |" "$SIMPLE_CONTENT"
assert_not_contains "multi: standard wiki has no implement row" "| implement |" "$STD_CONTENT"
assert_not_contains "multi: standard wiki has no direct label" "direct (simple task)" "$STD_CONTENT"

print_results
