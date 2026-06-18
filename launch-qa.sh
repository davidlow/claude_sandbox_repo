#!/bin/bash
set -eo pipefail
# Note: -u (nounset) is intentionally omitted. Claude Code's bash shell
# integration installs hooks that reference $ZSH_VERSION, which is unset in
# bash. With -u active, those hooks error-out and break docker tee pipelines.

[ -f "$(dirname "${BASH_SOURCE[0]}")/.env.local" ] && source "$(dirname "${BASH_SOURCE[0]}")/.env.local"

# ==============================================================================
# claude-qa — Adversarial Test Generation Pipeline
#
# Runs a two-phase pipeline for building robust test suites:
#
#   Phase 1  Generate + Fix   Write tests, run them, fix all failures.
#   Gemini   Red Team Audit   Identify edge cases the initial suite misses.
#   Phase 2  Remediate        Implement every missing test from the audit.
#
# Without GEMINI_API_KEY set (or with --no-gemini), only Phase 1 runs —
# still useful as a full retry/recovery wrapper for test writing tasks.
#
# USAGE:
#    claude-qa "what to test / scope" [model] [--no-gemini]
#
# ARGUMENTS:
#    "scope"     What to test — a module, feature, or file path.
#    model       (Optional) Claude model. Default: claude-sonnet-4-6.
#    --no-gemini Skip Gemini adversarial audit (Phase 2 will not run).
#
# EXAMPLES:
#    claude-qa "write tests for the auth module"
#    claude-qa "add integration tests for the payments API" claude-opus-4-8
#    claude-qa "test the file upload handler" --no-gemini
#
# OUTPUT FILES (kept on disk for review):
#    tests/gemini_missing_coverage.md              Gemini adversarial audit findings (if run)
#    docs/decisions/YYYY-MM-DD_HHMM_<task>_qa.md  Timestamped decision log
#
# SETUP:
#    Run claude-box-auth once before first use. Export GEMINI_API_KEY to enable audit.
# ==============================================================================

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    sed -n '/^# ====/,/^# ====/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
    exit 0
fi

source "$(dirname "$0")/lib/launch-lib.sh"
parse_args "$@"

if [ -z "${ORIGINAL_TASK_PROMPT:-}" ]; then
    echo "❌ Error: You must provide a task description."
    echo "   Usage: claude-qa \"what to test\" [model] [--no-gemini]"
    exit 1
fi

[ -z "${GEMINI_API_KEY:-}" ] && GEMINI_ENABLED=false

mkdir -p docs/decisions
TIMESTAMP=$(date '+%Y-%m-%d_%H%M')
FEATURE_SLUG=$(printf '%s' "$ORIGINAL_TASK_PROMPT" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -cs 'a-z0-9' '-' \
    | sed 's/-\{2,\}/-/g; s/^-//; s/-$//' \
    | cut -c1-40 \
    | sed 's/-$//')
DECISION_FILE="docs/decisions/${TIMESTAMP}_${FEATURE_SLUG}_qa.md"
decision_log_init "$DECISION_FILE" "qa" "$ORIGINAL_TASK_PROMPT" "$CHOSEN_MODEL"

GEMINI_PROMPT_FILE="/tmp/claude_qa_gemini_$$.txt"
QA_PAYLOAD_FILE="/tmp/claude_qa_payload_$$.txt"
trap 'rm -f "$GEMINI_PROMPT_FILE" "$QA_PAYLOAD_FILE"' EXIT

SCRIPT_DIR="$(dirname "$0")"

echo "🧪 claude-qa pipeline"
echo "   Task:   $ORIGINAL_TASK_PROMPT"
echo "   Model:  $CHOSEN_MODEL"
echo "   Gemini: $([ "$GEMINI_ENABLED" = true ] && echo "enabled (adversarial audit after Phase 1)" || echo "disabled")"
echo "   Log:    $DECISION_FILE"
echo ""

# ==============================================================================
# PHASE 1: TEST GENERATION + FIX
# Full retry/recovery loop via launch-scripted.sh. Claude writes the initial
# test suite, runs it, and iterates until all tests pass.
# ==============================================================================
echo "🧪 PHASE 1: Generating and fixing test suite (${CHOSEN_MODEL})..."

PHASE1_PROMPT="Write a comprehensive test suite for: ${ORIGINAL_TASK_PROMPT}. Cover: happy paths, common error cases, and edge cases you can identify from the code. Run the tests immediately after writing them. Fix any failures. The full suite must pass cleanly before you stop."

PHASE1_ARGS=("$PHASE1_PROMPT" "$CHOSEN_MODEL")
[ "$GEMINI_ENABLED" = "false" ] && PHASE1_ARGS+=("--no-gemini")

"$SCRIPT_DIR/launch-scripted.sh" "${PHASE1_ARGS[@]}"
PHASE1_EXIT=$?

if [ $PHASE1_EXIT -ne 0 ]; then
    echo "❌ Phase 1 (test generation) failed after all retries."
    decision_log_outcome "$DECISION_FILE" "failed" "Phase 1 (test generation) failed after all retries."
    exit 1
