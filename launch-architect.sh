#!/bin/bash
set -eo pipefail
# Note: -u (nounset) is intentionally omitted. Claude Code's bash shell
# integration installs hooks that reference $ZSH_VERSION, which is unset in
# bash. With -u active, those hooks error-out and break docker tee pipelines.

[ -f "$(dirname "${BASH_SOURCE[0]}")/.env.local" ] && source "$(dirname "${BASH_SOURCE[0]}")/.env.local"

# ==============================================================================
# claude-architect — Multi-Stage Architectural Design & Implementation Pipeline
#
# Runs a three-phase pipeline that physically separates brainstorming, evaluation,
# and implementation into isolated containers. .claude/ is wiped between phases
# to prevent cognitive anchoring on discarded ideas.
#
#   Phase 1  Brainstorm  (haiku)   Generate 3 distinct architectural approaches
#   Gemini   Critique    (optional) Adversarial review of each candidate
#   Phase 2  Evaluate    (sonnet)  Select best approach, write implementation spec
#   Phase 3  Implement   (chosen)  Implement the approved spec with full recovery
#
# Intermediate artifacts are written to docs/ for review after the run.
#
# USAGE:
#    claude-architect "feature or task description" [model] [--no-gemini]
#
# ARGUMENTS:
#    "task"      What to design and build.
#    model       (Optional) Model for Phase 3 implementation. Default: claude-sonnet-4-6.
#    --no-gemini Disable Gemini architectural critique between phases 1 and 2.
#
# EXAMPLES:
#    claude-architect "add a plugin system to the CLI"
#    claude-architect "design a caching layer for the API" claude-opus-4-8
#    claude-architect "redesign the auth module" --no-gemini
#
# INTERMEDIATE FILES (kept on disk for review after the run):
#    docs/architecture_candidates.md              3 approaches from Phase 1
#    docs/gemini_architectural_audit.md           Gemini critique (if enabled)
#    docs/approved_architecture.md                Implementation spec from Phase 2
#    docs/decisions/YYYY-MM-DD_HHMM_<task>_architect.md  Timestamped decision log
#
# SETUP:
#    Run claude-box-auth once before first use. Export GEMINI_API_KEY to enable critique.
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
    echo "❌ Error: You must provide a task description."
    echo "   Usage: claude-architect \"your task\" [model] [--no-gemini]"
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
BASE_CONTAINER="claude-arch-${SANITIZED_DIR:-sandbox}-$$"
GEMINI_PROMPT_FILE="/tmp/claude_arch_gemini_$$.txt"
trap 'rm -f "$GEMINI_PROMPT_FILE"' EXIT

if ! docker info >/dev/null 2>&1; then
    echo "❌ Error: Docker is not running or not accessible. Start Docker and try again."
    exit 1
fi

BRAINSTORM_MODEL="claude-haiku-4-5"
EVAL_MODEL="claude-sonnet-4-6"

mkdir -p docs docs/decisions
TIMESTAMP=$(date '+%Y-%m-%d_%H%M')
FEATURE_SLUG=$(printf '%s' "$ORIGINAL_TASK_PROMPT" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -cs 'a-z0-9' '-' \
    | sed 's/-\{2,\}/-/g; s/^-//; s/-$//' \
    | cut -c1-40 \
    | sed 's/-$//')
DECISION_FILE="docs/decisions/${TIMESTAMP}_${FEATURE_SLUG}_architect.md"
decision_log_init "$DECISION_FILE" "architect" "$ORIGINAL_TASK_PROMPT" "$CHOSEN_MODEL"

echo "🏛️  claude-architect pipeline"
echo "   Task:     $ORIGINAL_TASK_PROMPT"
echo "   Impl:     $CHOSEN_MODEL"
echo "   Gemini:   $([ "$GEMINI_ENABLED" = true ] && echo "enabled" || echo "disabled")"
echo "   Log:      $DECISION_FILE"
echo ""

