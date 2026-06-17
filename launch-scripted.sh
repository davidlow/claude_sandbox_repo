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
# SETUP:
#    Run claude-box-auth once before first use to save your Claude Pro login.
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTH_DIR="$SCRIPT_DIR/claude-auth"

if [ ! -d "$AUTH_DIR" ] || [ -z "$(ls -A "$AUTH_DIR" 2>/dev/null)" ]; then
    echo "❌ Error: No Claude credentials found in $AUTH_DIR"
    echo "   Run 'claude-box-auth' first to log in with your Claude Pro account."
    exit 1
fi

if [ -z "${1:-}" ]; then
    echo "❌ Error: You must provide an instruction string."
    echo "Usage: claude-yolo \"your task\" [optional_model]"
    echo "       claude-yolo --help"
    exit 1
fi

ORIGINAL_TASK_PROMPT="$1"   # Never mutated — used when rebuilding retry prompts
TASK_PROMPT="$1"
CHOSEN_MODEL="${2:-claude-sonnet-4-6}" # Baseline default

# ==============================================================================
# --- DYNAMIC SAFE-FENCE ENGINE (High-Capability / Cost-Protected) ---
# Balances the deep context needs of elite models with aggressive host timeouts.
#
# MAX_CONTEXT_TOKENS  — The maximum memory cap before an auto-compaction trigger.
#                       Scales UP with model tier: bigger model = bigger context.
# TARGET_INPUT_TOKENS — Soft target for tokens sent per API call (~50% of max).
# MAX_THINKING_TOKENS — Reasoning token allocation. 0 = model doesn't support it.
# MAX_MINUTES         — Hard circuit breaker. Tighter on expensive models.
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
SESSION_STARTED=false   # Flips to true after our first attempt creates a session

# Sanitizes paths, transforms spaces/symbols to dashes, forces lower-case
# for Docker container naming conformity.
SANITIZED_DIR=$(basename "$(pwd)" | tr -cs '[:alnum:]-' '-' | tr '[:upper:]' '[:lower:]')
CONTAINER_NAME="claude-auto-${SANITIZED_DIR:-sandbox}"

# Preflight: fail fast with a clear message rather than a Docker internal error.
if ! docker info >/dev/null 2>&1; then
    echo "❌ Error: Docker is not running or not accessible. Start Docker and try again."
    exit 1
fi

# DOCKER_RUN_BASE: main task runs — -it allocates a PTY for Claude Code's TUI.
DOCKER_RUN_BASE=(
  docker run -it --rm
  --name "$CONTAINER_NAME"
  -v "$(pwd)":/workspace
  -v "$AUTH_DIR":/home/claudeuser/.claude
  -e DISABLE_AUTO_COMPACT=0
  -e CLAUDE_CODE_MAX_CONTEXT_TOKENS="$MAX_CONTEXT_TOKENS"
  -e API_TARGET_INPUT_TOKENS="$TARGET_INPUT_TOKENS"
  -e MAX_THINKING_TOKENS="$MAX_THINKING_TOKENS"
  claude-sandbox
)

# DOCKER_RECOVERY_BASE: recovery passes — no -t (no PTY) since these are automated
# intermediate steps, not user-interactive sessions. Using -it here breaks when
# called from non-TTY contexts and sends garbled output to the handoff prompt.
DOCKER_RECOVERY_BASE=(
  docker run -i --rm
  --name "${CONTAINER_NAME}-recovery"
  -v "$(pwd)":/workspace
  -v "$AUTH_DIR":/home/claudeuser/.claude
  -e DISABLE_AUTO_COMPACT=0
  -e CLAUDE_CODE_MAX_CONTEXT_TOKENS="$MAX_CONTEXT_TOKENS"
  -e API_TARGET_INPUT_TOKENS="$TARGET_INPUT_TOKENS"
  -e MAX_THINKING_TOKENS="$MAX_THINKING_TOKENS"
  claude-sandbox
)

