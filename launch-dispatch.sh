#!/bin/bash
set -eo pipefail
# Note: -u (nounset) intentionally omitted — see launch-scripted.sh.

[ -f "$(dirname "${BASH_SOURCE[0]}")/.env.local" ] && source "$(dirname "${BASH_SOURCE[0]}")/.env.local"

# ==============================================================================
# launch-dispatch.sh — Intelligent multi-pipeline task dispatcher
#
# Analyzes a task description and routes it to the appropriate pipeline(s) in
# sequence. Gemini (or a keyword heuristic fallback) decomposes compound tasks
# into ordered steps; each step runs the matching pipeline script end-to-end.
#
#   Pipelines available:
#     architect — brainstorm → evaluate → implement a new feature
#     qa        — generate tests → adversarial audit → remediate gaps
#     refactor  — diagnose → plan → fix a bug or restructure code
#     scripted  — general-purpose task (fallback)
#
# USAGE:
#    launch-dispatch.sh "task description" [model] [--no-gemini] [--loop-tests[=N]]
#    launch-dispatch.sh @tasks.md [model] [--loop-tests[=N]]
#    launch-dispatch.sh "@tasks.md:phase 3" [model]
#
# ARGUMENTS:
#    "task"           What to do. Plain text or an @file reference.
#    @file            Read the full task from a file (e.g. @tasks.md).
#    @file:section    Extract a named section from the file by heading.
#    model            (Optional) Claude model for implementation phases.
#                     Default: claude-sonnet-4-6.
#    --no-gemini      Disable Gemini for planning AND all sub-pipelines.
#    --loop-tests     After the plan, loop qa → refactor until tests pass.
#    --loop-tests=N   As above, up to N iterations (default: 3).
#
# EXAMPLES:
#    launch-dispatch.sh "add a plugin system, then write tests for it"
#    launch-dispatch.sh @tasks.md claude-opus-4-8
#    launch-dispatch.sh "@tasks.md:phase 4" --loop-tests=5
#    launch-dispatch.sh "fix the auth bug" --no-gemini
#
# SETUP:
#    Run claude-box-auth once before first use.
#    Export GEMINI_API_KEY to enable smart routing and sub-pipeline critiques.
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    sed -n '/^# ====/,/^# ====/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
    exit 0
fi

source "$SCRIPT_DIR/lib/launch-lib.sh"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
RAW_TASK=""
CHOSEN_MODEL="claude-sonnet-4-6"
GEMINI_ENABLED=true
LOOP_TESTS=0

for arg in "$@"; do
    case "$arg" in
        --no-gemini)
            GEMINI_ENABLED=false ;;
        --loop-tests=*)
            LOOP_TESTS="${arg#*=}" ;;
        --loop-tests)
            LOOP_TESTS=3 ;;
        --help|-h) ;;
        *)
            if [ -z "$RAW_TASK" ]; then
                RAW_TASK="$arg"
            elif [[ "$arg" == *"haiku"* || "$arg" == *"sonnet"* || "$arg" == *"opus"* || "$arg" == *"fable"* ]]; then
                CHOSEN_MODEL="$arg"
            fi
            ;;
    esac
done

[ -z "${GEMINI_API_KEY:-}" ] && GEMINI_ENABLED=false

if [ -z "$RAW_TASK" ]; then
    echo "❌ Error: You must provide a task description."
    echo "   Usage: claude-dispatch \"task\" [model] [--no-gemini] [--loop-tests[=N]]"
    echo "          claude-dispatch @tasks.md [model]"
    echo "          claude-dispatch \"@tasks.md:phase 3\" [model]"
    exit 1
fi

# ---------------------------------------------------------------------------
# Resolve @file and @file:section references
# ---------------------------------------------------------------------------
TASK=""
if [[ "$RAW_TASK" == @* ]]; then
    FILE_REF="${RAW_TASK:1}"   # strip leading @
    SECTION=""
    if [[ "$FILE_REF" == *:* ]]; then
        SECTION="${FILE_REF#*:}"
        FILE_REF="${FILE_REF%%:*}"
    fi

    if [ ! -f "$FILE_REF" ]; then
        echo "❌ Error: File not found: $FILE_REF"
        exit 1
    fi

    if [ -n "$SECTION" ]; then
        # Extract the named section by heading (case-insensitive substring match).
        TASK=$(python3 - "$FILE_REF" "$SECTION" <<'PYEOF'
import sys, re

filepath = sys.argv[1]
section  = sys.argv[2].lower()

with open(filepath) as fh:
    lines = fh.read().split('\n')

start = None
start_level = 0
for i, line in enumerate(lines):
    m = re.match(r'^(#{1,6})\s+(.*)', line)
    if m and section in m.group(2).lower():
        start, start_level = i, len(m.group(1))
        break

if start is None:
    for i, line in enumerate(lines):
        if section in line.lower():
            start = i
            break

if start is None:
    print('\n'.join(lines))
    sys.exit(0)

end = len(lines)
for i in range(start + 1, len(lines)):
    m = re.match(r'^(#{1,6})\s+', lines[i])
    if m and (start_level == 0 or len(m.group(1)) <= start_level):
        end = i
        break

print('\n'.join(lines[start:end]))
PYEOF
        )
        echo "📄 Loaded section \"$SECTION\" from $FILE_REF"
    else
        TASK=$(cat "$FILE_REF")
        echo "📄 Loaded task file: $FILE_REF"
    fi
