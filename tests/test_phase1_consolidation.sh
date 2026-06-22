#!/bin/bash
# Test suite for Phase 1: Code Refactoring and Consolidation.
#
# Regression coverage for shared patterns targeted for extraction into
# lib/launch-lib.sh, plus tests for previously untested script behaviors.
#
# Coverage:
#   - ensure_claude_md_current: create / update / skip / non-fatal behaviors
#   - Container name sanitization (SANITIZED_DIR pattern, shared across scripts)
#   - Decision file naming: TIMESTAMP_SLUG_<pipeline>.md format
#   - launch-architect.sh and launch-refactor.sh credential/task guards
#   - launch-dispatch.sh: @file loading, @file:section extraction,
#     --loop-tests parsing, heuristic routing, model keyword detection,
#     plan parsing, empty task validation
#   - run_headless_phase: OAuth env var forwarding, token budget, .claude/ cleanup
#
# No Docker, real credentials, or network access required.
set -eo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
FIXTURE_DIR="$TESTS_DIR/fixtures"
source "$TESTS_DIR/helpers.sh"
source "$REPO_DIR/lib/launch-lib.sh"

INITIAL_DIR="$(pwd)"
_CLEANUP_PATHS=()
_cleanup() {
    for p in "${_CLEANUP_PATHS[@]}"; do rm -rf "$p" 2>/dev/null || true; done
    cd "$INITIAL_DIR" 2>/dev/null || true
}
trap _cleanup EXIT

_tmpdir() { local d; d=$(mktemp -d /tmp/claude_phase1_XXXXXX); _CLEANUP_PATHS+=("$d"); echo "$d"; }
_tmpfile() { local f; f=$(mktemp /tmp/claude_phase1_XXXXXX); _CLEANUP_PATHS+=("$f"); echo "$f"; }

# Shared call log used across ensure_claude_md_current test suites
_ENSURE_LOG=$(_tmpfile)

# ==============================================================================
suite "ensure_claude_md_current — skip: CLAUDE.md present, no git"
# ==============================================================================

# Override run_headless_phase: if it's called, we record it.
run_headless_phase() { echo "CALLED" >> "$_ENSURE_LOG"; return 0; }

NO_GIT_DIR=$(_tmpdir)
touch "$NO_GIT_DIR/CLAUDE.md"

> "$_ENSURE_LOG"
cd "$NO_GIT_DIR"
ensure_claude_md_current "test-skip" 2>/dev/null
cd "$INITIAL_DIR"

assert_equals "CLAUDE.md present, no git: no run_headless_phase call" \
    "" "$(cat "$_ENSURE_LOG")"

# ==============================================================================
suite "ensure_claude_md_current — create: CLAUDE.md absent"
# ==============================================================================

# Capture model arg so we can verify haiku is used.
run_headless_phase() { printf 'MODEL=%s\nPROMPT=%s\n' "$2" "$4" >> "$_ENSURE_LOG"; return 0; }

NO_CLAUDE_DIR=$(_tmpdir)

> "$_ENSURE_LOG"
cd "$NO_CLAUDE_DIR"
ensure_claude_md_current "test-create" 2>/dev/null || true
cd "$INITIAL_DIR"

CREATE_LOG=$(cat "$_ENSURE_LOG")
assert_contains "CLAUDE.md absent: run_headless_phase called" "MODEL=" "$CREATE_LOG"
assert_contains "CLAUDE.md absent: uses haiku model" "MODEL=claude-haiku-4-5" "$CREATE_LOG"
assert_contains "CLAUDE.md absent: create prompt mentions CLAUDE.md" "CLAUDE.md" "$CREATE_LOG"
assert_contains "CLAUDE.md absent: create prompt contains 'create'" "create" "$CREATE_LOG"
assert_not_contains "CLAUDE.md absent: create prompt does not say 'update the existing'" \
    "update the existing" "$CREATE_LOG"

# ==============================================================================
suite "ensure_claude_md_current — update: CLAUDE.md older than last git commit"
# ==============================================================================

STALE_DIR=$(_tmpdir)
(
    cd "$STALE_DIR"
    git init --quiet
    git config user.email "test@example.com"
    git config user.name "Test User"
    echo "placeholder" > README.md
    git add README.md
    # Commit dated 2024 → newer than the year-2000 CLAUDE.md we create next
    GIT_AUTHOR_DATE="2024-01-01T00:00:00" GIT_COMMITTER_DATE="2024-01-01T00:00:00" \
        git commit -m "init" --quiet
    touch CLAUDE.md
    touch -t 200001010000 CLAUDE.md  # Jan 1, 2000 — older than 2024 commit
)

run_headless_phase() { printf 'MODEL=%s\nPROMPT=%s\n' "$2" "$4" >> "$_ENSURE_LOG"; return 0; }

