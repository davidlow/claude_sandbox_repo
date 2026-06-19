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

    # Pass MOCK_CLAUDE_EXIT into the container when set (used by mock image in tests).
    local extra_docker_env=()
    [ -n "${MOCK_CLAUDE_EXIT:-}" ] && extra_docker_env+=(-e "MOCK_CLAUDE_EXIT=$MOCK_CLAUDE_EXIT")

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
            "${extra_docker_env[@]}" \
            "${CLAUDE_SANDBOX_IMAGE:-claude-sandbox}" \
            claude --dangerously-skip-permissions --model "$model" -p "$prompt"
    ) || exit_code=$?

    rm -rf .claude/ 2>/dev/null || true
    return $exit_code
}

# ---------------------------------------------------------------------------
# ensure_claude_md_current <container_name> [model]
# Ensures CLAUDE.md exists and reflects recent git commits before a Gemini call.
#
# Two scenarios trigger an update:
#   1. CLAUDE.md is absent          → creates it from scratch
#   2. CLAUDE.md is older than the  → refreshes it to capture recent changes
#      most recent git commit
#
# The refresh prompt is scoped to CLAUDE.md updates only — Claude is explicitly
# told not to make any other code changes. This function never calls Gemini, so
# it cannot cause a Gemini→update→Gemini infinite loop.
#
# Requires OAUTH_TOKEN and OAUTH_REFRESH to be set in the environment (uses
# run_headless_phase). Non-fatal: failures are logged and the caller proceeds
# with whatever context is available.
# ---------------------------------------------------------------------------
ensure_claude_md_current() {
    local container_name="${1:-claude-md-refresh-$$}"
    local model="${2:-claude-haiku-4-5}"

    local needs_create=false
    local needs_update=false

    if [ ! -f "CLAUDE.md" ]; then
        needs_create=true
    elif git rev-parse --git-dir >/dev/null 2>&1; then
        local last_commit_ts claude_md_ts
        last_commit_ts=$(git log -1 --format=%ct 2>/dev/null || echo "0")
        claude_md_ts=$(stat -c %Y CLAUDE.md 2>/dev/null || echo "0")
        if [ "$last_commit_ts" -gt "$claude_md_ts" ]; then
            needs_update=true
        fi
    fi

    if [ "$needs_create" = false ] && [ "$needs_update" = false ]; then
        return 0
    fi

    local prompt
    if [ "$needs_create" = true ]; then
        echo "⚠️  CLAUDE.md not found. Generating before Gemini call..."
        prompt="Analyze this codebase and create a CLAUDE.md file in the root directory. Follow standard Claude Code conventions: project purpose, exact build/test/lint commands, file layout, and engineering/style guidelines for this tech stack. Do not perform any other tasks."
    else
        echo "📋 CLAUDE.md is older than the latest commit — refreshing before Gemini call..."
        prompt="Your ONLY task is to update the existing CLAUDE.md file to reflect recent changes in this codebase. Run 'git log --oneline -20' to see what has changed recently. Review the current CLAUDE.md and update any sections that are now outdated — focus on new or removed files, changed commands, and modified architecture. Preserve the existing structure and style. Do NOT make any other code changes."
    fi

    run_headless_phase "$container_name" "$model" "5" "$prompt" || true

    if [ -f "CLAUDE.md" ]; then
        echo "✅ CLAUDE.md is current."
    else
        echo "⚠️  CLAUDE.md refresh failed. Proceeding without it."
    fi
}

# ---------------------------------------------------------------------------
# Gemini model priority lists — ordered by preference within each tier.
#
# Flash models handle real problems (newest/most capable first).
# Lite models are used when GEMINI_MODEL_TIER=lite (test runs) or as a
# last-resort fallback when all flash models are rate-limited.
# ---------------------------------------------------------------------------
_GEMINI_FLASH_MODELS=(
    "gemini-3.5-flash"
    "gemini-3-flash"
    "gemini-2.5-flash"
)
_GEMINI_LITE_MODELS=(
    "gemini-3.1-flash-lite"
    "gemini-2.5-flash-lite"
)

