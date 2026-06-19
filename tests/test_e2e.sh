#!/bin/bash
# Full end-to-end tests for the three pipeline scripts.
#
# These tests run REAL Claude instances against REAL self-contained codebases in
# tests/e2e/.  They take several minutes each, consume Claude Pro quota, and
# require both Docker and valid credentials.  They are intentionally excluded
# from the default `--all` run and must be triggered explicitly with --e2e.
#
# Each test:
#   1. Copies a test workspace to a fresh temp directory
#   2. Runs the pipeline script against it
#   3. Verifies structural outputs (files created, tests pass, decision log complete)
#
# Environment:
#   CLAUDE_E2E_MODEL   Override the implementation model (default: claude-sonnet-4-6)
#   GEMINI_API_KEY     Optional: enables Gemini audit phases
#
# Usage:
#   ./tests/run_tests.sh --e2e
#   CLAUDE_E2E_MODEL=claude-haiku-4-5 ./tests/run_tests.sh --e2e
set -eo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
E2E_DIR="$TESTS_DIR/e2e"
source "$TESTS_DIR/helpers.sh"

# Load .env.local for GEMINI_API_KEY if present
[ -f "$REPO_DIR/.env.local" ] && source "$REPO_DIR/.env.local"

IMPL_MODEL="${CLAUDE_E2E_MODEL:-claude-sonnet-4-6}"

# ---------------------------------------------------------------------------
suite "E2E prerequisites"
# ---------------------------------------------------------------------------

if ! docker info >/dev/null 2>&1; then
    skip "Docker not running — skipping all E2E tests"
    print_results
    exit 0
fi
echo "  ✅ Docker is running"
TEST_PASS=$(( TEST_PASS + 1 ))

if ! docker image inspect claude-sandbox >/dev/null 2>&1; then
    skip "claude-sandbox image not found — run: docker build -t claude-sandbox -f Dockerfile.claude ."
    print_results
    exit 0
fi
echo "  ✅ claude-sandbox image exists"
TEST_PASS=$(( TEST_PASS + 1 ))

CREDS="$HOME/.claude/.credentials.json"
if [ ! -f "$CREDS" ]; then
    skip "No credentials at $CREDS — run: claude auth login --claudeai && claude-box-auth"
    print_results
    exit 0
fi
echo "  ✅ Credentials present"
TEST_PASS=$(( TEST_PASS + 1 ))

echo "  Using model: $IMPL_MODEL"
[ -n "${GEMINI_API_KEY:-}" ] && echo "  Gemini: enabled" || echo "  Gemini: disabled (no GEMINI_API_KEY)"

GEMINI_FLAG=""
[ -z "${GEMINI_API_KEY:-}" ] && GEMINI_FLAG="--no-gemini"

# ---------------------------------------------------------------------------
# Helper: copy a test workspace to a temp dir and return the path
# ---------------------------------------------------------------------------
clone_workspace() {
    local src="$1"
    local dest
    dest=$(mktemp -d)
    cp -r "$src/." "$dest/"
    echo "$dest"
}

# ---------------------------------------------------------------------------
suite "E2E: claude-qa on python-calculator"
# ---------------------------------------------------------------------------
# Goal: Claude writes a pytest suite for calculator.py, Gemini finds edge cases
# it missed, Claude fills them in. All tests must pass at the end.

echo ""
echo "  ⏳ Starting claude-qa on python-calculator (may take several minutes)..."

QA_WS=$(clone_workspace "$E2E_DIR/python-calculator")
trap 'rm -rf "$QA_WS"' RETURN

QA_OUT=$(cd "$QA_WS" && \
    bash "$REPO_DIR/launch-qa.sh" \
        "Write a thorough pytest suite for calculator.py covering all functions, edge cases, type errors, and boundary conditions." \
        "$IMPL_MODEL" $GEMINI_FLAG 2>&1)
QA_RC=$?

assert_equals "qa e2e: pipeline exits 0" "0" "$QA_RC"

