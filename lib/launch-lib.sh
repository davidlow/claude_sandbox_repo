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

# ---------------------------------------------------------------------------
# run_headless_phase <container_name> <model> <timeout_mins> <prompt>
# Runs a single headless (no PTY) Docker container phase for pipeline scripts.
# Uses a subshell to isolate error-exit changes from the calling script.
# Calls parse_model_tier to set token budget env vars for the container.
# Reads OAUTH_TOKEN and OAUTH_REFRESH from the environment (set by caller).
# Wipes .claude/ on completion regardless of exit code.
# Returns the docker/timeout exit code.
# ---------------------------------------------------------------------------
run_headless_phase() {
    local container_name="$1"
    local model="$2"
    local timeout_mins="$3"
    local prompt="$4"

    parse_model_tier "$model"

    local exit_code=0
    (
        set +e
        timeout "${timeout_mins}m" docker run -i --rm \
            --name "$container_name" \
            -v "$(pwd)":/workspace \
            -v "$HOME/.claude":/home/claudeuser/.claude \
            -e CLAUDE_CODE_OAUTH_TOKEN="$OAUTH_TOKEN" \
            -e CLAUDE_CODE_OAUTH_REFRESH_TOKEN="$OAUTH_REFRESH" \
            -e DISABLE_AUTO_COMPACT=0 \
            -e CLAUDE_CODE_MAX_CONTEXT_TOKENS="$MAX_CONTEXT_TOKENS" \
            -e API_TARGET_INPUT_TOKENS="$TARGET_INPUT_TOKENS" \
            -e MAX_THINKING_TOKENS="$MAX_THINKING_TOKENS" \
            claude-sandbox \
            claude --dangerously-skip-permissions --model "$model" -p "$prompt"
    ) || exit_code=$?

    rm -rf .claude/ 2>/dev/null || true
    return $exit_code
}

# ---------------------------------------------------------------------------
# call_gemini <prompt_file> <output_file>
# Reads the full prompt from prompt_file, calls Gemini 2.5 Flash, and writes
# the response text to output_file.
# Reads GEMINI_API_KEY from the environment.
# Returns 0 on success, 1 on failure (API error, missing key, empty response).
# ---------------------------------------------------------------------------
call_gemini() {
    local prompt_file="$1"
    local output_file="$2"

    local response
    response=$(GEMINI_PROMPT_FILE="$prompt_file" python3 - <<'PYEOF' 2>/dev/null
import json, os, sys, urllib.request

api_key = os.environ.get('GEMINI_API_KEY', '')
prompt_file = os.environ.get('GEMINI_PROMPT_FILE', '')
if not api_key or not prompt_file:
    sys.exit(1)

try:
    with open(prompt_file) as f:
        prompt = f.read()
except OSError:
    sys.exit(1)

payload = json.dumps({
    'contents': [{'parts': [{'text': prompt}]}],
    'generationConfig': {'maxOutputTokens': 2048, 'temperature': 0.3}
}).encode()

url = (
    'https://generativelanguage.googleapis.com/v1beta/models/'
    'gemini-2.5-flash:generateContent?key=' + api_key
)
req = urllib.request.Request(
    url, data=payload, headers={'Content-Type': 'application/json'}
)
try:
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.loads(resp.read())
    print(data['candidates'][0]['content']['parts'][0]['text'])
except Exception:
    sys.exit(1)
PYEOF
    )

    if [ -n "$response" ]; then
        printf '%s\n' "$response" > "$output_file"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# build_gemini_architectural_prompt <candidates_file>
# Prints a Gemini prompt for critiquing architectural design candidates.
# Redirect stdout to a temp file and pass that to call_gemini.
# ---------------------------------------------------------------------------
build_gemini_architectural_prompt() {
    local candidates_file="$1"
    printf '%s\n\n%s\n' \
        "You are a Principal Engineer performing an architectural review. Read the proposed designs below. For EACH option, provide a concise critique covering: (1) maintainability risks, (2) scaling bottlenecks, (3) security concerns, (4) hidden complexity. Do NOT select a winner — only critique each option individually. Be direct, specific, and adversarial." \
        "$(cat "$candidates_file" 2>/dev/null || echo '(candidates file not found)')"
}

# ---------------------------------------------------------------------------
# build_gemini_qa_prompt <payload_file>
# Prints a Gemini prompt for adversarial QA coverage analysis.
# Redirect stdout to a temp file and pass that to call_gemini.
# ---------------------------------------------------------------------------
build_gemini_qa_prompt() {
    local payload_file="$1"
    printf '%s\n\n%s\n' \
        "You are an adversarial Red Team QA engineer reviewing a codebase and its test suite. Identify edge cases, boundary conditions, race conditions, type-coercion bugs, null/undefined handling failures, and error paths that the current tests FAIL to cover. Output a numbered list of concrete, implementable missing test requirements. Assume this code will be deployed to production — be ruthlessly thorough." \
        "$(cat "$payload_file" 2>/dev/null || echo '(payload file not found)')"
}

# ---------------------------------------------------------------------------
# build_gemini_refactor_prompt <context_file>
# Prints a Gemini prompt for diagnosing a failed refactoring attempt.
# Redirect stdout to a temp file and pass that to call_gemini.
# ---------------------------------------------------------------------------
build_gemini_refactor_prompt() {
    local context_file="$1"
    printf '%s\n\n%s\n' \
        "An autonomous coding agent attempted a refactoring task and failed. Review the context below (original task, stack trace or test failures, and the agent's git diff). Diagnose the fundamental logical flaw in the agent's approach. Explain specifically: (1) what it got wrong, (2) what assumption was incorrect, (3) what the next attempt must do differently. Be concise and directly actionable." \
        "$(cat "$context_file" 2>/dev/null || echo '(context file not found)')"
}
