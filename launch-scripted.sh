#!/bin/bash
set -eo pipefail
# Note: -u (nounset) is intentionally omitted. Claude Code's bash shell
# integration installs hooks that reference $ZSH_VERSION, which is unset in
# bash. With -u active, those hooks error-out and break docker tee pipelines.

[ -f "$(dirname "${BASH_SOURCE[0]}")/.env.local" ] && source "$(dirname "${BASH_SOURCE[0]}")/.env.local"

# ==============================================================================
# claude-yolo — Context-Aware, Cross-Model Adaptive Autonomous Sandbox Runner
#
# Launches Claude Code in a sandboxed Docker container in non-interactive
# (scripted) mode. Claude executes the given task autonomously, bypassing
# all permission prompts, and the container is destroyed when it exits.
#
# CORE PIPELINES:
#   - Context Bootstrap:   Auto-generates CLAUDE.md if absent before the main task.
#   - Rate-Limit Adapting: Pauses and resumes automatically when token quotas reset.
#   - Strategy Recovery:   /compact (A), handoff+reset (B+C), then Gemini audit.
#   - Cross-Model Audit:   Sends failure context to Gemini 2.5 Flash for architect
#                          advice; injects the recommendation into the next attempt.
#
# USAGE:
#    claude-yolo "your task description" [model] [--no-gemini]
#
# ARGUMENTS:
#    "your task"   The instruction string for Claude to execute autonomously.
#    model         (Optional) Claude model to use. Defaults to claude-sonnet-4-6.
#                  Supported tiers: haiku, sonnet (default), opus, fable
#
# FLAGS:
#    --no-gemini   Disable Gemini cross-model audit on failure.
#                  Audit runs by default when GEMINI_API_KEY is set in the
#                  environment; this flag suppresses it even if the key exists.
#
# EXAMPLES:
#    claude-yolo "run the test suite and fix any failures"
#    claude-yolo "refactor the auth module for readability" claude-opus-4-8
#    claude-yolo "add input validation to all API endpoints" claude-haiku-4-5
#    claude-yolo "migrate the database schema" --no-gemini
#
# SETUP:
#    Run claude-box-auth once before first use to save your Claude Pro login.
#    Export GEMINI_API_KEY (from Google AI Studio) to enable cross-model audits.
#
# SAFETY:
#    - Claude has full read/write access to your current directory.
#    - Commit or stash your changes before running to protect your work.
#    - Context and time limits are enforced per model tier to control costs.
# ==============================================================================

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    sed -n '/^# ====/,/^# ====/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
    exit 0
fi

# Load pure helper functions (also sourced by the test suite).
source "$(dirname "$0")/lib/launch-lib.sh"

# ==============================================================================
# ARGUMENT PARSING
# parse_args extracts --no-gemini and sets GEMINI_ENABLED, POSITIONAL_ARGS,
# ORIGINAL_TASK_PROMPT, and CHOSEN_MODEL.
# ==============================================================================
parse_args "$@"

CREDS="$HOME/.claude/.credentials.json"
if [ ! -f "$CREDS" ]; then
    echo "❌ Error: No Claude credentials found at $CREDS"
    echo "   Log in with: claude auth login --claudeai"
    exit 1
fi

if [ -z "${ORIGINAL_TASK_PROMPT:-}" ]; then
    echo "❌ Error: You must provide an instruction string."
    echo "Usage: claude-yolo \"your task\" [optional_model] [--no-gemini]"
    echo "       claude-yolo --help"
    exit 1
fi

# Gemini audit requires an API key; silently disable if absent so the script
# works identically for users who haven't configured one.
[ -z "${GEMINI_API_KEY:-}" ] && GEMINI_ENABLED=false

# ==============================================================================
# DYNAMIC SAFE-FENCE ENGINE (High-Capability / Cost-Protected)
# parse_model_tier sets MAX_MINUTES, MAX_RETRIES, MAX_CONTEXT_TOKENS,
# TARGET_INPUT_TOKENS, and MAX_THINKING_TOKENS based on the chosen model tier.
# ==============================================================================
parse_model_tier "$CHOSEN_MODEL"

# ==============================================================================
# OAUTH TOKEN EXTRACTION
# ==============================================================================
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

