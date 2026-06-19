#!/bin/bash
# Pipeline orchestration tests.
#
# Verifies that launch-architect.sh, launch-qa.sh, and launch-refactor.sh
# correctly orchestrate their phases, create decision logs, write expected
# output files, and handle failure/retry paths — without spending real Claude
# tokens or requiring real credentials.
#
# Strategy:
#   - launch-architect.sh and launch-refactor.sh use run_headless_phase (Docker).
#     We build claude-sandbox-mock (a minimal image whose 'claude' binary writes
#     fixture files) and set CLAUDE_SANDBOX_IMAGE=claude-sandbox-mock.
#   - launch-qa.sh delegates to launch-scripted.sh (no headless phases itself).
#     We set LAUNCH_SCRIPTED_OVERRIDE to a local script that exits 0.
#   - Phase 3 / Phase 2 remediation for QA also use LAUNCH_SCRIPTED_OVERRIDE.
#   - Gemini calls are skipped with --no-gemini in all orchestration tests.
#     Real Gemini integration is covered by test_gemini.sh.
#   - Fake credentials from tests/fixtures/valid_creds.json are placed at
#     $HOME/.claude/.credentials.json via a temp HOME override.
#
# Requires: Docker running.
set -eo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/helpers.sh"

# ---------------------------------------------------------------------------
suite "Orchestration prerequisites"
# ---------------------------------------------------------------------------

if ! docker info >/dev/null 2>&1; then
    skip "Docker not running — skipping all orchestration tests"
    print_results
    exit 0
fi
echo "  ✅ Docker is running"
TEST_PASS=$(( TEST_PASS + 1 ))

# Build mock image if not present
MOCK_DIR="$TESTS_DIR/mock"
if ! docker image inspect claude-sandbox-mock >/dev/null 2>&1; then
    echo "  Building claude-sandbox-mock..."
    docker build -q -t claude-sandbox-mock \
        -f "$MOCK_DIR/Dockerfile.mock" "$MOCK_DIR/" >/dev/null 2>&1
    echo "  ✅ claude-sandbox-mock image built"
    TEST_PASS=$(( TEST_PASS + 1 ))
else
    echo "  ✅ claude-sandbox-mock image already present"
    TEST_PASS=$(( TEST_PASS + 1 ))
fi

# ---------------------------------------------------------------------------
# Shared setup helpers
# ---------------------------------------------------------------------------

# Create a temp HOME with fake credentials
make_mock_home() {
    local h
    h=$(mktemp -d)
    mkdir -p "$h/.claude"
    cp "$TESTS_DIR/fixtures/valid_creds.json" "$h/.claude/.credentials.json"
    echo "$h"
}

# Create a mock launch-scripted.sh that exits 0 immediately
make_mock_scripted() {
    local s
    s=$(mktemp)
    printf '#!/bin/bash\nexit 0\n' > "$s"
    chmod +x "$s"
    echo "$s"
}

# Create a mock launch-scripted.sh that exits 1 (simulate failure)
make_failing_scripted() {
    local s
    s=$(mktemp)
    printf '#!/bin/bash\nexit 1\n' > "$s"
    chmod +x "$s"
    echo "$s"
}

# ---------------------------------------------------------------------------
suite "launch-qa.sh — basic orchestration (no Docker needed)"
# ---------------------------------------------------------------------------
# launch-qa.sh does not call run_headless_phase — it only calls launch-scripted.sh.
# We can test its orchestration fully with just LAUNCH_SCRIPTED_OVERRIDE.

QA_WS=$(mktemp -d)
MOCK_SCRIPTED=$(make_mock_scripted)
trap 'rm -rf "$QA_WS"; rm -f "$MOCK_SCRIPTED"' RETURN

QA_OUT=$(cd "$QA_WS" && \
    LAUNCH_SCRIPTED_OVERRIDE="$MOCK_SCRIPTED" \
    bash "$REPO_DIR/launch-qa.sh" "write tests for auth module" --no-gemini 2>&1)
QA_RC=$?

assert_equals "qa --no-gemini: exits 0" "0" "$QA_RC"
assert_contains "qa --no-gemini: Phase 1 reported" "PHASE 1" "$QA_OUT"
assert_contains "qa --no-gemini: completion message" "complete" "$(echo "$QA_OUT" | tr '[:upper:]' '[:lower:]')"