else
    TASK="$RAW_TASK"
fi

if [ -z "$TASK" ]; then
    echo "❌ Error: Task is empty (file or section may be empty)."
    exit 1
fi

# ---------------------------------------------------------------------------
# Plan: use Gemini to decompose into pipeline steps, or fall back to heuristic
# ---------------------------------------------------------------------------
GEMINI_FLAG=""
[ "$GEMINI_ENABLED" = "false" ] && GEMINI_FLAG="--no-gemini"

PLAN=""
PLAN_SOURCE=""
PLAN_PROMPT_FILE=""
PLAN_OUTPUT_FILE=""
trap 'rm -f "$PLAN_PROMPT_FILE" "$PLAN_OUTPUT_FILE"' EXIT

if [ "$GEMINI_ENABLED" = "true" ]; then
    PLAN_PROMPT_FILE=$(mktemp)
    PLAN_OUTPUT_FILE=$(mktemp)

    build_gemini_dispatch_prompt "$TASK" > "$PLAN_PROMPT_FILE"

    echo "🧭 Planning pipeline sequence (Gemini)..."
    if call_gemini "$PLAN_PROMPT_FILE" "$PLAN_OUTPUT_FILE" 2>/dev/null; then
        PLAN=$(cat "$PLAN_OUTPUT_FILE")
        PLAN_SOURCE="gemini"
    else
        echo "⚠️  Gemini planning failed — falling back to keyword heuristic."
    fi
fi

if [ -z "$PLAN" ]; then
    TASK_LOWER=$(printf '%s' "$TASK" | tr '[:upper:]' '[:lower:]')
    PIPELINE="scripted"
    if [[ "$TASK_LOWER" =~ (^|[^a-z])(test|qa|coverage|spec|assert|verify)([^a-z]|$) ]]; then
        PIPELINE="qa"
    elif [[ "$TASK_LOWER" =~ (^|[^a-z])(fix|bug|refactor|repair|race|leak|debug|broken|regress)([^a-z]|$) ]]; then
        PIPELINE="refactor"
    elif [[ "$TASK_LOWER" =~ (^|[^a-z])(add|implement|build|create|design|feature|new)([^a-z]|$) ]]; then
        PIPELINE="architect"
    fi
    PLAN="${PIPELINE}: ${TASK}"
    PLAN_SOURCE="heuristic ($PIPELINE)"
fi

# ---------------------------------------------------------------------------
# Parse and validate plan output into STEPS / STEP_PROMPTS arrays
# ---------------------------------------------------------------------------
STEPS=()
STEP_PROMPTS=()

while IFS= read -r line; do
    [ -z "$line" ] && continue
    [[ "$line" == \#* ]] && continue
    pipeline="${line%%: *}"
    step_prompt="${line#*: }"
    pipeline=$(printf '%s' "$pipeline" | tr -d ' \t' | tr '[:upper:]' '[:lower:]')
    case "$pipeline" in
        architect|qa|refactor|scripted) ;;
        *) continue ;;
    esac
    [ "${#STEPS[@]}" -ge 8 ] && break
    STEPS+=("$pipeline")
    STEP_PROMPTS+=("$step_prompt")
done <<< "$PLAN"

if [ "${#STEPS[@]}" -eq 0 ]; then
    echo "❌ Error: Planning produced no valid steps. Raw output:"
    printf '%s\n' "$PLAN"
    exit 1
fi

# ---------------------------------------------------------------------------
# Print execution plan
# ---------------------------------------------------------------------------
echo ""
echo "🗺️  claude-dispatch"
echo "   Source: $PLAN_SOURCE"
echo "   Model:  $CHOSEN_MODEL"
echo "   Gemini: $([ "$GEMINI_ENABLED" = "true" ] && echo "enabled" || echo "disabled")"
[ "$LOOP_TESTS" -gt 0 ] && echo "   Tests:  loop up to ${LOOP_TESTS}x after plan"
echo ""
echo "   Execution plan (${#STEPS[@]} step(s)):"
for i in "${!STEPS[@]}"; do
    printf "   %d. [%s] %s\n" "$(( i + 1 ))" "${STEPS[$i]}" "${STEP_PROMPTS[$i]}"