# Sanitize current directory name for use as Docker container name suffix.
SANITIZED_DIR=$(basename "$(pwd)" | tr -cs '[:alnum:]-' '-' | tr '[:upper:]' '[:lower:]')
CONTAINER_NAME="claude-auto-${SANITIZED_DIR:-sandbox}-$$"

# Temp log captures each run's output so rate-limit messages can be parsed
# after the container exits. Cleaned up on script exit.
# .gemini_audit_input.txt is also temp. GEMINI_ADVICE.md is intentionally kept
# on disk after a final failure so the user can review Gemini's last advice.
TEMP_LOG="/tmp/claude_exec_${SANITIZED_DIR}_$$.log"
trap 'rm -f "$TEMP_LOG" .gemini_audit_input.txt' EXIT

if ! docker info >/dev/null 2>&1; then
    echo "❌ Error: Docker is not running or not accessible. Start Docker and try again."
    exit 1
fi

# DOCKER_RUN_BASE: main task runs — -it allocates a PTY for Claude Code's TUI.
DOCKER_RUN_BASE=(
  docker run -it --rm
  --name "$CONTAINER_NAME"
  -v "$(pwd)":/workspace
  -v "$HOME/.claude":/home/claudeuser/.claude
  -e CLAUDE_CODE_OAUTH_TOKEN="$OAUTH_TOKEN"
  -e CLAUDE_CODE_OAUTH_REFRESH_TOKEN="$OAUTH_REFRESH"
  -e DISABLE_AUTO_COMPACT=0
  -e CLAUDE_CODE_MAX_CONTEXT_TOKENS="$MAX_CONTEXT_TOKENS"
  -e API_TARGET_INPUT_TOKENS="$TARGET_INPUT_TOKENS"
  -e MAX_THINKING_TOKENS="$MAX_THINKING_TOKENS"
  claude-sandbox
)

# DOCKER_RECOVERY_BASE: headless passes — no -t since these are automated steps
# with no user PTY attached. Using -it here breaks non-TTY contexts and sends
# garbled output into handoff prompts.
DOCKER_RECOVERY_BASE=(
  docker run -i --rm
  --name "${CONTAINER_NAME}-recovery"
  -v "$(pwd)":/workspace
  -v "$HOME/.claude":/home/claudeuser/.claude
  -e CLAUDE_CODE_OAUTH_TOKEN="$OAUTH_TOKEN"
  -e CLAUDE_CODE_OAUTH_REFRESH_TOKEN="$OAUTH_REFRESH"
  -e DISABLE_AUTO_COMPACT=0
  -e CLAUDE_CODE_MAX_CONTEXT_TOKENS="$MAX_CONTEXT_TOKENS"
  -e API_TARGET_INPUT_TOKENS="$TARGET_INPUT_TOKENS"
  -e MAX_THINKING_TOKENS="$MAX_THINKING_TOKENS"
  claude-sandbox
)

# ==============================================================================
# HELPER FUNCTIONS
# (strip_ansi, wait_for_quota, build_prompt_with_advice are in lib/launch-lib.sh)
# ==============================================================================

# ==============================================================================
# GEMINI CROSS-MODEL AUDIT
#
# Sends failure context to Gemini for architectural advice using flash models
# (with automatic fallback through the model tier list in launch-lib.sh).
# Writes the recommendation to GEMINI_ADVICE.md and sets GEMINI_ADVICE_TEXT
# so the main loop can inject it into the next attempt's prompt.
#
# Disabled when:
#   - --no-gemini flag was passed
#   - GEMINI_API_KEY is not set in the environment
#
# GEMINI_ADVICE.md is intentionally NOT cleaned up on failure exit — it is left
# on disk for the user to review after a final failed run. It IS removed on
# successful task completion.
# ==============================================================================
GEMINI_ADVICE_TEXT=""