# Decision log created in workspace
DL_COUNT=$(find "$QA_WS/docs/decisions" -name "*_qa.md" 2>/dev/null | wc -l | tr -d ' ')
assert_equals "qa: decision log file created" "1" "$DL_COUNT"

DL_FILE=$(find "$QA_WS/docs/decisions" -name "*_qa.md" | head -1)
DL_CONTENT=$(cat "$DL_FILE")
assert_contains "qa decision log: pipeline name" "qa" "$DL_CONTENT"
assert_contains "qa decision log: task embedded" "write tests for auth module" "$DL_CONTENT"
assert_contains "qa decision log: final status success" "success" "$DL_CONTENT"

rm -rf "$QA_WS"
rm -f "$MOCK_SCRIPTED"

# ---------------------------------------------------------------------------
suite "launch-qa.sh — Phase 1 failure propagates"
# ---------------------------------------------------------------------------

QA_FAIL_WS=$(mktemp -d)
FAIL_SCRIPTED=$(make_failing_scripted)
trap 'rm -rf "$QA_FAIL_WS"; rm -f "$FAIL_SCRIPTED"' RETURN

set +e
cd "$QA_FAIL_WS" && \
    LAUNCH_SCRIPTED_OVERRIDE="$FAIL_SCRIPTED" \
    bash "$REPO_DIR/launch-qa.sh" "write tests for auth" --no-gemini 2>&1
FAIL_RC=$?
set -e
cd "$REPO_DIR"

assert_equals "qa: Phase 1 failure exits non-zero" "1" "$FAIL_RC"

DL_FAIL=$(find "$QA_FAIL_WS/docs/decisions" -name "*_qa.md" 2>/dev/null | head -1)
if [ -n "$DL_FAIL" ]; then
    DL_FAIL_CONTENT=$(cat "$DL_FAIL")
    assert_contains "qa: failure captured in decision log" "failed" "$DL_FAIL_CONTENT"
fi

rm -rf "$QA_FAIL_WS"
rm -f "$FAIL_SCRIPTED"

# ---------------------------------------------------------------------------
suite "launch-qa.sh — feature slug in decision log filename"
# ---------------------------------------------------------------------------

SLUG_WS=$(mktemp -d)
SLUG_SCRIPTED=$(make_mock_scripted)
trap 'rm -rf "$SLUG_WS"; rm -f "$SLUG_SCRIPTED"' RETURN

cd "$SLUG_WS" && \
    LAUNCH_SCRIPTED_OVERRIDE="$SLUG_SCRIPTED" \
    bash "$REPO_DIR/launch-qa.sh" "Write Tests for the AUTH Module!" --no-gemini >/dev/null 2>&1 || true
cd "$REPO_DIR"

DL_FILENAME=$(find "$SLUG_WS/docs/decisions" -name "*_qa.md" 2>/dev/null | head -1 | xargs basename 2>/dev/null || echo "")
assert_contains "qa: slug lowercased" "write" "$DL_FILENAME"
assert_not_contains "qa: slug has no uppercase" "A" "$(echo "$DL_FILENAME" | tr -d 'a-z0-9._-')"
assert_not_contains "qa: slug has no exclamation marks" "!" "$DL_FILENAME"

rm -rf "$SLUG_WS"
rm -f "$SLUG_SCRIPTED"

# ---------------------------------------------------------------------------
suite "launch-architect.sh — full orchestration with mock Docker"
# ---------------------------------------------------------------------------

ARCH_WS=$(mktemp -d)
ARCH_HOME=$(make_mock_home)
ARCH_SCRIPTED=$(make_mock_scripted)
trap 'rm -rf "$ARCH_WS" "$ARCH_HOME"; rm -f "$ARCH_SCRIPTED"' RETURN

ARCH_OUT=$(cd "$ARCH_WS" && \
    HOME="$ARCH_HOME" \
    CLAUDE_SANDBOX_IMAGE=claude-sandbox-mock \
    LAUNCH_SCRIPTED_OVERRIDE="$ARCH_SCRIPTED" \
    bash "$REPO_DIR/launch-architect.sh" "add a plugin system" --no-gemini 2>&1)
