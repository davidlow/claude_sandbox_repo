#!/bin/bash
# Pure helper functions shared between launch-scripted.sh and the test suite.
# Source this file; do not execute it directly.

# ---------------------------------------------------------------------------
# parse_args <args...>
# Extracts --no-gemini flag and positional args.
# Sets globals: GEMINI_ENABLED, POSITIONAL_ARGS, ORIGINAL_TASK_PROMPT, CHOSEN_MODEL
# ---------------------------------------------------------------------------
parse_args() {
    GEMINI_ENABLED=true
    POSITIONAL_ARGS=()
    for arg in "$@"; do
        case "$arg" in
            --no-gemini) GEMINI_ENABLED=false ;;
            *) POSITIONAL_ARGS+=("$arg") ;;
        esac
    done
    ORIGINAL_TASK_PROMPT="${POSITIONAL_ARGS[0]:-}"
    CHOSEN_MODEL="${POSITIONAL_ARGS[1]:-claude-sonnet-4-6}"
}

# ---------------------------------------------------------------------------
# parse_model_tier <model>
# Sets per-model resource budget globals based on model name substring match.
# Sets globals: MAX_MINUTES, MAX_RETRIES, MAX_CONTEXT_TOKENS,
#               TARGET_INPUT_TOKENS, MAX_THINKING_TOKENS
# ---------------------------------------------------------------------------
parse_model_tier() {
    local model="$1"
    # Sonnet tier baseline (default)
    MAX_MINUTES="10"
    MAX_RETRIES=3
    MAX_CONTEXT_TOKENS=80000
    TARGET_INPUT_TOKENS=40000
    MAX_THINKING_TOKENS=10000

    if [[ "$model" == *"haiku"* ]]; then
        MAX_MINUTES="15"
        MAX_CONTEXT_TOKENS=50000
        TARGET_INPUT_TOKENS=25000
        MAX_THINKING_TOKENS=0
    elif [[ "$model" == *"opus"* ]]; then
        MAX_MINUTES="5"
        MAX_RETRIES=2
        MAX_CONTEXT_TOKENS=120000
        TARGET_INPUT_TOKENS=60000
        MAX_THINKING_TOKENS=24000
    elif [[ "$model" == *"fable"* ]]; then
        MAX_MINUTES="4"
        MAX_RETRIES=2
        MAX_CONTEXT_TOKENS=120000
        TARGET_INPUT_TOKENS=60000
        MAX_THINKING_TOKENS=0
    fi
}

# ---------------------------------------------------------------------------
# strip_ansi <file>
# Strips ANSI color/cursor escape sequences and carriage returns from a file.
# Prints cleaned output to stdout.
# ---------------------------------------------------------------------------
strip_ansi() {
    sed 's/\x1b\[[0-9;]*[A-Za-z]//g; s/\r//g' "$1"
}

# ---------------------------------------------------------------------------
# build_prompt_with_advice <base_task>
# If GEMINI_ADVICE_TEXT is non-empty, prepends the advice block to base_task.
# Prints the composed prompt to stdout.
# ---------------------------------------------------------------------------
build_prompt_with_advice() {
    local base="$1"
    if [ -n "${GEMINI_ADVICE_TEXT:-}" ]; then
        printf '=== GEMINI ARCHITECT ADVICE (from previous failed attempt) ===\n%s\n=== END ADVICE ===\n\n%s' \
            "$GEMINI_ADVICE_TEXT" "$base"
    else
        printf '%s' "$base"
    fi
}

# ---------------------------------------------------------------------------
# wait_for_quota <target_epoch> <target_display>
# Blocks until target_epoch, printing a heartbeat every 5 minutes.
# Returns immediately if target_epoch is already in the past.
# ---------------------------------------------------------------------------
wait_for_quota() {
    local target_epoch="$1"
    local target_display="$2"
    echo "💤 Entering standby. Quota resets at $target_display (including 5-min buffer)."
    while true; do
        local now remaining mins secs curr_time
        now=$(date +%s)
        remaining=$(( target_epoch - now ))
        [ "$remaining" -le 0 ] && break
        mins=$(( remaining / 60 ))
        secs=$(( remaining % 60 ))
        curr_time=$(date '+%H:%M:%S')
        echo "   [$curr_time] Waiting... ${mins}m ${secs}s until $target_display"
        sleep 300
    done
    echo "⏰ Quota window open. Resuming task..."
}