run_gemini_audit() {
    echo "🧠 [GEMINI AUDIT] Sending failure context for cross-model analysis..."

    # Build audit context: task objective + repo blueprint + diff + failure log.
    # Git diff is capped at 500 lines to stay within Gemini's input window.
    {
        echo "=== TASK OBJECTIVE ==="
        echo "$ORIGINAL_TASK_PROMPT"
        echo ""
        echo "=== CLAUDE.md ==="
        [ -f CLAUDE.md ] && cat CLAUDE.md || echo "(not present)"
        echo ""
        echo "=== GIT STATUS ==="
        if git rev-parse --git-dir >/dev/null 2>&1; then
            git diff HEAD --stat 2>/dev/null || true
            echo "---"
            git diff HEAD 2>/dev/null | head -500 || true
        else
            echo "(not a git repository)"
        fi
        echo ""
        echo "=== FAILURE OUTPUT (last 100 lines) ==="
        if [ -s "$TEMP_LOG" ]; then
            strip_ansi "$TEMP_LOG" | tail -100
        else
            echo "(no output captured)"
        fi
    } > .gemini_audit_input.txt

    # Prepend the cross-model audit framing to the raw context, then hand off
    # to call_gemini which handles model selection and fallback automatically.
    local audit_prompt_file
    audit_prompt_file=$(mktemp)
    {
        printf '%s\n\n' \
            "You are a senior software architect performing a cross-model code audit. Claude Code attempted a task and failed or timed out. Review the context below and provide:" \
            "1. ROOT CAUSE: Why did Claude likely fail or get stuck?" \
            "2. CORRECTIVE STRATEGY: Concrete steps the next attempt should take." \
            "3. PITFALLS: Specific mistakes to avoid on the retry." \
            "Be concise and directly actionable — your advice will be prepended to Claude's next attempt prompt."
        cat .gemini_audit_input.txt
    } > "$audit_prompt_file"
    rm -f .gemini_audit_input.txt

    if call_gemini "$audit_prompt_file" "GEMINI_ADVICE.md"; then
        GEMINI_ADVICE_TEXT=$(cat "GEMINI_ADVICE.md")
        echo "✅ Gemini audit complete. Recommendation saved to GEMINI_ADVICE.md"
        rm -f "$audit_prompt_file"
        return 0
    else
        echo "⚠️  Gemini audit returned no response — continuing without advice."
        GEMINI_ADVICE_TEXT=""
        rm -f "$audit_prompt_file"
        return 1
    fi
}

# ==============================================================================
# PRE-FLIGHT: CLAUDE.md BOOTSTRAP / REFRESH
# Ensures CLAUDE.md exists and reflects recent git changes before the main task
# and any Gemini audit. Failures are non-fatal — the main task proceeds with
# whatever context is available. .claude/ is wiped by run_headless_phase.
# ==============================================================================
ensure_claude_md_current "${CONTAINER_NAME}-setup"

# ==============================================================================
# MAIN RETRY LOOP
#
# BASE_TASK tracks the "content" of the prompt (original task, or handoff +
# original after a B+C reset). TASK_PROMPT = Gemini advice + BASE_TASK, rebuilt
# each recovery cycle. Keeping them separate prevents advice blocks from stacking
# across multiple Strategy A compaction retries.
# ==============================================================================
BASE_TASK="$ORIGINAL_TASK_PROMPT"
TASK_PROMPT="$BASE_TASK"
ATTEMPT=1
SUCCESS=false
SESSION_STARTED=false