> "$_ENSURE_LOG"
cd "$STALE_DIR"
ensure_claude_md_current "test-stale" 2>/dev/null || true
cd "$INITIAL_DIR"

STALE_LOG=$(cat "$_ENSURE_LOG")
assert_contains "stale CLAUDE.md: run_headless_phase called" "MODEL=" "$STALE_LOG"
assert_contains "stale CLAUDE.md: update prompt contains 'update'" "update" "$STALE_LOG"
assert_contains "stale CLAUDE.md: update prompt mentions git log" "git log" "$STALE_LOG"
assert_not_contains "stale CLAUDE.md: update prompt does NOT say 'create a CLAUDE.md'" \
    "create a CLAUDE.md" "$STALE_LOG"

# ==============================================================================
suite "ensure_claude_md_current — skip: CLAUDE.md current (git)"
# ==============================================================================

CURRENT_DIR=$(_tmpdir)
(
    cd "$CURRENT_DIR"
    git init --quiet
    git config user.email "test@example.com"
    git config user.name "Test User"
    echo "placeholder" > README.md
    git add README.md
    # Commit dated 2020 → older than a freshly-touched CLAUDE.md
    GIT_AUTHOR_DATE="2020-01-01T00:00:00" GIT_COMMITTER_DATE="2020-01-01T00:00:00" \
        git commit -m "init" --quiet
    touch CLAUDE.md  # current timestamp → newer than 2020 commit
)

run_headless_phase() { echo "CALLED" >> "$_ENSURE_LOG"; return 0; }

> "$_ENSURE_LOG"
cd "$CURRENT_DIR"
ensure_claude_md_current "test-current" 2>/dev/null
cd "$INITIAL_DIR"

assert_equals "CLAUDE.md current (git): run_headless_phase NOT called" \
    "" "$(cat "$_ENSURE_LOG")"

# ==============================================================================
suite "ensure_claude_md_current — non-fatal on run_headless_phase failure"
# ==============================================================================

run_headless_phase() { return 1; }  # simulates Docker unavailable

NONFATAL_DIR=$(_tmpdir)  # no CLAUDE.md → create path would fire

cd "$NONFATAL_DIR"
set +e
ensure_claude_md_current "test-nonfatal" 2>/dev/null
NONFATAL_RC=$?
set -e
cd "$INITIAL_DIR"

assert_equals "ensure non-fatal: returns 0 even when RHP fails" "0" "$NONFATAL_RC"

# ==============================================================================
suite "ensure_claude_md_current — default model is haiku when not specified"
# ==============================================================================

run_headless_phase() { printf 'MODEL=%s\n' "$2" >> "$_ENSURE_LOG"; return 0; }

DEFAULT_MODEL_DIR=$(_tmpdir)

> "$_ENSURE_LOG"
cd "$DEFAULT_MODEL_DIR"
ensure_claude_md_current 2>/dev/null || true  # no args → default model
cd "$INITIAL_DIR"

DM_LOG=$(cat "$_ENSURE_LOG")
assert_contains "ensure: default model is haiku" "MODEL=claude-haiku-4-5" "$DM_LOG"

# Restore the real run_headless_phase before tests that call it directly.
source "$REPO_DIR/lib/launch-lib.sh"

# ==============================================================================
suite "Container name sanitization — shared SANITIZED_DIR pattern"
# ==============================================================================

# This pattern is duplicated in launch-scripted.sh, launch-architect.sh, and
# launch-refactor.sh. These assertions are a regression baseline before
# the pattern is consolidated into lib/launch-lib.sh.
sanitize_dir_name() {
    printf '%s' "$1" | tr -cs '[:alnum:]-' '-' | tr '[:upper:]' '[:lower:]'
}

assert_equals "sanitize: uppercase → lowercase"        "myproject"    "$(sanitize_dir_name 'MyProject')"
assert_equals "sanitize: single space → hyphen"        "my-project"   "$(sanitize_dir_name 'my project')"
assert_equals "sanitize: dot → hyphen"                 "my-project"   "$(sanitize_dir_name 'my.project')"
assert_equals "sanitize: hyphen preserved"             "my-project"   "$(sanitize_dir_name 'my-project')"
assert_equals "sanitize: digits preserved"             "project123"   "$(sanitize_dir_name 'project123')"
assert_equals "sanitize: consecutive specials squeezed" "my-project"  "$(sanitize_dir_name 'my...project')"
assert_equals "sanitize: underscore → hyphen"          "my-project"   "$(sanitize_dir_name 'my_project')"
assert_equals "sanitize: mixed case + space + parens"  "my-cool-project-" \
    "$(sanitize_dir_name 'My Cool (Project)')"
