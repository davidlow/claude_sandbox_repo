#!/bin/bash
set -euo pipefail # Hardens script execution against unhandled pipe failures

# ==============================================================================
# claude-yolo — Autonomous Claude Code Sandbox Runner
#
# Launches Claude Code in a sandboxed Docker container in non-interactive
# (scripted) mode. Claude executes the given task autonomously, bypassing
# all permission prompts, and the container is destroyed when it exits.
#
# USAGE:
#    claude-yolo "your task description" [model]
#
# ARGUMENTS:
#    "your task"   The instruction string for Claude to execute autonomously.
#    model         (Optional) Claude model to use. Defaults to claude-sonnet-4-6.
#                  Supported tiers: haiku, sonnet (default), opus, fable
#
# EXAMPLES:
#    claude-yolo "run the test suite and fix any failures"
#    claude-yolo "refactor the auth module for readability" claude-opus-4-8
#    claude-yolo "add input validation to all API endpoints" claude-haiku-4-5
#
# ENVIRONMENT:
#    ANTHROPIC_API_KEY   Required. Your Anthropic API key.
#
# SAFETY:
#    - Claude has full read/write access to your current directory.
#    - Commit or stash your changes before running to protect your work.
#    - Context and time limits are enforced per model tier to control costs.
# ==============================================================================

# Dynamic help flag parsing that strips the header comments and presents them cleanly
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    sed -n '/^# ====/,/^# ====/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
    exit 0
fi

if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    echo "❌ Error: ANTHROPIC_API_KEY environment variable is not set."
    exit 1
fi

if [ -z "${1:-}" ]; then
    echo "❌ Error: You must provide an instruction string."
    echo "Usage: claude-yolo \"your task\" [optional_model]"
    echo "       claude-yolo --help"
    exit 1
fi

TASK_PROMPT="$1"
CHOSEN_MODEL="${2:-claude-sonnet-4-6}" # Baseline default

# ==============================================================================
# --- DYNAMIC SAFE-FENCE ENGINE (High-Capability / Cost-Protected) ---
# Balances the deep context needs of elite models with aggressive host timeouts.
#
# MAX_CONTEXT_TOKENS  — The maximum memory cap before an auto-compaction trigger.
# TARGET_INPUT_TOKENS — Target size for compressed context history.
# MAX_THINKING_TOKENS — Reasoning token allocation for models with thinking models.
# MAX_MINUTES         — Ultimate host circuit breaker to stop runaway financial loops.
# ==============================================================================
# Defaults (Sonnet Tier Baseline Setup)
MAX_MINUTES="10"
MAX_RETRIES=3
MAX_CONTEXT_TOKENS=80000
TARGET_INPUT_TOKENS=40000
MAX_THINKING_TOKENS=10000

if [[ "$CHOSEN_MODEL" == *"haiku"* ]]; then
    # Haiku: Fast and incredibly economical. Smaller memory footprint, no thinking tokens.
    MAX_MINUTES="15" # Cheap enough to give it maximum leeway to loop and try alternatives
    MAX_CONTEXT_TOKENS=50000
    TARGET_INPUT_TOKENS=25000
    MAX_THINKING_TOKENS=0
    
elif [[ "$CHOSEN_MODEL" == *"opus"* ]]; then
    # Opus: Premium tier ($5/M). Give it full context capacity to solve massive architecture shifts,
    # but run it on a strict, brief timeout chain to mitigate cost spikes.
    MAX_MINUTES="5" 
    MAX_RETRIES=2
    MAX_CONTEXT_TOKENS=120000 
    TARGET_INPUT_TOKENS=60000
    MAX_THINKING_TOKENS=24000

elif [[ "$CHOSEN_MODEL" == *"fable"* ]]; then
    # Fable: Highest-tier computational model ($10/M). Needs ample room to cross-reference logs,
    # but relies on the tightest time threshold to cut execution long before token limits fill up.
    MAX_MINUTES="4"
    MAX_RETRIES=2
    MAX_CONTEXT_TOKENS=120000
    TARGET_INPUT_TOKENS=60000
    MAX_THINKING_TOKENS=0 # Fable manages its own adaptive reasoning internally
fi
# ==============================================================================