while [ $ATTEMPT -le $MAX_RETRIES ]; do
    echo "🚀 [Attempt $ATTEMPT/$MAX_RETRIES] Launching $CHOSEN_MODEL..."
    echo "⏳ Context: ${MAX_CONTEXT_TOKENS} | Thinking: ${MAX_THINKING_TOKENS} | Timeout: ${MAX_MINUTES}m"
    if [ "$GEMINI_ENABLED" = true ]; then
        echo "   Gemini audit: enabled (GEMINI_API_KEY set)"
    else
        echo "   Gemini audit: disabled"
    fi

    set +e
    if [ "$SESSION_STARTED" = true ] && [ -d ".claude" ]; then
        # Our own previous attempt created a session — resume from it.
        # SESSION_STARTED guards against accidentally picking up a .claude/
        # directory left by a completely different prior task.
        echo "📥 Resuming from existing session..."
        timeout "${MAX_MINUTES}m" "${DOCKER_RUN_BASE[@]}" claude --continue \
            --dangerously-skip-permissions --model "$CHOSEN_MODEL" -p "$TASK_PROMPT" \
            2>&1 | tee "$TEMP_LOG"
    else
        # Fresh start: first attempt, or after Strategy B+C wiped .claude/.
        timeout "${MAX_MINUTES}m" "${DOCKER_RUN_BASE[@]}" claude \
            --dangerously-skip-permissions --model "$CHOSEN_MODEL" -p "$TASK_PROMPT" \
            2>&1 | tee "$TEMP_LOG"
    fi
    # PIPESTATUS[0] captures the docker/timeout exit code, not tee's (which is
    # almost always 0 and would mask real failures).
    EXIT_CODE=${PIPESTATUS[0]}
    SESSION_STARTED=true
    set -e

    if [ $EXIT_CODE -eq 0 ]; then
        echo "✅ Task completed successfully on attempt $ATTEMPT."
        rm -f ".task_handoff.md" "GEMINI_ADVICE.md"
        SUCCESS=true
        break
    fi

    # ===========================================================================
    # RATE LIMIT DETECTION
    # Claude Pro emits a message like "try again after 14:00" when the token quota
    # is exhausted. We parse the reset time, sleep with a 5-minute safety buffer,
    # then resume. Rate-limit waits use `continue` to jump back to the top WITHOUT
    # incrementing ATTEMPT — they do not consume a retry slot.
    # ===========================================================================
    if strip_ansi "$TEMP_LOG" | grep -qi "after [0-9]\{1,2\}:[0-9]\{2\}"; then
        TARGET_TIME=$(strip_ansi "$TEMP_LOG" \
            | grep -oi "after [0-9]\{1,2\}:[0-9]\{2\}\( *[AaPp][Mm]\)\?" \
            | tail -1 \
            | awk '{print $2, $3}' \
            | xargs)

        echo "🛑 [RATE LIMIT] Quota exhausted. Claude reported reset time: $TARGET_TIME"

        TARGET_EPOCH=$(date -d "$TARGET_TIME" +%s 2>/dev/null \
            || date -d "today $TARGET_TIME" +%s)
        NOW_EPOCH=$(date +%s)
        [ "$TARGET_EPOCH" -lt "$NOW_EPOCH" ] && \
            TARGET_EPOCH=$(date -d "tomorrow $TARGET_TIME" +%s)
        TARGET_EPOCH=$(( TARGET_EPOCH + 300 ))   # 5-minute safety buffer
        TARGET_DISPLAY=$(date -d "@$TARGET_EPOCH" '+%H:%M:%S')

        docker kill "$CONTAINER_NAME" 2>/dev/null || true
        wait_for_quota "$TARGET_EPOCH" "$TARGET_DISPLAY"
        continue
    fi

    if [ $EXIT_CODE -eq 124 ]; then
        echo "⚠️  [TIMEOUT] Attempt $ATTEMPT exceeded the ${MAX_MINUTES}m limit."
    else
        echo "⚠️  [FAILURE] Attempt $ATTEMPT exited with code $EXIT_CODE."
    fi

    # ===========================================================================
    # RECOVERY PHASE
    #
    # On any non-rate-limit failure:
    #
    #   Gemini Audit (pre-flight, if enabled):
    #     Sends failure context to Gemini 2.5 Flash for architectural advice.
    #     Sets GEMINI_ADVICE_TEXT. Non-fatal: recovery continues if API fails.
    #
    #   Strategy A (primary):
    #     Pipes /compact to Claude Code's built-in slash command. Verifies by
    #     measuring .claude/ size before and after — exit 0 alone is insufficient.
    #     On success, rebuilds TASK_PROMPT with Gemini advice prepended to BASE_TASK.
    #
    #   Strategy B+C (fallback):
    #     B — Run one final --continue pass asking Claude to write a checkpoint
    #         (.task_handoff.md) while it can still see its full history.
    #     C — Wipe .claude/ entirely. The handoff file survives in the workspace
    #         volume. Next attempt starts fresh but gets the checkpoint + Gemini
    #         advice injected into its prompt.
    # ===========================================================================
    if [ $ATTEMPT -lt $MAX_RETRIES ]; then
        docker kill "$CONTAINER_NAME" 2>/dev/null || true
        sleep 2

        # --- GEMINI CROSS-MODEL AUDIT (pre-flight before recovery strategies) ---
        if [ "$GEMINI_ENABLED" = true ]; then
            run_gemini_audit || true   # non-fatal; recovery continues either way
        fi

        echo "🧹 [RECOVERY] Attempting context compaction (Strategy A)..."

        # Snapshot .claude/ size before the compaction attempt.
        BEFORE_SIZE=0
        [ -d ".claude" ] && BEFORE_SIZE=$(du -sk ".claude" 2>/dev/null | cut -f1 || echo "0")

        # Strategy A: /compact is a Claude Code slash command that summarises the
        # conversation history in-place. Without -t (no TTY), the CLI reads stdin
        # directly; piping the command triggers the same compaction path as typing
        # /compact interactively.
        set +e
        printf '/compact\n' | timeout "3m" "${DOCKER_RECOVERY_BASE[@]}" \
            claude --continue --dangerously-skip-permissions --model "$CHOSEN_MODEL"
        COMPACT_CODE=$?
        set -e

        AFTER_SIZE=0
        [ -d ".claude" ] && AFTER_SIZE=$(du -sk ".claude" 2>/dev/null | cut -f1 || echo "0")

        if [ $COMPACT_CODE -eq 0 ] && [ "${AFTER_SIZE}" -lt "${BEFORE_SIZE}" ]; then
            echo "✅ Strategy A: session compacted ${BEFORE_SIZE}K → ${AFTER_SIZE}K."
            echo "   Next attempt resumes via --continue from the condensed session."
            # Prepend Gemini advice to BASE_TASK so the resumed session benefits.
            TASK_PROMPT=$(build_prompt_with_advice "$BASE_TASK")
            [ -n "${GEMINI_ADVICE_TEXT:-}" ] && echo "   Gemini advice injected into next attempt prompt."
        else
            echo "⚠️  Strategy A ineffective (${BEFORE_SIZE}K → ${AFTER_SIZE}K, exit ${COMPACT_CODE})."
            echo "   Running Strategy B+C: handoff capture then context reset..."

            # Strategy B: Run one final --continue pass asking Claude to write a
            # checkpoint. The workspace volume ensures the file survives even after
            # we wipe .claude/ in step C.
            set +e
            timeout "2m" "${DOCKER_RECOVERY_BASE[@]}" claude --continue \
                --dangerously-skip-permissions --model "$CHOSEN_MODEL" \
                -p "Session interrupted. Do NOT continue the main task. Write .task_handoff.md to the workspace root with exactly: (1) bullet list of fully completed steps, (2) what was actively in-progress when interrupted, (3) any files created or modified, (4) the precise next steps needed to finish. Be concise. Stop immediately after writing."
            HANDOFF_CODE=$?
            set -e

            # Strategy C: Wipe the bloated failed session. Carrying a full failed
            # history into the next attempt wastes tokens and biases reasoning.
            echo "🗑️  Resetting session context (handoff file preserved in workspace)..."
            rm -rf .claude/
            SESSION_STARTED=false   # Next iteration must start fresh, not --continue

            # Build the new BASE_TASK from the handoff (if captured), then inject
            # Gemini advice on top. Always wrap ORIGINAL_TASK_PROMPT (not BASE_TASK)
            # so repeated B+C cycles never nest "Context from previous session:" blocks.
            if [ $HANDOFF_CODE -eq 0 ] && [ -f ".task_handoff.md" ]; then
                HANDOFF_CONTEXT=$(cat ".task_handoff.md")
                BASE_TASK="Context from previous session:
${HANDOFF_CONTEXT}

Continue the original task: ${ORIGINAL_TASK_PROMPT}"
                echo "✅ Strategy B+C: handoff captured, session wiped."
            else
                echo "⚠️  Handoff write failed (exit ${HANDOFF_CODE}). Starting from original task."
                BASE_TASK="$ORIGINAL_TASK_PROMPT"
            fi

            TASK_PROMPT=$(build_prompt_with_advice "$BASE_TASK")
            [ -n "${GEMINI_ADVICE_TEXT:-}" ] && echo "   Gemini advice injected into next attempt prompt."
        fi

        sleep 3
    fi

    ATTEMPT=$((ATTEMPT + 1))
done

if [ "$SUCCESS" = false ]; then
    echo "❌ [FATAL ERROR] Task execution failed to resolve after $MAX_RETRIES attempts."
    if [ "$GEMINI_ENABLED" = true ] && [ -f "GEMINI_ADVICE.md" ]; then
        echo "💡 Gemini's last audit is saved in GEMINI_ADVICE.md for your review."
    fi
    exit 1
fi