assert_equals "sanitize: all digits"                   "123"          "$(sanitize_dir_name '123')"
assert_equals "sanitize: starts with number"           "2-factor"     "$(sanitize_dir_name '2-Factor')"

# Key difference from FEATURE_SLUG: trailing special chars produce trailing hyphens.
# FEATURE_SLUG strips them; SANITIZED_DIR does not.
TRAIL=$(sanitize_dir_name 'project!')
LAST_CHAR="${TRAIL: -1}"
assert_equals "sanitize: trailing special char leaves trailing hyphen" "-" "$LAST_CHAR"

# ==============================================================================
suite "Decision file naming — TIMESTAMP_SLUG_<pipeline>.md convention"
# ==============================================================================

# Reuse the same make_slug logic as the pipeline scripts.
make_slug() {
    printf '%s' "$1" \
        | tr '[:upper:]' '[:lower:]' \
        | tr -cs 'a-z0-9' '-' \
        | sed 's/-\{2,\}/-/g; s/^-//; s/-$//' \
        | cut -c1-40 \
        | sed 's/-$//'
}

TIMESTAMP=$(date '+%Y-%m-%d_%H%M')

# Timestamp format: YYYY-MM-DD_HHMM (15 chars)
assert_equals "timestamp: 15 chars" "15" "${#TIMESTAMP}"

if [[ "$TIMESTAMP" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{4}$ ]]; then
    echo "  ✅ timestamp: matches YYYY-MM-DD_HHMM pattern"
    TEST_PASS=$(( TEST_PASS + 1 ))
else
    echo "  ❌ timestamp: does not match YYYY-MM-DD_HHMM (got: $TIMESTAMP)"
    TEST_FAIL=$(( TEST_FAIL + 1 ))
    TEST_ERRORS+=("[Decision file naming] timestamp pattern mismatch")
fi

TASK="Add user authentication feature"
SLUG=$(make_slug "$TASK")

ARCH_FILE="docs/decisions/${TIMESTAMP}_${SLUG}_architect.md"
QA_FILE="docs/decisions/${TIMESTAMP}_${SLUG}_qa.md"
RF_FILE="docs/decisions/${TIMESTAMP}_${SLUG}_refactor.md"

assert_contains "architect file: in docs/decisions/"    "docs/decisions/"   "$ARCH_FILE"
assert_contains "architect file: suffix _architect.md"  "_architect.md"     "$ARCH_FILE"
assert_contains "qa file: suffix _qa.md"                "_qa.md"            "$QA_FILE"
assert_contains "refactor file: suffix _refactor.md"    "_refactor.md"      "$RF_FILE"
assert_contains "architect file: slug in path"          "add-user-authentication" "$ARCH_FILE"

# Pipelines must not share suffix (cross-contamination guard)
assert_not_contains "architect file: no _qa.md suffix"      "_qa.md"       "$ARCH_FILE"
assert_not_contains "qa file: no _architect.md suffix"       "_architect.md" "$QA_FILE"
assert_not_contains "refactor file: no _architect.md suffix" "_architect.md" "$RF_FILE"

# Empty task: slug is empty string, file path still generated without crash
EMPTY_SLUG=$(make_slug "")
EMPTY_FILE="docs/decisions/${TIMESTAMP}_${EMPTY_SLUG}_qa.md"
assert_contains "empty task slug: path still formed" "docs/decisions/" "$EMPTY_FILE"

# ==============================================================================
suite "launch-architect.sh — credential and task guards"
# ==============================================================================

# Missing credentials directory
FAKE_ARCH_HOME=$(_tmpdir)
set +e
ARCH_OUT=$(HOME="$FAKE_ARCH_HOME" bash "$REPO_DIR/launch-architect.sh" "some task" 2>&1)
ARCH_RC=$?
set -e
assert_equals "architect: missing creds exits 1" "1" "$ARCH_RC"
assert_contains "architect: shows credential error" "No Claude credentials found" "$ARCH_OUT"
assert_contains "architect: shows login hint" "claude auth login" "$ARCH_OUT"
assert_contains "architect: error mentions .credentials.json" ".credentials.json" "$ARCH_OUT"

# Malformed credentials → python token extraction fails → set -eo pipefail causes
# silent exit before the "Could not read OAuth token" message is reached.
# Behaviour: exits 1 with no output (same guard as scripted.sh but without set -e there).
FAKE_ARCH_HOME2=$(_tmpdir)
mkdir -p "$FAKE_ARCH_HOME2/.claude"
cp "$FIXTURE_DIR/malformed_creds.json" "$FAKE_ARCH_HOME2/.claude/.credentials.json"
set +e
ARCH_MAL_OUT=$(HOME="$FAKE_ARCH_HOME2" bash "$REPO_DIR/launch-architect.sh" "some task" 2>&1)
ARCH_MAL_RC=$?
set -e
assert_equals "architect: malformed creds exits 1" "1" "$ARCH_MAL_RC"

