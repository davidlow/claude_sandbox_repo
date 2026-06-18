#!/bin/bash
set -eo pipefail
# Note: -u (nounset) is intentionally omitted. Claude Code's bash shell
# integration installs hooks that reference $ZSH_VERSION, which is unset in
# bash. With -u active, those hooks error-out and break docker tee pipelines.

[ -f "$(dirname "${BASH_SOURCE[0]}")/.env.local" ] && source "$(dirname "${BASH_SOURCE[0]}")/.env.local"

# ==============================================================================
# claude-refactor — Multi-Stage Bug Fix & Refactoring Pipeline
#
# Runs a three-phase pipeline that separates diagnosis, planning, and execution
# into isolated containers. .claude/ is wiped between phases so the implementing
# model focuses only on the approved plan, not the diagnostic history.
#
#   Phase 1  Diagnose    (haiku)  Analyze the issue, generate 3 solution options
#   Phase 2  Evaluate    (sonnet) Select best option, write step-by-step plan
#   Phase 3  Implement   (chosen) Apply the plan, run tests, fix failures
#
# Gemini acts as a circuit-breaker in Phase 3: if implementation fails,
# launch-scripted.sh sends the failure context to Gemini for diagnosis before
# each retry (the standard cross-model audit behavior).
#
# USAGE:
#    claude-refactor "bug or refactor description" [model] [--no-gemini]
#
# ARGUMENTS:
#    "target"    Bug description or refactor goal.
#    model       (Optional) Model for Phase 3 implementation. Default: claude-sonnet-4-6.
#    --no-gemini Disable Gemini circuit-breaker in Phase 3.
#
# EXAMPLES:
#    claude-refactor "fix the race condition in the job queue"
#    claude-refactor "reduce coupling in the user service" claude-opus-4-8
#    claude-refactor "the payment processor fails on retry" --no-gemini
#
# INTERMEDIATE FILES (kept on disk for review after the run):
#    docs/refactor_candidates.md  3 solution options from Phase 1
#    docs/approved_fix.md         Implementation plan from Phase 2
#
# SETUP:
#    Run claude-box-auth once before first use. Export GEMINI_API_KEY to enable
#    the Gemini circuit-breaker in Phase 3.
# ==============================================================================

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    sed -n '/^# ====/,/^# ====/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
    exit 0
fi

source "$(dirname "$0")/lib/launch-lib.sh"
parse_args "$@"

CREDS="$HOME/.claude/.credentials.json"
if [ ! -f "$CREDS" ]; then
    echo "❌ Error: No Claude credentials found at $CREDS"
    echo "   Log in with: claude auth login --claudeai"
    exit 1
fi

if [ -z "${ORIGINAL_TASK_PROMPT:-}" ]; then
    echo "❌ Error: You must provide a bug description or refactor target."
    echo "   Usage: claude-refactor \"your target\" [model] [--no-gemini]"
    exit 1
fi

[ -z "${GEMINI_API_KEY:-}" ] && GEMINI_ENABLED=false