while [ $ATTEMPT -le $MAX_RETRIES ]; do
    echo "🚀 [Attempt $ATTEMPT/$MAX_RETRIES] Launching $CHOSEN_MODEL..."
    echo "⏳ Context: ${MAX_CONTEXT_TOKENS} | Thinking: ${MAX_THINKING_TOKENS} | Timeout: ${MAX_MINUTES}m"

    set +e
    if [ "$SESSION_STARTED" = true ] && [ -d ".claude" ]; then
        # Our own previous attempt created a session — resume from it.
        # We check SESSION_STARTED to avoid accidentally picking up a .claude/
        # directory from a completely different prior task in the same directory.
        echo "📥 Resuming from existing session..."
        timeout "${MAX_MINUTES}m" "${DOCKER_RUN_BASE[@]}" claude --continue \
            --dangerously-skip-permissions --model "$CHOSEN_MODEL" -p "$TASK_PROMPT"
    else
        # Fresh start: first attempt, or after Strategy B+C wiped .claude/.
        timeout "${MAX_MINUTES}m" "${DOCKER_RUN_BASE[@]}" claude \
            --dangerously-skip-permissions --model "$CHOSEN_MODEL" -p "$TASK_PROMPT"
    fi
    EXIT_CODE=$?
    SESSION_STARTED=true   # A session now exists on disk (even if the run failed)
    set -e

    if [ $EXIT_CODE -eq 0 ]; then
        echo "✅ Task completed successfully on attempt $ATTEMPT."
        rm -f ".task_handoff.md"   # Clean up any checkpoint from a prior failed attempt
        SUCCESS=true
        break
    elif [ $EXIT_CODE -eq 124 ]; then
        echo "⚠️  [TIMEOUT] Attempt $ATTEMPT exceeded the ${MAX_MINUTES}m limit."
    else
        echo "⚠️  [FAILURE] Attempt $ATTEMPT exited with code $EXIT_CODE."
    fi

    # ===========================================================================
    # RECOVERY PHASE — Three-strategy context management, in priority order.
    # Goal: next attempt runs on condensed context, not the full failed history.
    #
    # Strategy A (primary): Pipe /compact via stdin (no TTY) to invoke Claude
    #   Code's built-in slash command. Verified by measuring .claude/ size before
    #   and after — exit 0 alone is insufficient, the file must actually shrink.
    #
    # Strategy B+C (combined fallback): Use --continue to ask Claude to write a
    #   .task_handoff.md checkpoint while it can still see its full history, then
    #   wipe .claude/ entirely. The handoff file survives in the workspace volume.
    #   Next attempt starts fresh but gets the checkpoint injected into the prompt.
    #   This avoids dragging a bloated failed context into the next run.
    # ===========================================================================
    if [ $ATTEMPT -lt $MAX_RETRIES ]; then
        docker kill "$CONTAINER_NAME" 2>/dev/null || true
        sleep 2

        echo "🧹 [RECOVERY] Attempting context compaction (Strategy A)..."

        # Snapshot .claude/ size before the compaction attempt
        BEFORE_SIZE=0
        [ -d ".claude" ] && BEFORE_SIZE=$(du -sk ".claude" 2>/dev/null | cut -f1 || echo "0")

        # Strategy A: /compact is a Claude Code slash command that summarises the
        # conversation history in-place and rewrites .claude/ on the shared volume.
        # Without -t (no TTY), the CLI reads stdin directly; piping the command in
        # triggers the same compaction path as typing /compact interactively.
        # DOCKER_RECOVERY_BASE is used here (not DOCKER_RUN_BASE) since these
        # are automated passes with no user PTY attached.
        set +e
        printf '/compact\n' | timeout "3m" "${DOCKER_RECOVERY_BASE[@]}" \
            claude --continue --dangerously-skip-permissions --model "$CHOSEN_MODEL"
        COMPACT_CODE=$?
        set -e

        # Verify compaction actually shrank the session — exit 0 alone isn't enough.
        AFTER_SIZE=0
        [ -d ".claude" ] && AFTER_SIZE=$(du -sk ".claude" 2>/dev/null | cut -f1 || echo "0")

        if [ $COMPACT_CODE -eq 0 ] && [ "${AFTER_SIZE}" -lt "${BEFORE_SIZE}" ]; then
            echo "✅ Strategy A: session compacted ${BEFORE_SIZE}K → ${AFTER_SIZE}K."
            echo "   Next attempt resumes via --continue from the condensed session."
        else
            echo "⚠️  Strategy A ineffective (${BEFORE_SIZE}K → ${AFTER_SIZE}K, exit ${COMPACT_CODE})."
            echo "   Running Strategy B+C: handoff capture then context reset..."

            # Strategy B: Run one final --continue pass asking Claude to write a
            # checkpoint file. The workspace is a mounted volume so the file
            # survives container teardown even after we wipe .claude/ in step C.
            # Uses DOCKER_RECOVERY_BASE (no -t) since this is an automated pass.
            set +e
            timeout "2m" "${DOCKER_RECOVERY_BASE[@]}" claude --continue \
                --dangerously-skip-permissions --model "$CHOSEN_MODEL" \
                -p "Session interrupted. Do NOT continue the main task. Write .task_handoff.md to the workspace root with exactly: (1) bullet list of fully completed steps, (2) what was actively in-progress when interrupted, (3) any files created or modified, (4) the precise next steps needed to finish. Be concise. Stop immediately after writing."
            HANDOFF_CODE=$?
            set -e

            # Strategy C: Wipe the bloated failed session. Carrying a full failed
            # history into the next attempt wastes tokens and biases reasoning.
            # The handoff file is the only context we want to preserve.
            echo "🗑️  Resetting session context (handoff file preserved in workspace)..."
            rm -rf .claude/
            SESSION_STARTED=false   # Next iteration must start fresh, not --continue

            # Inject the handoff into the next attempt's task prompt.
            # Always wrap ORIGINAL_TASK_PROMPT (not the mutated TASK_PROMPT) so
            # repeated B+C cycles don't nest "Context from previous session:" blocks.
            if [ $HANDOFF_CODE -eq 0 ] && [ -f ".task_handoff.md" ]; then
                HANDOFF_CONTEXT=$(cat ".task_handoff.md")
                TASK_PROMPT="Context from previous session:
${HANDOFF_CONTEXT}

Continue the original task: ${ORIGINAL_TASK_PROMPT}"
                echo "✅ Strategy B+C: handoff captured, session wiped, context injected into next prompt."
            else
                echo "⚠️  Handoff write failed (exit ${HANDOFF_CODE}). Starting clean from original task."
                TASK_PROMPT="$ORIGINAL_TASK_PROMPT"
            fi
        fi

        sleep 3
    fi

    ATTEMPT=$((ATTEMPT + 1))
done

if [ "$SUCCESS" = false ]; then
    echo "❌ [FATAL ERROR] Task execution failed to resolve after $MAX_RETRIES allocation attempts."
    exit 1
fi