# Missing task (with valid credentials present)
FAKE_ARCH_HOME3=$(_tmpdir)
mkdir -p "$FAKE_ARCH_HOME3/.claude"
cp "$FIXTURE_DIR/valid_creds.json" "$FAKE_ARCH_HOME3/.claude/.credentials.json"
set +e
ARCH_NOTASK=$(HOME="$FAKE_ARCH_HOME3" bash "$REPO_DIR/launch-architect.sh" 2>&1)
ARCH_NOTASK_RC=$?
set -e
assert_equals "architect: missing task exits 1" "1" "$ARCH_NOTASK_RC"
assert_contains "architect: missing task shows Error" "Error" "$ARCH_NOTASK"

# Help flags
ARCH_HELP=$(bash "$REPO_DIR/launch-architect.sh" --help 2>&1) || true
assert_contains "architect --help: shows USAGE" "USAGE" "$ARCH_HELP"
assert_contains "architect --help: mentions phases" "Phase" "$ARCH_HELP"
assert_contains "architect --help: mentions no-gemini" "no-gemini" "$ARCH_HELP"

ARCH_H=$(bash "$REPO_DIR/launch-architect.sh" -h 2>&1) || true
assert_contains "architect -h: shows USAGE" "USAGE" "$ARCH_H"

# ==============================================================================
suite "launch-refactor.sh — credential and task guards"
# ==============================================================================

# Missing credentials
FAKE_RF_HOME=$(_tmpdir)
set +e
RF_OUT=$(HOME="$FAKE_RF_HOME" bash "$REPO_DIR/launch-refactor.sh" "some task" 2>&1)
RF_RC=$?
set -e
assert_equals "refactor: missing creds exits 1" "1" "$RF_RC"
assert_contains "refactor: shows credential error" "No Claude credentials found" "$RF_OUT"
assert_contains "refactor: shows login hint" "claude auth login" "$RF_OUT"

# Malformed credentials → same set -eo pipefail silent exit as architect
FAKE_RF_HOME2=$(_tmpdir)
mkdir -p "$FAKE_RF_HOME2/.claude"
cp "$FIXTURE_DIR/malformed_creds.json" "$FAKE_RF_HOME2/.claude/.credentials.json"
set +e
RF_MAL_OUT=$(HOME="$FAKE_RF_HOME2" bash "$REPO_DIR/launch-refactor.sh" "some task" 2>&1)
RF_MAL_RC=$?
set -e
assert_equals "refactor: malformed creds exits 1" "1" "$RF_MAL_RC"

# Missing task (valid creds)
FAKE_RF_HOME3=$(_tmpdir)
mkdir -p "$FAKE_RF_HOME3/.claude"
cp "$FIXTURE_DIR/valid_creds.json" "$FAKE_RF_HOME3/.claude/.credentials.json"
set +e
RF_NOTASK=$(HOME="$FAKE_RF_HOME3" bash "$REPO_DIR/launch-refactor.sh" 2>&1)
RF_NOTASK_RC=$?
set -e
assert_equals "refactor: missing task exits 1" "1" "$RF_NOTASK_RC"
assert_contains "refactor: missing task shows Error" "Error" "$RF_NOTASK"

# Help flags
RF_HELP=$(bash "$REPO_DIR/launch-refactor.sh" --help 2>&1) || true
assert_contains "refactor --help: shows USAGE" "USAGE" "$RF_HELP"
assert_contains "refactor --help: mentions phases" "Phase" "$RF_HELP"

RF_H=$(bash "$REPO_DIR/launch-refactor.sh" -h 2>&1) || true
assert_contains "refactor -h: shows USAGE" "USAGE" "$RF_H"

# ==============================================================================
suite "launch-dispatch.sh — @file loading"
# ==============================================================================

TASK_FILE=$(_tmpfile)
printf 'Implement a plugin architecture for the CLI' > "$TASK_FILE"

set +e
DISP_OUT=$(GEMINI_API_KEY="" bash "$REPO_DIR/launch-dispatch.sh" "@$TASK_FILE" --no-gemini 2>&1)
set -e
assert_contains "@file: file-loaded message shown" "Loaded task file" "$DISP_OUT"
assert_not_contains "@file: no 'must provide task' error" "You must provide a task description" "$DISP_OUT"

# ==============================================================================
suite "launch-dispatch.sh — @file:section extraction"
# ==============================================================================

SECTION_FILE=$(_tmpfile)
cat > "$SECTION_FILE" << 'SEOF'
# Repository Tasks

## Phase 1: Setup
Run the initial setup scripts and install dependencies.

## Phase 2: Implementation
Build the new authentication module with OAuth support.