# At least one test file must exist
TEST_FILES=$(find "$QA_WS" -name "test_*.py" -o -name "*_test.py" 2>/dev/null | wc -l | tr -d ' ')
assert_not_contains "qa e2e: test files created" "0" "$TEST_FILES"

# Run the generated tests inside a Docker container to verify they pass
echo "  Verifying generated tests pass..."
VERIFY_OUT=$(docker run --rm \
    -v "$QA_WS":/workspace \
    claude-sandbox \
    bash -c "cd /workspace && pip install -q -r requirements.txt 2>/dev/null && python -m pytest -v --tb=short 2>&1" 2>&1)
VERIFY_RC=$?
assert_equals "qa e2e: generated tests pass" "0" "$VERIFY_RC"
assert_contains "qa e2e: pytest reports passed" "passed" "$(echo "$VERIFY_OUT" | tr '[:upper:]' '[:lower:]')"

# Check decision log exists and is complete
DL=$(find "$QA_WS/docs/decisions" -name "*_qa.md" 2>/dev/null | head -1)
assert_file_exists "qa e2e: decision log exists" "$DL"
DL_CONTENT=$(cat "$DL")
assert_contains "qa e2e: decision log has task" "calculator" "$(echo "$DL_CONTENT" | tr '[:upper:]' '[:lower:]')"
assert_not_contains "qa e2e: decision log not in-progress" "**Status:** in-progress" "$DL_CONTENT"

# Count test functions (should be more than just happy paths)
TEST_FUNC_COUNT=$(grep -rh "^def test_" "$QA_WS" --include="*.py" 2>/dev/null | wc -l | tr -d ' ')
assert_equals "qa e2e: at least 10 test functions written" "true" \
    "$([ "$TEST_FUNC_COUNT" -ge 10 ] && echo true || echo false)"

echo "  ✅ claude-qa e2e: $TEST_FUNC_COUNT test functions, all passing"
rm -rf "$QA_WS"

# ---------------------------------------------------------------------------
suite "E2E: claude-refactor on buggy-python"
# ---------------------------------------------------------------------------
# Goal: Claude fixes the thread-safety bug in queue.py. The thread-safety
# tests (test_concurrent_puts_never_exceed_maxsize, test_concurrent_gets_no_index_error)
# must pass reliably after the fix.

echo ""
echo "  ⏳ Starting claude-refactor on buggy-python (may take several minutes)..."

RF_WS=$(clone_workspace "$E2E_DIR/buggy-python")
git -C "$RF_WS" init -q
git -C "$RF_WS" add -A
git -C "$RF_WS" commit -q -m "initial buggy state"

RF_OUT=$(cd "$RF_WS" && \
    bash "$REPO_DIR/launch-refactor.sh" \
        "Fix the thread-safety race condition in queue.py. The put() and get() methods have a check-then-act bug where the emptiness/fullness guard is outside the lock. The concurrent tests in test_queue.py expose this bug." \
        "$IMPL_MODEL" $GEMINI_FLAG 2>&1)
RF_RC=$?

assert_equals "refactor e2e: pipeline exits 0" "0" "$RF_RC"

# The fix plan must exist
assert_file_exists "refactor e2e: approved_fix.md created" "$RF_WS/docs/approved_fix.md"

# All tests must pass after the fix
echo "  Verifying all tests pass after fix..."
RF_VERIFY=$(docker run --rm \
    -v "$RF_WS":/workspace \
    claude-sandbox \
    bash -c "cd /workspace && pip install -q -r requirements.txt 2>/dev/null && python -m pytest test_queue.py -v --tb=short 2>&1" 2>&1)
RF_VERIFY_RC=$?
assert_equals "refactor e2e: all tests pass after fix" "0" "$RF_VERIFY_RC"
assert_not_contains "refactor e2e: no failures" "FAILED" "$RF_VERIFY"