ARCH_RC=$?

assert_equals "architect: exits 0 on success" "0" "$ARCH_RC"
assert_contains "architect: Phase 1 reported" "PHASE 1" "$ARCH_OUT"
assert_contains "architect: Phase 2 reported" "PHASE 2" "$ARCH_OUT"
assert_contains "architect: Phase 3 reported" "PHASE 3" "$ARCH_OUT"

# Phase 1 output file created by mock claude
assert_file_exists "architect: architecture_candidates.md created" "$ARCH_WS/docs/architecture_candidates.md"
CANDS=$(cat "$ARCH_WS/docs/architecture_candidates.md")
assert_contains "architect: candidates has Option A" "Option A" "$CANDS"
assert_contains "architect: candidates has Option B" "Option B" "$CANDS"
assert_contains "architect: candidates has Option C" "Option C" "$CANDS"

# Phase 2 output file created by mock claude
assert_file_exists "architect: approved_architecture.md created" "$ARCH_WS/docs/approved_architecture.md"
SPEC=$(cat "$ARCH_WS/docs/approved_architecture.md")
assert_contains "architect: spec has selection rationale" "Rationale" "$SPEC"
assert_contains "architect: spec has implementation steps" "Implementation Steps" "$SPEC"

# Decision log
DL_COUNT=$(find "$ARCH_WS/docs/decisions" -name "*_architect.md" 2>/dev/null | wc -l | tr -d ' ')
assert_equals "architect: decision log created" "1" "$DL_COUNT"

DL_ARCH=$(find "$ARCH_WS/docs/decisions" -name "*_architect.md" | head -1)
DL_CONTENT=$(cat "$DL_ARCH")
assert_contains "architect decision log: Phase 1 section" "Phase 1" "$DL_CONTENT"
assert_contains "architect decision log: Phase 2 section" "Phase 2" "$DL_CONTENT"
assert_contains "architect decision log: outcome success" "success" "$DL_CONTENT"
assert_not_contains "architect decision log: no in-progress" "**Status:** in-progress" "$DL_CONTENT"

# .claude/ must be wiped after each headless phase (run_headless_phase does this)
assert_not_contains "architect: .claude/ not left behind" "true" \
    "$([ -d "$ARCH_WS/.claude" ] && echo true || echo false)"

rm -rf "$ARCH_WS" "$ARCH_HOME"
rm -f "$ARCH_SCRIPTED"

# ---------------------------------------------------------------------------
suite "launch-architect.sh — Phase 2 failure exits with error"
# ---------------------------------------------------------------------------

ARCH_FAIL_WS=$(mktemp -d)
ARCH_FAIL_HOME=$(make_mock_home)
trap 'rm -rf "$ARCH_FAIL_WS" "$ARCH_FAIL_HOME"' RETURN

# MOCK_CLAUDE_EXIT=1 propagates into the mock container via run_headless_phase.
# mock-claude.sh skips writing output files when EXIT_CODE != 0, so both Phase 1
# and Phase 2 produce no output files.  Phase 1 failure is non-fatal (the pipeline
# continues with a warning); Phase 2 failure causes the pipeline to exit 1.
set +e
ARCH_FAIL_OUT=$(cd "$ARCH_FAIL_WS" && \
    HOME="$ARCH_FAIL_HOME" \
    CLAUDE_SANDBOX_IMAGE=claude-sandbox-mock \
    MOCK_CLAUDE_EXIT=1 \
    bash "$REPO_DIR/launch-architect.sh" "add feature" --no-gemini 2>&1)
ARCH_FAIL_RC=$?
set -e

assert_not_contains "architect Phase 2 failure: exits non-zero" "0" "$ARCH_FAIL_RC"
assert_contains "architect Phase 2 failure: error message shown" "Phase 2 failed" "$ARCH_FAIL_OUT"

DL_FAIL_ARCH=$(find "$ARCH_FAIL_WS/docs/decisions" -name "*_architect.md" 2>/dev/null | head -1)
if [ -n "$DL_FAIL_ARCH" ]; then
    assert_contains "architect: failure logged in decision log" "failed" "$(cat "$DL_FAIL_ARCH")"