## Phase 3: Testing
Write a comprehensive test suite covering all edge cases.
SEOF

# Extract phase 2 by heading substring
set +e
DISP_P2=$(GEMINI_API_KEY="" bash "$REPO_DIR/launch-dispatch.sh" \
    "@${SECTION_FILE}:phase 2" --no-gemini 2>&1)
set -e
assert_contains "@file:section: extraction message shown" "Loaded section" "$DISP_P2"
assert_contains "@file:section: correct section name" "phase 2" "$DISP_P2"

# Extract phase 3
set +e
DISP_P3=$(GEMINI_API_KEY="" bash "$REPO_DIR/launch-dispatch.sh" \
    "@${SECTION_FILE}:phase 3" --no-gemini 2>&1)
set -e
assert_contains "@file:section phase 3: extraction message shown" "Loaded section" "$DISP_P3"
assert_contains "@file:section phase 3: section name in message" "phase 3" "$DISP_P3"

# Nonexistent section: Python code returns full file content (no crash)
set +e
DISP_NOSEC=$(GEMINI_API_KEY="" bash "$REPO_DIR/launch-dispatch.sh" \
    "@${SECTION_FILE}:nonexistent_section_xyz" --no-gemini 2>&1)
set -e
assert_contains "@file:section nonexistent: still produces output (full file fallback)" \
    "Loaded section" "$DISP_NOSEC"

# @file that does not exist → exit 1 with "not found" error
set +e
DISP_MISS=$(GEMINI_API_KEY="" bash "$REPO_DIR/launch-dispatch.sh" \
    "@/nonexistent/missing_file_$$.md" --no-gemini 2>&1)
DISP_MISS_RC=$?
set -e
assert_equals "@file missing: exits 1" "1" "$DISP_MISS_RC"
assert_contains "@file missing: shows file-not-found error" "not found" "$DISP_MISS"

# ==============================================================================
suite "launch-dispatch.sh — empty task file"
# ==============================================================================

EMPTY_FILE=$(_tmpfile)
> "$EMPTY_FILE"  # deliberately empty

set +e
DISP_EMPTY=$(GEMINI_API_KEY="" bash "$REPO_DIR/launch-dispatch.sh" \
    "@$EMPTY_FILE" --no-gemini 2>&1)
DISP_EMPTY_RC=$?
set -e
assert_equals "empty task file: exits 1" "1" "$DISP_EMPTY_RC"
assert_contains "empty task file: shows 'empty' error" "empty" "$DISP_EMPTY"

# ==============================================================================
suite "launch-dispatch.sh — --loop-tests flag parsing"
# ==============================================================================

LOOP_TASK_FILE=$(_tmpfile)
printf 'Deploy the application' > "$LOOP_TASK_FILE"

# --loop-tests without =N defaults to 3
set +e
DISP_LOOP=$(GEMINI_API_KEY="" bash "$REPO_DIR/launch-dispatch.sh" \
    "@$LOOP_TASK_FILE" --no-gemini --loop-tests 2>&1)
set -e
assert_contains "--loop-tests default: shows loop header" "loop up to" "$DISP_LOOP"
assert_contains "--loop-tests default: 3 iterations" "3x" "$DISP_LOOP"

# --loop-tests=5: custom count
set +e
DISP_LOOP5=$(GEMINI_API_KEY="" bash "$REPO_DIR/launch-dispatch.sh" \
    "@$LOOP_TASK_FILE" --no-gemini --loop-tests=5 2>&1)
set -e
assert_contains "--loop-tests=5: shows 5 iterations" "5x" "$DISP_LOOP5"

# --loop-tests=1: minimum custom count
set +e
DISP_LOOP1=$(GEMINI_API_KEY="" bash "$REPO_DIR/launch-dispatch.sh" \
    "@$LOOP_TASK_FILE" --no-gemini --loop-tests=1 2>&1)
set -e
assert_contains "--loop-tests=1: shows 1 iteration" "1x" "$DISP_LOOP1"

# Without --loop-tests: no loop header shown
set +e
DISP_NOLOOP=$(GEMINI_API_KEY="" bash "$REPO_DIR/launch-dispatch.sh" \
    "@$LOOP_TASK_FILE" --no-gemini 2>&1)
set -e
assert_not_contains "no --loop-tests: no loop header" "loop up to" "$DISP_NOLOOP"

# ==============================================================================
suite "launch-dispatch.sh — heuristic routing (no Gemini)"
# ==============================================================================

# Helper: run dispatch with a plain task string (no @file) and no-gemini
_dispatch_heuristic() {
    local task="$1"
    local tf; tf=$(mktemp /tmp/claude_phase1_XXXXXX); _CLEANUP_PATHS+=("$tf")
    printf '%s' "$task" > "$tf"
    GEMINI_API_KEY="" bash "$REPO_DIR/launch-dispatch.sh" "@$tf" --no-gemini 2>&1 || true
}