# CLAUDE.md bootstrap: generate before Phase 1 if absent so all phases benefit.
if [ ! -f "CLAUDE.md" ]; then
    echo "⚠️  CLAUDE.md not found. Generating before pipeline..."
    run_headless_phase "${BASE_CONTAINER}-setup" "$BRAINSTORM_MODEL" "5" \
        "Analyze this codebase and create a CLAUDE.md file in the root directory. Follow standard Claude Code conventions: project purpose, exact build/test/lint commands, file layout, and engineering/style guidelines. Do not perform any other tasks." || true
    [ -f "CLAUDE.md" ] && echo "✅ CLAUDE.md created." || echo "⚠️  CLAUDE.md creation failed. Continuing."
    echo ""
fi

# ==============================================================================
# PHASE 1: BRAINSTORM (haiku)
# Generates 3 distinct architectural approaches without writing executable code.
# ==============================================================================
echo "🧠 PHASE 1: Brainstorming architectural approaches (${BRAINSTORM_MODEL})..."

PHASE1_PROMPT="Analyze this workspace thoroughly. For the following task: '${ORIGINAL_TASK_PROMPT}', generate exactly 3 DISTINCT architectural approaches. Each must represent a genuinely different design philosophy — not variations on the same idea.

Save your analysis to docs/architecture_candidates.md with this structure for each option:
## Option [A/B/C]: [Name]
**Summary:** one-line description
**Key design decisions:** bullet list
**Trade-offs:** extensibility, complexity, test surface, blast radius
**Risks or prerequisites:** any concerns

Do NOT write executable implementation code. Architectural descriptions and trade-off analysis only."

PHASE1_CODE=0
run_headless_phase "${BASE_CONTAINER}-phase1" "$BRAINSTORM_MODEL" "10" "$PHASE1_PROMPT" \
    || PHASE1_CODE=$?

if [ $PHASE1_CODE -ne 0 ] || [ ! -f "docs/architecture_candidates.md" ]; then
    echo "⚠️  Phase 1 attempt 1 failed (exit ${PHASE1_CODE}). Retrying..."
    PHASE1_CODE=0
    run_headless_phase "${BASE_CONTAINER}-phase1r" "$BRAINSTORM_MODEL" "10" "$PHASE1_PROMPT" \
        || PHASE1_CODE=$?
fi

if [ -f "docs/architecture_candidates.md" ]; then
    echo "✅ Phase 1 complete: docs/architecture_candidates.md"
    decision_log_section "$DECISION_FILE" "Phase 1: Architectural Candidates" "docs/architecture_candidates.md"
else
    echo "⚠️  Phase 1 produced no output. Phase 2 will brainstorm and select independently."
    decision_log_note "$DECISION_FILE" "Phase 1: Architectural Candidates" "Phase 1 produced no output — Phase 2 brainstormed and selected independently."
fi
echo ""

# ==============================================================================
# GEMINI ARCHITECTURAL CRITIQUE (optional, between phases 1 and 2)
# An independent Principal Engineer critique of each candidate — feeds into
# Phase 2's selection decision without anchoring it to Claude's own preferences.
# ==============================================================================
if [ "$GEMINI_ENABLED" = true ] && [ -f "docs/architecture_candidates.md" ]; then
    echo "🔍 Gemini architectural critique..."
    build_gemini_architectural_prompt "$ORIGINAL_TASK_PROMPT" "docs/architecture_candidates.md" > "$GEMINI_PROMPT_FILE"
    if call_gemini "$GEMINI_PROMPT_FILE" "docs/gemini_architectural_audit.md"; then
        echo "✅ Gemini critique saved to docs/gemini_architectural_audit.md"
        decision_log_section "$DECISION_FILE" "Gemini Architectural Critique" "docs/gemini_architectural_audit.md"
    else
        echo "⚠️  Gemini critique failed — Phase 2 will proceed without it."
        rm -f "docs/gemini_architectural_audit.md"
        decision_log_note "$DECISION_FILE" "Gemini Architectural Critique" "Gemini critique failed — Phase 2 proceeded without it."
    fi
    echo ""
fi