fi

rm -rf "$ARCH_FAIL_WS" "$ARCH_FAIL_HOME"

# ---------------------------------------------------------------------------
suite "launch-refactor.sh — full orchestration with mock Docker"
# ---------------------------------------------------------------------------

RF_WS=$(mktemp -d)
RF_HOME=$(make_mock_home)
RF_SCRIPTED=$(make_mock_scripted)

# Create a git repo so 'git diff' doesn't fail
git -C "$RF_WS" init -q
git -C "$RF_WS" commit --allow-empty -q -m "init"

trap 'rm -rf "$RF_WS" "$RF_HOME"; rm -f "$RF_SCRIPTED"' RETURN

RF_OUT=$(cd "$RF_WS" && \
    HOME="$RF_HOME" \
    CLAUDE_SANDBOX_IMAGE=claude-sandbox-mock \
    LAUNCH_SCRIPTED_OVERRIDE="$RF_SCRIPTED" \
    bash "$REPO_DIR/launch-refactor.sh" "fix race condition in queue" --no-gemini 2>&1)
RF_RC=$?

assert_equals "refactor: exits 0 on success" "0" "$RF_RC"
assert_contains "refactor: Phase 1 reported" "PHASE 1" "$RF_OUT"
assert_contains "refactor: Phase 2 reported" "PHASE 2" "$RF_OUT"
assert_contains "refactor: Phase 3 reported" "PHASE 3" "$RF_OUT"

assert_file_exists "refactor: refactor_candidates.md created" "$RF_WS/docs/refactor_candidates.md"
assert_file_exists "refactor: approved_fix.md created" "$RF_WS/docs/approved_fix.md"

CANDIDATES=$(cat "$RF_WS/docs/refactor_candidates.md")
assert_contains "refactor: candidates has Option A" "Option A" "$CANDIDATES"
assert_contains "refactor: candidates has Minimal Patch" "Minimal Patch" "$CANDIDATES"

FIX=$(cat "$RF_WS/docs/approved_fix.md")
assert_contains "refactor: fix has selection rationale" "Rationale" "$FIX"

DL_RF=$(find "$RF_WS/docs/decisions" -name "*_refactor.md" | head -1)
DL_RF_CONTENT=$(cat "$DL_RF")
assert_contains "refactor decision log: Phase 1 section" "Phase 1" "$DL_RF_CONTENT"
assert_contains "refactor decision log: Phase 2 section" "Phase 2" "$DL_RF_CONTENT"
assert_contains "refactor decision log: outcome success" "success" "$DL_RF_CONTENT"

rm -rf "$RF_WS" "$RF_HOME"
rm -f "$RF_SCRIPTED"

# ---------------------------------------------------------------------------
suite "launch-refactor.sh — Phase 3 failure captured in decision log"
# ---------------------------------------------------------------------------

RF_FAIL_WS=$(mktemp -d)
RF_FAIL_HOME=$(make_mock_home)
FAIL_SCRIPTED2=$(make_failing_scripted)
git -C "$RF_FAIL_WS" init -q
git -C "$RF_FAIL_WS" commit --allow-empty -q -m "init"

set +e
cd "$RF_FAIL_WS" && \
    HOME="$RF_FAIL_HOME" \
    CLAUDE_SANDBOX_IMAGE=claude-sandbox-mock \
    LAUNCH_SCRIPTED_OVERRIDE="$FAIL_SCRIPTED2" \
    bash "$REPO_DIR/launch-refactor.sh" "fix queue" --no-gemini >/dev/null 2>&1
RF_FAIL_RC=$?
cd "$REPO_DIR"
set -e

assert_not_contains "refactor Phase 3 failure: exits non-zero" "0" "$RF_FAIL_RC"

DL_RFAIL=$(find "$RF_FAIL_WS/docs/decisions" -name "*_refactor.md" 2>/dev/null | head -1)
if [ -n "$DL_RFAIL" ]; then
    assert_contains "refactor: Phase 3 failure in decision log" "failed" "$(cat "$DL_RFAIL")"
fi

rm -rf "$RF_FAIL_WS" "$RF_FAIL_HOME"
rm -f "$FAIL_SCRIPTED2"

print_results