# qa keywords: test, qa, coverage, spec, assert, verify
QA_TEST=$(_dispatch_heuristic "Write a unit test for the login function")
assert_contains "heuristic: 'test' keyword → qa" "[qa]" "$QA_TEST"

QA_COV=$(_dispatch_heuristic "Check code coverage for the auth module")
assert_contains "heuristic: 'coverage' keyword → qa" "[qa]" "$QA_COV"

QA_SPEC=$(_dispatch_heuristic "Write a spec for the payment endpoint")
assert_contains "heuristic: 'spec' keyword → qa" "[qa]" "$QA_SPEC"

# refactor keywords: fix, bug, refactor, repair, race, leak, debug, broken, regress
RF_FIX=$(_dispatch_heuristic "Fix the null pointer in the session handler")
assert_contains "heuristic: 'fix' keyword → refactor" "[refactor]" "$RF_FIX"

RF_DEBUG=$(_dispatch_heuristic "Debug the connection leak in the database pool")
assert_contains "heuristic: 'debug'+'leak' keywords → refactor" "[refactor]" "$RF_DEBUG"

RF_BROKEN=$(_dispatch_heuristic "The broken authentication flow needs repair")
assert_contains "heuristic: 'broken'+'repair' keywords → refactor" "[refactor]" "$RF_BROKEN"

# architect keywords: add, implement, build, create, design, feature, new
ARCH_ADD=$(_dispatch_heuristic "Add a plugin system to the CLI")
assert_contains "heuristic: 'add' keyword → architect" "[architect]" "$ARCH_ADD"

ARCH_BUILD=$(_dispatch_heuristic "Build a caching layer for the API")
assert_contains "heuristic: 'build' keyword → architect" "[architect]" "$ARCH_BUILD"

ARCH_DESIGN=$(_dispatch_heuristic "Design and implement a new feature flag system")
assert_contains "heuristic: 'design'+'new' keywords → architect" "[architect]" "$ARCH_DESIGN"

# scripted fallback: no recognized keyword
SCR_DEPLOY=$(_dispatch_heuristic "Deploy the application to production")
assert_contains "heuristic: no keyword → scripted" "[scripted]" "$SCR_DEPLOY"

# Task with no keyword match → scripted (avoid "new" which is an architect keyword)
SCR_CHECK=$(_dispatch_heuristic "Check the application logs and report any issues")
assert_contains "heuristic: no keyword → scripted (check/report)" "[scripted]" "$SCR_CHECK"

# qa takes precedence over refactor when both keywords appear
QA_BEATS_RF=$(_dispatch_heuristic "Write a test to verify the bug is fixed")
assert_contains "heuristic: qa keywords win over refactor" "[qa]" "$QA_BEATS_RF"

# refactor takes precedence over architect when both keywords appear
RF_BEATS_ARCH=$(_dispatch_heuristic "Fix and refactor the new feature module")
assert_contains "heuristic: refactor keywords win over architect" "[refactor]" "$RF_BEATS_ARCH"

# ==============================================================================
suite "launch-dispatch.sh — model keyword detection"
# ==============================================================================

MODEL_FILE=$(_tmpfile)
printf 'Deploy the application' > "$MODEL_FILE"

# Default: claude-sonnet-4-6
set +e
DISP_DEF=$(GEMINI_API_KEY="" bash "$REPO_DIR/launch-dispatch.sh" \
    "@$MODEL_FILE" --no-gemini 2>&1)
set -e
assert_contains "dispatch model: default is sonnet" "claude-sonnet-4-6" "$DISP_DEF"

# Explicit haiku
set +e
DISP_HAIKU=$(GEMINI_API_KEY="" bash "$REPO_DIR/launch-dispatch.sh" \
    "@$MODEL_FILE" "claude-haiku-4-5" --no-gemini 2>&1)
set -e
assert_contains "dispatch model: haiku explicit" "claude-haiku-4-5" "$DISP_HAIKU"

# Explicit opus
set +e
DISP_OPUS=$(GEMINI_API_KEY="" bash "$REPO_DIR/launch-dispatch.sh" \
    "@$MODEL_FILE" "claude-opus-4-8" --no-gemini 2>&1)
set -e
assert_contains "dispatch model: opus explicit" "claude-opus-4-8" "$DISP_OPUS"

# Explicit fable
set +e
DISP_FABLE=$(GEMINI_API_KEY="" bash "$REPO_DIR/launch-dispatch.sh" \
    "@$MODEL_FILE" "claude-fable-5" --no-gemini 2>&1)
set -e
assert_contains "dispatch model: fable explicit" "claude-fable-5" "$DISP_FABLE"