done
echo ""

# ---------------------------------------------------------------------------
# Execute each step in sequence
# ---------------------------------------------------------------------------
TOTAL_STEPS="${#STEPS[@]}"
STEP_NUM=0
DISPATCH_EXIT=0

for i in "${!STEPS[@]}"; do
    STEP_NUM=$(( i + 1 ))
    pipeline="${STEPS[$i]}"
    step_prompt="${STEP_PROMPTS[$i]}"

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Step $STEP_NUM/$TOTAL_STEPS  [$pipeline]"
    echo "  $step_prompt"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    STEP_ARGS=("$step_prompt" "$CHOSEN_MODEL")
    [ -n "$GEMINI_FLAG" ] && STEP_ARGS+=("$GEMINI_FLAG")

    STEP_EXIT=0
    case "$pipeline" in
        architect) bash "$SCRIPT_DIR/launch-architect.sh" "${STEP_ARGS[@]}" || STEP_EXIT=$? ;;
        qa)        bash "$SCRIPT_DIR/launch-qa.sh"        "${STEP_ARGS[@]}" || STEP_EXIT=$? ;;
        refactor)  bash "$SCRIPT_DIR/launch-refactor.sh"  "${STEP_ARGS[@]}" || STEP_EXIT=$? ;;
        scripted)  bash "$SCRIPT_DIR/launch-scripted.sh"  "${STEP_ARGS[@]}" || STEP_EXIT=$? ;;
    esac

    if [ "$STEP_EXIT" -ne 0 ]; then
        echo ""
        echo "❌ Step $STEP_NUM [$pipeline] failed (exit $STEP_EXIT). Stopping dispatch."
        DISPATCH_EXIT=$STEP_EXIT
        break
    fi
    echo ""
    echo "✅ Step $STEP_NUM/$TOTAL_STEPS complete."
    echo ""
done

# ---------------------------------------------------------------------------
# Optional test loop: qa → refactor → qa until tests pass or limit reached
# ---------------------------------------------------------------------------
LOOP_FAILED=false

if [ "$DISPATCH_EXIT" -eq 0 ] && [ "$LOOP_TESTS" -gt 0 ]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Test loop (max ${LOOP_TESTS} iteration(s))"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    TEST_PROMPT="Run the full project test suite. Fix any failures. All tests must pass before you stop."
    FIX_PROMPT="The test suite is still failing. Diagnose the remaining failures and fix them without breaking passing tests."

    for iter in $(seq 1 "$LOOP_TESTS"); do
        echo "🔄 Test loop $iter/$LOOP_TESTS — running qa..."
        QA_ARGS=("$TEST_PROMPT" "$CHOSEN_MODEL")
        [ -n "$GEMINI_FLAG" ] && QA_ARGS+=("$GEMINI_FLAG")
        QA_EXIT=0
        bash "$SCRIPT_DIR/launch-qa.sh" "${QA_ARGS[@]}" || QA_EXIT=$?

        if [ "$QA_EXIT" -eq 0 ]; then
            echo ""
            echo "✅ All tests passing after $iter iteration(s)."
            break
        fi

        if [ "$iter" -lt "$LOOP_TESTS" ]; then
            echo ""
            echo "⚠️  Tests still failing — running refactor..."
            RF_ARGS=("$FIX_PROMPT" "$CHOSEN_MODEL")
            [ -n "$GEMINI_FLAG" ] && RF_ARGS+=("$GEMINI_FLAG")
            bash "$SCRIPT_DIR/launch-refactor.sh" "${RF_ARGS[@]}" || true
            echo ""
        else
            echo ""
            echo "❌ Tests still failing after $LOOP_TESTS iteration(s)."
            DISPATCH_EXIT=1
            LOOP_FAILED=true
        fi
    done
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$DISPATCH_EXIT" -eq 0 ]; then
    echo "  ✅ Dispatch complete — all ${TOTAL_STEPS} step(s) succeeded."
elif [ "$LOOP_FAILED" = "true" ]; then
    echo "  ❌ Plan completed but tests still failing after ${LOOP_TESTS} loop iteration(s)."
else
    echo "  ❌ Dispatch stopped at step $STEP_NUM/$TOTAL_STEPS."
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

exit $DISPATCH_EXIT