ATTEMPT=1
SUCCESS=false

# Claude's Fix: Sanitizes paths, transforms spaces/symbols to dashes, and forces lower-case
# for impeccable Docker container naming conformity.
SANITIZED_DIR=$(basename "$(pwd)" | tr -cs '[:alnum:]-' '-' | tr '[:upper:]' '[:lower:]')
CONTAINER_NAME="claude-auto-${SANITIZED_DIR:-sandbox}"

# Base Docker Command Blueprint (Fixed continuation backslashes)
DOCKER_RUN_BASE=(
  docker run -it --rm \
  --name "$CONTAINER_NAME" \
  -v "$(pwd)":/workspace \
  -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  -e DISABLE_AUTO_COMPACT=0 \
  -e CLAUDE_CODE_MAX_CONTEXT_TOKENS="$MAX_CONTEXT_TOKENS" \
  -e API_TARGET_INPUT_TOKENS="$TARGET_INPUT_TOKENS" \
  -e MAX_THINKING_TOKENS="$MAX_THINKING_TOKENS" \
  claude-sandbox
)

while [ $ATTEMPT -le $MAX_RETRIES ]; do
    echo "🚀 [Attempt $ATTEMPT/$MAX_RETRIES] Launching $CHOSEN_MODEL..."
    echo "⏳ Boundaries -> Context Cap: ${MAX_CONTEXT_TOKENS} | Thinking Cap: ${MAX_THINKING_TOKENS} | Hard Timeout: ${MAX_MINUTES}m"
    
    set +e
    if [ $ATTEMPT -eq 1 ]; then
        # Turn 1: Fresh run or standard resumption entry point
        "${DOCKER_RUN_BASE[@]}" claude --dangerously-skip-permissions --model "$CHOSEN_MODEL" -p "$TASK_PROMPT"
    else
        # Subsequent Turns: Continue seamlessly from the newly compacted/intervened context
        echo "📥 Resuming task execution from the newly streamlined context stream..."
        "${DOCKER_RUN_BASE[@]}" claude --continue --dangerously-skip-permissions --model "$CHOSEN_MODEL" -p "$TASK_PROMPT"
    fi
    EXIT_CODE=$?
    set -e

    if [ $EXIT_CODE -eq 0 ]; then
        echo "✅ Task completed successfully by Claude on Attempt $ATTEMPT."
        SUCCESS=true
        break
    elif [ $EXIT_CODE -eq 124 ]; then
        echo "⚠️  [TIMEOUT] Attempt $ATTEMPT hit the hard time threshold limit."
    else
        echo "⚠️  [FAILURE] Attempt $ATTEMPT broke with an exit status code: $EXIT_CODE"
    fi

    # RECOVERY PHASE: Intelligent Intercept instead of hard wiping
    if [ $ATTEMPT -lt $MAX_RETRIES ]; then
        echo "🩹 [INTERVENTION] Forcing context compression and error re-evaluation..."

        # Guard rail: Make sure the previous container instance is totally unlinked/killed
        docker kill "$CONTAINER_NAME" 2>/dev/null || true
        sleep 2

        # Invoke a dedicated sub-turn targeting the exact same session file history.
        # This pipes the built-in '/compact' tool command to compression engines, forcing
        # Claude to condense the bloat and re-architect its approach BEFORE re-running the prompt.
        set +e
        echo "🧹 Sending compaction orders and requesting strategy shift logs..."
        "${DOCKER_RUN_BASE[@]}" claude --continue --dangerously-skip-permissions --model "$CHOSEN_MODEL" -p "/compact The previous attempt failed or timed out. Compress historical logs, drop dead-ends, analyze why the task stalled, and prepare a corrected strategy map for the next run turn."
        INTERVENTION_CODE=$?
        set -e

        if [ $INTERVENTION_CODE -ne 0 ]; then
            echo "⚠️  [CRITICAL] Context intervention script failed. Falling back to clean slate protocol."
            rm -rf .claude/
        fi

        sleep 3
    fi

    ((ATTEMPT++))
done

if [ "$SUCCESS" = false ]; then
    echo "❌ [FATAL ERROR] Task execution failed to resolve after $MAX_RETRIES allocation attempts."
    exit 1
fi