# Unknown model (no haiku/sonnet/opus/fable substring) → stays as default sonnet
set +e
DISP_UNK=$(GEMINI_API_KEY="" bash "$REPO_DIR/launch-dispatch.sh" \
    "@$MODEL_FILE" "gpt-4o" --no-gemini 2>&1)
set -e
assert_contains "dispatch model: unknown → stays as sonnet" "claude-sonnet-4-6" "$DISP_UNK"
assert_not_contains "dispatch model: unknown not forwarded" "gpt-4o" "$DISP_UNK"

# ==============================================================================
suite "launch-dispatch.sh — plan output format"
# ==============================================================================

PLAN_FILE=$(_tmpfile)
printf 'Write a unit test for the login function' > "$PLAN_FILE"

set +e
PLAN_OUT=$(GEMINI_API_KEY="" bash "$REPO_DIR/launch-dispatch.sh" \
    "@$PLAN_FILE" --no-gemini 2>&1)
set -e

# Execution plan header is printed before pipeline runs
assert_contains "plan output: step count line" "step" "$PLAN_OUT"
assert_contains "plan output: step number prefix" "1." "$PLAN_OUT"
# The plan source is shown
assert_contains "plan output: source shown" "Source:" "$PLAN_OUT"
assert_contains "plan output: heuristic source" "heuristic" "$PLAN_OUT"

# ==============================================================================
suite "run_headless_phase — OAuth token and budget env var forwarding"
# ==============================================================================

# Create a mock docker binary that records its arguments.
MOCK_DOCKER_DIR=$(_tmpdir)
DOCKER_ARG_LOG=$(_tmpfile)

cat > "$MOCK_DOCKER_DIR/docker" << MOCKEOF
#!/bin/bash
printf '%s\n' "\$*" >> "$DOCKER_ARG_LOG"
exit 0
MOCKEOF
chmod +x "$MOCK_DOCKER_DIR/docker"

_SAVED_PATH="$PATH"
PATH="$MOCK_DOCKER_DIR:$PATH"

OAUTH_TOKEN="test-access-token-UNIQUE12345"
OAUTH_REFRESH="test-refresh-token-UNIQUE67890"

# Haiku model: verify token budget values per parse_model_tier
> "$DOCKER_ARG_LOG"
set +e
run_headless_phase "test-haiku" "claude-haiku-4-5" "1" "echo hello" 2>/dev/null
set -e

HAIKU_ARGS=$(cat "$DOCKER_ARG_LOG")
assert_contains "RHP haiku: OAUTH_TOKEN forwarded" "test-access-token-UNIQUE12345" "$HAIKU_ARGS"
assert_contains "RHP haiku: OAUTH_REFRESH forwarded" "test-refresh-token-UNIQUE67890" "$HAIKU_ARGS"
assert_contains "RHP haiku: MAX_CONTEXT_TOKENS=50000" "CLAUDE_CODE_MAX_CONTEXT_TOKENS=50000" "$HAIKU_ARGS"
assert_contains "RHP haiku: TARGET_INPUT_TOKENS=25000" "API_TARGET_INPUT_TOKENS=25000" "$HAIKU_ARGS"
assert_contains "RHP haiku: MAX_THINKING_TOKENS=0" "MAX_THINKING_TOKENS=0" "$HAIKU_ARGS"
assert_contains "RHP haiku: DISABLE_AUTO_COMPACT set" "DISABLE_AUTO_COMPACT=0" "$HAIKU_ARGS"
assert_contains "RHP haiku: container name passed" "test-haiku" "$HAIKU_ARGS"
assert_contains "RHP haiku: prompt passed" "echo hello" "$HAIKU_ARGS"
assert_contains "RHP haiku: --model flag passed" "--model claude-haiku-4-5" "$HAIKU_ARGS"
assert_contains "RHP haiku: --dangerously-skip-permissions" "dangerously-skip-permissions" "$HAIKU_ARGS"

# Opus model: different budget
> "$DOCKER_ARG_LOG"
set +e
run_headless_phase "test-opus" "claude-opus-4-8" "1" "echo hello" 2>/dev/null
set -e

OPUS_ARGS=$(cat "$DOCKER_ARG_LOG")
assert_contains "RHP opus: MAX_CONTEXT_TOKENS=120000" "CLAUDE_CODE_MAX_CONTEXT_TOKENS=120000" "$OPUS_ARGS"
assert_contains "RHP opus: TARGET_INPUT_TOKENS=60000" "API_TARGET_INPUT_TOKENS=60000" "$OPUS_ARGS"
assert_contains "RHP opus: MAX_THINKING_TOKENS=24000" "MAX_THINKING_TOKENS=24000" "$OPUS_ARGS"