OAUTH_TOKEN=$(python3 -c "
import json
with open('$CREDS') as f:
    print(json.load(f)['claudeAiOauth']['accessToken'])
" 2>/dev/null)
OAUTH_REFRESH=$(python3 -c "
import json
with open('$CREDS') as f:
    print(json.load(f)['claudeAiOauth']['refreshToken'])
" 2>/dev/null)

if [ -z "$OAUTH_TOKEN" ]; then
    echo "❌ Error: Could not read OAuth token from $CREDS"
    echo "   Run 'claude-box-auth' to refresh your credentials."
    exit 1
fi

SANITIZED_DIR=$(basename "$(pwd)" | tr -cs '[:alnum:]-' '-' | tr '[:upper:]' '[:lower:]')
BASE_CONTAINER="claude-refactor-${SANITIZED_DIR:-sandbox}-$$"

if ! docker info >/dev/null 2>&1; then
    echo "❌ Error: Docker is not running or not accessible. Start Docker and try again."
    exit 1
fi

DIAGNOSE_MODEL="claude-haiku-4-5"
EVAL_MODEL="claude-sonnet-4-6"

mkdir -p docs

echo "🔧 claude-refactor pipeline"
echo "   Target:  $ORIGINAL_TASK_PROMPT"
echo "   Impl:    $CHOSEN_MODEL"
echo "   Gemini:  $([ "$GEMINI_ENABLED" = true ] && echo "enabled (circuit-breaker in Phase 3)" || echo "disabled")"
echo ""

# Capture current diff so the diagnosis phase can see uncommitted changes.
DIFF_FILE=".current_state.diff"
git diff > "$DIFF_FILE" 2>/dev/null || true

# CLAUDE.md bootstrap before Phase 1 if absent.
if [ ! -f "CLAUDE.md" ]; then
    echo "⚠️  CLAUDE.md not found. Generating before pipeline..."
    run_headless_phase "${BASE_CONTAINER}-setup" "$DIAGNOSE_MODEL" "5" \
        "Analyze this codebase and create a CLAUDE.md file in the root directory. Follow standard Claude Code conventions: project purpose, exact build/test/lint commands, file layout, and engineering/style guidelines. Do not perform any other tasks." || true
    [ -f "CLAUDE.md" ] && echo "✅ CLAUDE.md created." || echo "⚠️  CLAUDE.md creation failed. Continuing."
    echo ""
fi

# ==============================================================================
# PHASE 1: DIAGNOSE (haiku)
# Analyzes the problem and generates 3 solution options — no code changes.
# .current_state.diff is mounted so the model sees uncommitted context.
# ==============================================================================
echo "🔍 PHASE 1: Diagnosing and proposing solutions (${DIAGNOSE_MODEL})..."

PHASE1_PROMPT="Analyze this workspace and .current_state.diff (recent uncommitted changes) for the following: '${ORIGINAL_TASK_PROMPT}'.

Generate exactly 3 solution options and save them to docs/refactor_candidates.md:

## Option A: Minimal Patch
**Strategy:** Smallest targeted change, lowest blast radius
**Changes required:** ...
**Trade-offs:** risk, coverage, side effects

## Option B: Structural Fix
**Strategy:** Address the root cause with a moderate refactor
**Changes required:** ...
**Trade-offs:** risk, coverage, side effects

## Option C: Module Rewrite
**Strategy:** Clean rewrite of the isolated component for clarity/performance
**Changes required:** ...
**Trade-offs:** risk, coverage, side effects

Do NOT modify any source code. Analysis and proposals only."

PHASE1_CODE=0
run_headless_phase "${BASE_CONTAINER}-phase1" "$DIAGNOSE_MODEL" "10" "$PHASE1_PROMPT" \
    || PHASE1_CODE=$?

# Diff is no longer needed — clean up before Phase 2.
rm -f "$DIFF_FILE"

if [ $PHASE1_CODE -ne 0 ] || [ ! -f "docs/refactor_candidates.md" ]; then
    echo "⚠️  Phase 1 attempt 1 failed (exit ${PHASE1_CODE}). Retrying..."
    # Regenerate diff for the retry.
    git diff > "$DIFF_FILE" 2>/dev/null || true
    PHASE1_CODE=0
    run_headless_phase "${BASE_CONTAINER}-phase1r" "$DIAGNOSE_MODEL" "10" "$PHASE1_PROMPT" \
        || PHASE1_CODE=$?
    rm -f "$DIFF_FILE"
fi

if [ -f "docs/refactor_candidates.md" ]; then
    echo "✅ Phase 1 complete: docs/refactor_candidates.md"
else
    echo "⚠️  Phase 1 produced no output. Phase 2 will diagnose and select independently."
fi
echo ""

# ==============================================================================
# PHASE 2: EVALUATE (sonnet)
# Selects the best solution option and writes a concrete implementation plan.
# ==============================================================================
echo "⚖️  PHASE 2: Evaluating and selecting solution (${EVAL_MODEL})..."

PHASE2_PROMPT="You are a senior engineer reviewing proposed solutions for: '${ORIGINAL_TASK_PROMPT}'."
if [ -f "docs/refactor_candidates.md" ]; then
    PHASE2_PROMPT+=" Read docs/refactor_candidates.md (three proposed solutions from Phase 1 analysis)."
else
    PHASE2_PROMPT+=" No Phase 1 proposals were produced. Analyze the workspace yourself and generate 3 distinct options (minimal patch, structural fix, module rewrite), then evaluate them."
fi
PHASE2_PROMPT+="

Select the most maintainable and appropriately-scoped approach. Write a strict step-by-step implementation plan to docs/approved_fix.md:
- Which option was selected and the rationale
- Exact files to modify or create
- The specific changes to make at each location
- How to verify the fix (which tests to run, what output to expect)

Be specific enough that an engineer can implement without reading any other context. Do NOT write executable code."

PHASE2_CODE=0
run_headless_phase "${BASE_CONTAINER}-phase2" "$EVAL_MODEL" "10" "$PHASE2_PROMPT" \
    || PHASE2_CODE=$?

if [ $PHASE2_CODE -ne 0 ] || [ ! -f "docs/approved_fix.md" ]; then
    echo "⚠️  Phase 2 attempt 1 failed (exit ${PHASE2_CODE}). Retrying..."
    PHASE2_CODE=0
    run_headless_phase "${BASE_CONTAINER}-phase2r" "$EVAL_MODEL" "10" "$PHASE2_PROMPT" \
        || PHASE2_CODE=$?
fi

if [ ! -f "docs/approved_fix.md" ]; then
    echo "❌ Phase 2 failed to produce an implementation plan after 2 attempts."
    echo "   Check docs/refactor_candidates.md for Phase 1 output."
    exit 1
fi
echo "✅ Phase 2 complete: docs/approved_fix.md"
echo ""

# ==============================================================================
# PHASE 3: IMPLEMENT + VERIFY
# Delegates to launch-scripted.sh for the full retry/recovery loop.
# Gemini acts as a circuit-breaker on failure: if implementation fails,
# the standard Gemini audit diagnoses the approach before each retry.
# ==============================================================================
echo "🛠️  PHASE 3: Implementing approved fix (${CHOSEN_MODEL})..."
IMPL_PROMPT="Read docs/approved_fix.md. Apply the exact implementation plan described there, making only the changes specified. After implementation, run the project test suite. If tests fail, fix them — but only in ways consistent with the approved plan."
IMPL_ARGS=("$IMPL_PROMPT" "$CHOSEN_MODEL")
[ "$GEMINI_ENABLED" = "false" ] && IMPL_ARGS+=("--no-gemini")

exec "$(dirname "$0")/launch-scripted.sh" "${IMPL_ARGS[@]}"