fi

decision_log_note "$DECISION_FILE" "Phase 1: Test Generation" "Phase 1 completed — initial test suite written and passing."
echo "✅ Phase 1 complete."
echo ""

# ==============================================================================
# GEMINI ADVERSARIAL AUDIT
# Bundles source code and test files into a payload, sends to Gemini with an
# adversarial Red Team prompt to find coverage gaps Claude missed.
# ==============================================================================
if [ "$GEMINI_ENABLED" = "false" ]; then
    decision_log_outcome "$DECISION_FILE" "success" "Completed Phase 1 only (Gemini audit skipped — no key or --no-gemini)."
    echo "✅ QA pipeline complete (Gemini audit skipped — no key or --no-gemini)."
    exit 0
fi

echo "🕵️  Gemini adversarial audit: scanning for missing coverage..."

# Bundle source and test files (skip generated/dependency directories).
# 500KB cap — well under Gemini's ~4MB practical limit but bounded for cost control.
FILE_LIST=$(find . -type f \( \
    -name "*.py" -o -name "*.js" -o -name "*.ts" -o -name "*.tsx" -o \
    -name "*.go" -o -name "*.rs" -o -name "*.java" -o -name "*.rb" -o \
    -name "*.sh" -o -name "*.bash" -o -name "*.c" -o -name "*.cpp" \
\) \
-not -path "*/node_modules/*" \
-not -path "*/.git/*" \
-not -path "*/__pycache__/*" \
-not -path "*/dist/*" \
-not -path "*/build/*" \
-not -path "*/vendor/*" \
-not -path "*/.venv/*" \
2>/dev/null | sort)

FILE_COUNT=$(printf '%s\n' "$FILE_LIST" | grep -c . 2>/dev/null || echo "0")

{
    printf '%s\n' "$FILE_LIST" | while IFS= read -r f; do
        [ -z "$f" ] && continue
        printf '\n--- %s ---\n' "$f"
        cat "$f" 2>/dev/null || true
    done
} | head -c 500000 > "$QA_PAYLOAD_FILE"

PAYLOAD_BYTES=$(wc -c < "$QA_PAYLOAD_FILE" 2>/dev/null || echo "0")
echo "   Bundled $FILE_COUNT source/test files ($(( PAYLOAD_BYTES / 1024 ))KB payload)"
[ "$PAYLOAD_BYTES" -ge 499990 ] && echo "   ⚠️  Payload hit 500KB cap — some files may be truncated"

build_gemini_qa_prompt "$ORIGINAL_TASK_PROMPT" "$QA_PAYLOAD_FILE" > "$GEMINI_PROMPT_FILE"

mkdir -p tests
if call_gemini "$GEMINI_PROMPT_FILE" "tests/gemini_missing_coverage.md"; then
    echo "✅ Gemini audit saved to tests/gemini_missing_coverage.md"
    decision_log_section "$DECISION_FILE" "Gemini Adversarial Audit" "tests/gemini_missing_coverage.md"
else
    echo "⚠️  Gemini audit failed — no Phase 2 will run."
    decision_log_note "$DECISION_FILE" "Gemini Adversarial Audit" "Gemini audit failed — Phase 2 skipped."
    decision_log_outcome "$DECISION_FILE" "success" "Completed Phase 1 only (Gemini audit failed)."
    echo "✅ QA pipeline complete (Phase 1 only)."
    exit 0
fi
echo ""

# Wipe session so Phase 2 starts with a fresh context focused only on the gaps.
rm -rf .claude/ 2>/dev/null || true

# ==============================================================================
# PHASE 2: REMEDIATION
# Claude reads Gemini's findings and implements every missing test case.
# ==============================================================================
echo "🛡️  PHASE 2: Implementing missing coverage (${CHOSEN_MODEL})..."

PHASE2_PROMPT="Read tests/gemini_missing_coverage.md. It contains a numbered list of missing test cases identified by an adversarial Red Team audit. Implement every test listed. Run the full test suite after implementing all new tests and ensure everything passes. Also review docs/decisions/ for past QA pipeline logs — they may reveal which areas have had persistent coverage gaps on this codebase."

PHASE2_ARGS=("$PHASE2_PROMPT" "$CHOSEN_MODEL")
# Always allow Gemini in Phase 2 for its own failure recovery — the key is set.

"$SCRIPT_DIR/launch-scripted.sh" "${PHASE2_ARGS[@]}"
PHASE2_EXIT=$?

if [ $PHASE2_EXIT -ne 0 ]; then
    echo "❌ Phase 2 (remediation) failed. tests/gemini_missing_coverage.md kept for review."
    decision_log_outcome "$DECISION_FILE" "failed" "Phase 2 (coverage remediation) failed. See tests/gemini_missing_coverage.md."
    exit 1
fi

decision_log_note "$DECISION_FILE" "Phase 2: Coverage Remediation" "Phase 2 completed — all missing tests from Gemini audit implemented and passing."
decision_log_outcome "$DECISION_FILE" "success" "Full adversarial test suite passing."
echo "✅ QA pipeline complete. Full adversarial test suite passing."