# ==============================================================================
# PHASE 2: EVALUATE (sonnet)
# Selects the best approach and writes a detailed implementation spec.
# ==============================================================================
echo "⚖️  PHASE 2: Evaluating and selecting architecture (${EVAL_MODEL})..."

PHASE2_PROMPT="You are a senior software architect performing a design review."
if [ -f "docs/architecture_candidates.md" ]; then
    PHASE2_PROMPT+=" Read docs/architecture_candidates.md (three architectural candidates)."
else
    PHASE2_PROMPT+=" No Phase 1 candidates were produced. First generate 3 distinct approaches for: '${ORIGINAL_TASK_PROMPT}', then evaluate them yourself."
fi
if [ -f "docs/gemini_architectural_audit.md" ]; then
    PHASE2_PROMPT+=" Also read docs/gemini_architectural_audit.md (independent adversarial critique of each candidate from a Principal Engineer)."
fi
PHASE2_PROMPT+="

Select the single most robust and maintainable approach. Write a definitive implementation spec to docs/approved_architecture.md. Include:
- Which option was selected and why
- File and directory changes required
- Key data structures or interfaces to define
- API contracts or function signatures
- The exact ordered sequence of implementation steps

Be specific enough that an engineer can implement without clarifying questions. Do NOT write executable code.

Before making your selection, also review docs/decisions/ for past decision logs from previous pipeline runs on this codebase — they show which approaches have already been tried and their outcomes. Use them only as historical context to avoid repeating past mistakes; do not let them anchor your analysis of the current candidates."

PHASE2_CODE=0
run_headless_phase "${BASE_CONTAINER}-phase2" "$EVAL_MODEL" "10" "$PHASE2_PROMPT" \
    || PHASE2_CODE=$?

if [ $PHASE2_CODE -ne 0 ] || [ ! -f "docs/approved_architecture.md" ]; then
    echo "⚠️  Phase 2 attempt 1 failed (exit ${PHASE2_CODE}). Retrying..."
    PHASE2_CODE=0
    run_headless_phase "${BASE_CONTAINER}-phase2r" "$EVAL_MODEL" "10" "$PHASE2_PROMPT" \
        || PHASE2_CODE=$?
fi

if [ ! -f "docs/approved_architecture.md" ]; then
    echo "❌ Phase 2 failed to produce an implementation spec after 2 attempts."
    echo "   Check docs/architecture_candidates.md for Phase 1 output."
    decision_log_outcome "$DECISION_FILE" "failed" "Phase 2 failed to produce an implementation spec after 2 attempts."
    exit 1
fi
decision_log_section "$DECISION_FILE" "Phase 2: Selected Architecture" "docs/approved_architecture.md"
echo "✅ Phase 2 complete: docs/approved_architecture.md"
echo ""

# ==============================================================================
# PHASE 3: IMPLEMENT
# Delegates to launch-scripted.sh for the full retry/recovery/rate-limit loop.
# Claude reads the approved spec and implements it step by step.
# ==============================================================================
echo "🏗️  PHASE 3: Implementing approved architecture (${CHOSEN_MODEL})..."
IMPL_PROMPT="Read docs/approved_architecture.md. Implement the exact spec found there, following the implementation steps in order. Do not deviate from the approved design. For context on why this approach was chosen over the alternatives, see ${DECISION_FILE}. After implementation, run any available tests to verify correctness."
IMPL_ARGS=("$IMPL_PROMPT" "$CHOSEN_MODEL")
[ "$GEMINI_ENABLED" = "false" ] && IMPL_ARGS+=("--no-gemini")

"${LAUNCH_SCRIPTED_OVERRIDE:-$(dirname "$0")/launch-scripted.sh}" "${IMPL_ARGS[@]}"
PHASE3_EXIT=$?
if [ $PHASE3_EXIT -eq 0 ]; then
    decision_log_outcome "$DECISION_FILE" "success" "Phase 3 implementation completed successfully."
else
    decision_log_outcome "$DECISION_FILE" "failed" "Phase 3 implementation failed (exit ${PHASE3_EXIT})."
fi
exit $PHASE3_EXIT