# Fable model
> "$DOCKER_ARG_LOG"
set +e
run_headless_phase "test-fable" "claude-fable-5" "1" "echo hello" 2>/dev/null
set -e

FABLE_ARGS=$(cat "$DOCKER_ARG_LOG")
assert_contains "RHP fable: MAX_THINKING_TOKENS=0" "MAX_THINKING_TOKENS=0" "$FABLE_ARGS"
assert_contains "RHP fable: MAX_CONTEXT_TOKENS=120000" "CLAUDE_CODE_MAX_CONTEXT_TOKENS=120000" "$FABLE_ARGS"

# MOCK_CLAUDE_EXIT is forwarded when set
> "$DOCKER_ARG_LOG"
set +e
MOCK_CLAUDE_EXIT=42 run_headless_phase "test-mock-exit" "claude-sonnet-4-6" "1" "echo hi" 2>/dev/null
set -e
MOCK_EXIT_ARGS=$(cat "$DOCKER_ARG_LOG")
assert_contains "RHP: MOCK_CLAUDE_EXIT forwarded when set" "MOCK_CLAUDE_EXIT=42" "$MOCK_EXIT_ARGS"

# MOCK_CLAUDE_EXIT absent when not set
> "$DOCKER_ARG_LOG"
unset MOCK_CLAUDE_EXIT
set +e
run_headless_phase "test-no-mock-exit" "claude-sonnet-4-6" "1" "echo hi" 2>/dev/null
set -e
NO_MOCK_ARGS=$(cat "$DOCKER_ARG_LOG")
assert_not_contains "RHP: MOCK_CLAUDE_EXIT absent when unset" "MOCK_CLAUDE_EXIT" "$NO_MOCK_ARGS"

PATH="$_SAVED_PATH"

# ==============================================================================
suite "run_headless_phase — .claude/ cleanup after phase"
# ==============================================================================

CLEANUP_TEST_DIR=$(_tmpdir)
CLEANUP_MOCK_DIR=$(_tmpdir)

cat > "$CLEANUP_MOCK_DIR/docker" << 'CMEOF'
#!/bin/bash
exit 0
CMEOF
chmod +x "$CLEANUP_MOCK_DIR/docker"

_SAVED_PATH2="$PATH"
PATH="$CLEANUP_MOCK_DIR:$PATH"

# Pre-create .claude/ to simulate session state left by a previous run
mkdir -p "$CLEANUP_TEST_DIR/.claude"
touch "$CLEANUP_TEST_DIR/.claude/state.json"

cd "$CLEANUP_TEST_DIR"
OAUTH_TOKEN="fake-token"
OAUTH_REFRESH="fake-refresh"
set +e
run_headless_phase "cleanup-test" "claude-sonnet-4-6" "1" "echo test" 2>/dev/null
set -e
cd "$INITIAL_DIR"

PATH="$_SAVED_PATH2"

CLAUDE_GONE="$([ ! -d "$CLEANUP_TEST_DIR/.claude" ] && echo "gone" || echo "still-there")"
assert_equals "run_headless_phase: .claude/ removed after phase" "gone" "$CLAUDE_GONE"

# ==============================================================================
suite "run_headless_phase — CLAUDE_SANDBOX_IMAGE override"
# ==============================================================================

IMG_MOCK_DIR=$(_tmpdir)
IMG_ARG_LOG=$(_tmpfile)

cat > "$IMG_MOCK_DIR/docker" << IMGEOF
#!/bin/bash
printf '%s\n' "\$*" >> "$IMG_ARG_LOG"
exit 0
IMGEOF
chmod +x "$IMG_MOCK_DIR/docker"

_SAVED_PATH3="$PATH"
PATH="$IMG_MOCK_DIR:$PATH"
OAUTH_TOKEN="fake-token"
OAUTH_REFRESH="fake-refresh"

# Default image (CLAUDE_SANDBOX_IMAGE unset)
unset CLAUDE_SANDBOX_IMAGE
> "$IMG_ARG_LOG"
set +e
run_headless_phase "img-test" "claude-sonnet-4-6" "1" "echo hi" 2>/dev/null
set -e
DEFAULT_IMG_ARGS=$(cat "$IMG_ARG_LOG")
assert_contains "default image: claude-sandbox used" "claude-sandbox" "$DEFAULT_IMG_ARGS"

# Custom image override
> "$IMG_ARG_LOG"
set +e
CLAUDE_SANDBOX_IMAGE="my-custom-image" \
    run_headless_phase "img-test-custom" "claude-sonnet-4-6" "1" "echo hi" 2>/dev/null
set -e
CUSTOM_IMG_ARGS=$(cat "$IMG_ARG_LOG")
assert_contains "custom image: override used" "my-custom-image" "$CUSTOM_IMG_ARGS"

PATH="$_SAVED_PATH3"

print_results