# ---------------------------------------------------------------------------
# call_gemini <prompt_file> <output_file>
# Reads the full prompt from prompt_file, calls the Gemini API with automatic
# model fallback, and writes the response text to output_file.
#
# Model selection is controlled by the GEMINI_MODEL_TIER environment variable:
#   flash (default): tries flash models in order (3.5→3→2.5), then falls back
#                    to lite models if all flash models are rate-limited (429).
#                    A warning is printed to stderr when the lite fallback fires.
#   lite:            uses only lite models (3.1-flash-lite→2.5-flash-lite).
#                    Set this for test runs to minimise free-tier quota pressure:
#                    GEMINI_MODEL_TIER=lite ./tests/run_tests.sh --gemini
#
# On HTTP 429 (rate limit), the current model is retried up to 3 times with
# exponential back-off; if retries are exhausted the next model in the list is
# tried. Any other HTTP error causes an immediate failure (no model switching).
#
# Reads GEMINI_API_KEY from the environment.
# Returns 0 on success, 1 on failure (API error, missing key, all models
# exhausted, empty response).
# ---------------------------------------------------------------------------
call_gemini() {
    local prompt_file="$1"
    local output_file="$2"
    local tier="${GEMINI_MODEL_TIER:-flash}"

    # Build ordered model list (newline-separated) and flash model count.
    local models_env flash_count_env
    if [ "$tier" = "lite" ]; then
        models_env=$(printf '%s\n' "${_GEMINI_LITE_MODELS[@]}")
        flash_count_env=0
    else
        models_env=$(printf '%s\n' "${_GEMINI_FLASH_MODELS[@]}" "${_GEMINI_LITE_MODELS[@]}")
        flash_count_env="${#_GEMINI_FLASH_MODELS[@]}"
    fi

    # Warnings (e.g. lite fallback notice) are written to a temp file by Python
    # and then printed to stderr by bash after the response is captured.
    local warn_file
    warn_file=$(mktemp)

    local response
    response=$(GEMINI_PROMPT_FILE="$prompt_file" \
               GEMINI_MODELS="$models_env" \
               GEMINI_FLASH_COUNT="$flash_count_env" \
               GEMINI_WARN_FILE="$warn_file" \
               python3 - <<'PYEOF' 2>/dev/null
import json, os, sys, time, urllib.request, urllib.error

api_key      = os.environ.get('GEMINI_API_KEY', '')
prompt_file  = os.environ.get('GEMINI_PROMPT_FILE', '')
models       = [m for m in os.environ.get('GEMINI_MODELS', '').splitlines() if m]
flash_count  = int(os.environ.get('GEMINI_FLASH_COUNT', '0'))
warn_file    = os.environ.get('GEMINI_WARN_FILE', '')

if not api_key or not prompt_file or not models:
    sys.exit(1)

try:
    with open(prompt_file) as f:
        prompt = f.read()
except OSError:
    sys.exit(1)

payload = json.dumps({
    'contents': [{'parts': [{'text': prompt}]}],
    'generationConfig': {'maxOutputTokens': 8192, 'temperature': 0.3}
}).encode()

def write_warn(msg):
    if warn_file:
        with open(warn_file, 'a') as wf:
            wf.write(msg + '\n')

for idx, model in enumerate(models):
    # Warn once when crossing from flash into lite fallback territory.
    if flash_count > 0 and idx == flash_count:
        write_warn(
            f'⚠️  All flash Gemini models are rate-limited. '
            f'Falling back to {model} (lite tier).\n'
            '   Response quality may be lower. '
            'Consider a GEMINI_API_KEY with higher quota limits.'
        )

    url = (
        'https://generativelanguage.googleapis.com/v1beta/models/'
        f'{model}:generateContent?key={api_key}'
    )
    req = urllib.request.Request(
        url, data=payload, headers={'Content-Type': 'application/json'}
    )

    # Retry up to 3 times with exponential back-off on rate-limit (HTTP 429).
    # Any other HTTP error fails immediately without trying further models.
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                data = json.loads(resp.read())
            print(data['candidates'][0]['content']['parts'][0]['text'])
            sys.exit(0)
        except urllib.error.HTTPError as e:
            if e.code == 429:
                if attempt < 2:
                    time.sleep(12 * (attempt + 1))  # 12 s, then 24 s
                    continue
                break  # 429 retries exhausted — try next model
            sys.exit(1)  # non-429 error: fail immediately
        except Exception:
            sys.exit(1)

sys.exit(1)  # all models exhausted
PYEOF
    )

    # Surface any warnings (lite fallback etc.) to the caller's stderr.
    if [ -s "$warn_file" ]; then
        cat "$warn_file" >&2
    fi
    rm -f "$warn_file"

    if [ -n "$response" ]; then
        printf '%s\n' "$response" > "$output_file"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# build_gemini_architectural_prompt <task> <candidates_file>
# Prints a Gemini prompt for critiquing architectural design candidates.
# Includes project context (CLAUDE.md if present) and the task objective so
# Gemini can evaluate fit with the existing codebase, not just the candidates
# in isolation. Redirect stdout to a temp file and pass that to call_gemini.
# ---------------------------------------------------------------------------
build_gemini_architectural_prompt() {
    local task="$1"
    local candidates_file="$2"
    if [ -f "CLAUDE.md" ]; then
        printf '=== PROJECT CONTEXT (CLAUDE.md) ===\n'
        cat "CLAUDE.md"
        printf '\n\n'
    fi
    printf '=== TASK OBJECTIVE ===\n%s\n\n' "${task:-"(no task specified)"}"
    printf '%s\n\n' \
        "You are a Principal Engineer performing an adversarial architectural review. Read the proposed designs below. For EACH option, provide a concise critique covering: (1) maintainability risks, (2) scaling bottlenecks, (3) security concerns, (4) hidden complexity. Do NOT select a winner — only critique each option individually. Be direct, specific, and adversarial."
    printf '=== ARCHITECTURAL CANDIDATES ===\n'
    cat "$candidates_file" 2>/dev/null || printf '(candidates file not found)\n'
}

# ---------------------------------------------------------------------------
# build_gemini_qa_prompt <task> <payload_file>
# Prints a Gemini prompt for adversarial QA coverage analysis.
# Includes the testing scope and project context (CLAUDE.md if present) so
# Gemini knows what framework/conventions apply and what's in scope.
# Redirect stdout to a temp file and pass that to call_gemini.
# ---------------------------------------------------------------------------
build_gemini_qa_prompt() {
    local task="$1"
    local payload_file="$2"
    printf '=== TESTING SCOPE ===\n%s\n\n' "${task:-"(no task specified)"}"
    if [ -f "CLAUDE.md" ]; then
        printf '=== PROJECT CONTEXT (CLAUDE.md) ===\n'
        cat "CLAUDE.md"
        printf '\n\n'
    fi
    printf '%s\n\n' \
        "You are an adversarial Red Team QA engineer reviewing a codebase and its test suite. Identify edge cases, boundary conditions, race conditions, type-coercion bugs, null/undefined handling failures, and error paths that the current tests FAIL to cover. Output a numbered list of concrete, implementable missing test requirements. Assume this code will be deployed to production — be ruthlessly thorough."
    printf '=== SOURCE AND TEST FILES ===\n'
    cat "$payload_file" 2>/dev/null || printf '(payload file not found)\n'
}

# ---------------------------------------------------------------------------
# build_gemini_refactor_prompt <task> <context_file>
# Prints a Gemini prompt for diagnosing a failed refactoring attempt.
# Includes the task objective and project context (CLAUDE.md if present).
# Redirect stdout to a temp file and pass that to call_gemini.
# ---------------------------------------------------------------------------
build_gemini_refactor_prompt() {
    local task="$1"
    local context_file="$2"
    printf '=== TASK OBJECTIVE ===\n%s\n\n' "${task:-"(no task specified)"}"
    if [ -f "CLAUDE.md" ]; then
        printf '=== PROJECT CONTEXT (CLAUDE.md) ===\n'
        cat "CLAUDE.md"
        printf '\n\n'
    fi
    printf '%s\n\n' \
        "An autonomous coding agent attempted a refactoring task and failed. Review the context below (original task, stack trace or test failures, and the agent's git diff). Diagnose the fundamental logical flaw in the agent's approach. Explain specifically: (1) what it got wrong, (2) what assumption was incorrect, (3) what the next attempt must do differently. Be concise and directly actionable."
    printf '=== FAILURE CONTEXT ===\n'
    cat "$context_file" 2>/dev/null || printf '(context file not found)\n'
}

# ---------------------------------------------------------------------------
# build_gemini_dispatch_prompt <task>
# Prints a Gemini prompt for decomposing a compound task into an ordered
# sequence of pipeline steps. Used by launch-dispatch.sh for smart routing.
# Redirect stdout to a temp file and pass that to call_gemini.
#
# Output format from Gemini (one line per step):
#   PIPELINE: task description for this step
# Valid pipeline names: architect, qa, refactor, scripted.
# ---------------------------------------------------------------------------
build_gemini_dispatch_prompt() {
    local task="$1"
    if [ -f "CLAUDE.md" ]; then
        printf '=== PROJECT CONTEXT (CLAUDE.md) ===\n'
        cat "CLAUDE.md"
        printf '\n\n'
    fi
    printf '%s\n\n' \
"You are a task dispatcher for an autonomous coding agent toolchain. Decompose the task below into an ordered sequence of pipeline steps.

Available pipelines:
- architect: Design and build a new feature from scratch (brainstorm → evaluate → implement).
- qa: Write or improve a test suite (generate → adversarial audit → remediate gaps).
- refactor: Fix a bug, reduce coupling, or restructure code (diagnose → plan → implement).
- scripted: General-purpose coding task that does not fit the above three.

Output format — output ONLY these lines, no prose, no commentary:
PIPELINE: task description for this step

Rules:
1. Use 1 step for simple tasks; multiple steps for compound tasks.
2. If the task involves building a feature AND testing it, use separate architect and qa steps.
3. If the task involves finding failures then fixing them, use qa → refactor.
4. Keep each step prompt concrete and self-contained (passed directly to that pipeline).
5. Output at most 8 steps."
    printf '=== TASK ===\n%s\n' "${task:-"(no task specified)"}"
}

# ---------------------------------------------------------------------------
# decision_log_init <file> <pipeline> <task> <model>
# Creates a new timestamped decision log with a standard markdown header.
# The parent directory is created if it does not exist.
# ---------------------------------------------------------------------------
decision_log_init() {
    local file="$1"
    local pipeline="$2"
    local task="$3"
    local model="$4"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M')
    mkdir -p "$(dirname "$file")"
    printf '# %s: %s\n**Date:** %s\n**Pipeline:** %s\n**Model:** %s\n**Status:** in-progress\n\n## Task\n%s\n\n' \
        "$pipeline" "$task" "$timestamp" "$pipeline" "$model" "$task" > "$file"
}

# ---------------------------------------------------------------------------
# decision_log_section <file> <title> [content_file]
# Appends a titled section to a decision log. If content_file exists on disk,
# its contents are embedded verbatim. If absent or unspecified, a placeholder
# is written. For inline text notes, use decision_log_note instead.
# ---------------------------------------------------------------------------
decision_log_section() {
    local file="$1"
    local title="$2"
    local content_file="${3:-}"
    [ ! -f "$file" ] && return 0
    printf '\n## %s\n\n' "$title" >> "$file"
    if [ -n "$content_file" ] && [ -f "$content_file" ]; then
        cat "$content_file" >> "$file"
    else
        printf '*(not available)*\n' >> "$file"
    fi
    printf '\n' >> "$file"
}

# ---------------------------------------------------------------------------
# decision_log_note <file> <title> <text>
# Appends a titled section containing an inline text note to a decision log.
# Use this when there is no artifact file to embed (e.g. phase skipped, failed).
# ---------------------------------------------------------------------------
decision_log_note() {
    local file="$1"
    local title="$2"
    local text="$3"
    [ ! -f "$file" ] && return 0
    printf '\n## %s\n\n%s\n\n' "$title" "$text" >> "$file"
}

# ---------------------------------------------------------------------------
# decision_log_outcome <file> <status> [notes]
# Updates the in-progress Status line to the final status (success/failed) and
# appends an Outcome section. Should be called once at the end of a pipeline run.
# ---------------------------------------------------------------------------
decision_log_outcome() {
    local file="$1"
    local status="$2"
    local notes="${3:-}"
    [ ! -f "$file" ] && return 0
    sed -i "s/^\*\*Status:\*\* in-progress/**Status:** ${status}/" "$file"
    printf '\n## Outcome\n\n**Status:** %s\n' "$status" >> "$file"
    if [ -n "$notes" ]; then printf '\n%s\n' "$notes" >> "$file"; fi
}