# The concurrent tests must pass (they're the ones that expose the race condition)
assert_contains "refactor e2e: concurrent put test passes" "PASSED" \
    "$(echo "$RF_VERIFY" | grep "test_concurrent_puts" || echo "")"

# Decision log should document the fix
DL_RF=$(find "$RF_WS/docs/decisions" -name "*_refactor.md" 2>/dev/null | head -1)
assert_file_exists "refactor e2e: decision log exists" "$DL_RF"
DL_RF_CONTENT=$(cat "$DL_RF")
assert_contains "refactor e2e: candidates section in log" "Phase 1" "$DL_RF_CONTENT"
assert_contains "refactor e2e: fix section in log" "Phase 2" "$DL_RF_CONTENT"
assert_not_contains "refactor e2e: log is complete" "**Status:** in-progress" "$DL_RF_CONTENT"

echo "  ✅ claude-refactor e2e: race condition fixed, all tests passing"
rm -rf "$RF_WS"

# ---------------------------------------------------------------------------
suite "E2E: claude-architect on js-todo"
# ---------------------------------------------------------------------------
# Goal: Claude designs and implements a persistence layer for the todo list.
# After the run, npm test must pass, including new tests for persistence.

echo ""
echo "  ⏳ Starting claude-architect on js-todo (may take several minutes)..."

ARCH_WS=$(clone_workspace "$E2E_DIR/js-todo")

ARCH_OUT=$(cd "$ARCH_WS" && \
    bash "$REPO_DIR/launch-architect.sh" \
        "Add persistence to the todo list so todos survive process restarts. The public API (add, get, complete, delete, list, count) must not change. Use file-based storage (JSON or similar) — no external services." \
        "$IMPL_MODEL" $GEMINI_FLAG 2>&1)
ARCH_RC=$?

assert_equals "architect e2e: pipeline exits 0" "0" "$ARCH_RC"

# The spec must exist
assert_file_exists "architect e2e: approved_architecture.md created" "$ARCH_WS/docs/approved_architecture.md"
SPEC_CONTENT=$(cat "$ARCH_WS/docs/approved_architecture.md")
assert_not_contains "architect e2e: spec is non-empty" "" "$SPEC_CONTENT"

# Tests must pass (npm test runs jest)
echo "  Verifying npm test passes..."
ARCH_VERIFY=$(docker run --rm \
    -v "$ARCH_WS":/workspace \
    claude-sandbox \
    bash -c "cd /workspace && npm install --silent 2>/dev/null && npm test 2>&1" 2>&1)
ARCH_VERIFY_RC=$?
assert_equals "architect e2e: npm test passes" "0" "$ARCH_VERIFY_RC"
assert_contains "architect e2e: jest reports tests passing" "passed" \
    "$(echo "$ARCH_VERIFY" | tr '[:upper:]' '[:lower:]')"

# There should be test files that cover persistence (survive restart)
PERSIST_TESTS=$(grep -rl "persist\|surviv\|restart\|reload\|load\|read.*file\|file.*read" \
    "$ARCH_WS" --include="*.js" --include="*.ts" 2>/dev/null | wc -l | tr -d ' ')
assert_equals "architect e2e: persistence tests written" "true" \
    "$([ "$PERSIST_TESTS" -ge 1 ] && echo true || echo false)"

# Decision log
DL_ARCH=$(find "$ARCH_WS/docs/decisions" -name "*_architect.md" 2>/dev/null | head -1)
assert_file_exists "architect e2e: decision log exists" "$DL_ARCH"
DL_ARCH_CONTENT=$(cat "$DL_ARCH")
assert_contains "architect e2e: candidates section in log" "Phase 1" "$DL_ARCH_CONTENT"
assert_contains "architect e2e: approved spec section in log" "Phase 2" "$DL_ARCH_CONTENT"
assert_not_contains "architect e2e: log is complete" "**Status:** in-progress" "$DL_ARCH_CONTENT"

echo "  ✅ claude-architect e2e: persistence implemented, all tests passing"
rm -rf "$ARCH_WS"

print_results
