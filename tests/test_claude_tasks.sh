#!/bin/bash
# Integration tests: Claude executes real tasks inside the container.
# Each task is designed to produce a verifiable, deterministic side effect.
#
# Requires: Docker running, claude-sandbox image built, valid credentials.
# Timeout per task: 2 minutes (keeps the suite fast while allowing Claude time to think).
set -eo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TESTS_DIR/helpers.sh"

CREDS="$HOME/.claude/.credentials.json"
TASK_TIMEOUT="2m"

# ---------------------------------------------------------------------------
# Guard: skip entire file if environment is not ready
# ---------------------------------------------------------------------------
_check_prereqs() {
    if ! docker info >/dev/null 2>&1; then
        echo ""
        echo "⏭  Skipping claude task tests — Docker not running."
        print_results
        exit 0
    fi
    if ! docker image inspect claude-sandbox >/dev/null 2>&1; then
        echo ""
        echo "⏭  Skipping claude task tests — claude-sandbox image not found."
        print_results
        exit 0
    fi
    if [ ! -f "$CREDS" ]; then
        echo ""
        echo "⏭  Skipping claude task tests — no credentials at $CREDS."
        print_results
        exit 0
    fi
}
_check_prereqs

# Extract real OAuth tokens
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
    echo "⏭  Skipping claude task tests — could not read OAuth token."
    print_results
    exit 0
fi

# ---------------------------------------------------------------------------
# _run_claude_task <workspace_dir> <prompt>
# Runs Claude headlessly in a fresh workspace. Prints Claude's stdout.
# Returns the container exit code.
# ---------------------------------------------------------------------------
_run_claude_task() {
    local ws="$1" prompt="$2"
    timeout "$TASK_TIMEOUT" docker run -i --rm \
        -v "$ws":/workspace \
        -v "$HOME/.claude":/home/claudeuser/.claude \
        -e CLAUDE_CODE_OAUTH_TOKEN="$OAUTH_TOKEN" \
        -e CLAUDE_CODE_OAUTH_REFRESH_TOKEN="$OAUTH_REFRESH" \
        claude-sandbox \
        claude --dangerously-skip-permissions -p "$prompt" 2>&1 || return $?
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "Claude task: arithmetic"

WS=$(mktemp -d); trap 'rm -rf "$WS"' RETURN
_run_claude_task "$WS" \
    "Create a file named result.txt in /workspace containing exactly the text: 4" \
    > /dev/null
assert_file_exists "arithmetic file created" "$WS/result.txt"
content=$(cat "$WS/result.txt" 2>/dev/null | tr -d '[:space:]')
assert_equals "arithmetic result correct (2+2=4)" "4" "$content"

suite "Claude task: file creation with exact content"

WS=$(mktemp -d); trap 'rm -rf "$WS"' RETURN
_run_claude_task "$WS" \
    "Write the string HELLO_WORLD (all caps, no spaces, no newline) into a file called output.txt in /workspace." \
    > /dev/null
assert_file_exists "output.txt created" "$WS/output.txt"
content=$(cat "$WS/output.txt" 2>/dev/null | tr -d '[:space:]')
assert_equals "file contains exact string" "HELLO_WORLD" "$content"

suite "Claude task: Python script execution"

WS=$(mktemp -d); trap 'rm -rf "$WS"' RETURN
_run_claude_task "$WS" \
    "Write a Python script at /workspace/compute.py that prints the integer 42 and nothing else. Then run it and save the output to /workspace/compute_output.txt." \
    > /dev/null
assert_file_exists "python script created" "$WS/compute.py"
assert_file_exists "script output file created" "$WS/compute_output.txt"
content=$(cat "$WS/compute_output.txt" 2>/dev/null | tr -d '[:space:]')
assert_equals "python script produced correct output" "42" "$content"

suite "Claude task: multiple files and directory structure"

WS=$(mktemp -d); trap 'rm -rf "$WS"' RETURN
_run_claude_task "$WS" \
    "Create the following structure in /workspace: a directory named 'data', and inside it two files: 'a.txt' containing the word ALPHA and 'b.txt' containing the word BETA." \
    > /dev/null
assert_file_exists "data/a.txt created" "$WS/data/a.txt"
assert_file_exists "data/b.txt created" "$WS/data/b.txt"
a_content=$(cat "$WS/data/a.txt" 2>/dev/null | tr -d '[:space:]')
b_content=$(cat "$WS/data/b.txt" 2>/dev/null | tr -d '[:space:]')
assert_equals "a.txt contains ALPHA" "ALPHA" "$a_content"
assert_equals "b.txt contains BETA" "BETA" "$b_content"

suite "Claude task: reading an existing file and transforming it"

WS=$(mktemp -d); trap 'rm -rf "$WS"' RETURN
# Pre-seed the workspace with a file for Claude to read
echo "hello" > "$WS/input.txt"
_run_claude_task "$WS" \
    "Read /workspace/input.txt and write its contents converted to uppercase into /workspace/upper.txt." \
    > /dev/null
assert_file_exists "upper.txt created" "$WS/upper.txt"
content=$(cat "$WS/upper.txt" 2>/dev/null | tr -d '[:space:]')
assert_equals "content uppercased correctly" "HELLO" "$content"

suite "Claude task: bash script creation and execution"

WS=$(mktemp -d); trap 'rm -rf "$WS"' RETURN
_run_claude_task "$WS" \
    "Write a bash script at /workspace/greet.sh that echoes the string GREETINGS. Make it executable, run it, and save its output to /workspace/greet_output.txt." \
    > /dev/null
assert_file_exists "greet.sh created" "$WS/greet.sh"
assert_file_exists "greet output file created" "$WS/greet_output.txt"
content=$(cat "$WS/greet_output.txt" 2>/dev/null | tr -d '[:space:]')
assert_equals "bash script produced GREETINGS output" "GREETINGS" "$content"

suite "Claude task: JSON manipulation"

WS=$(mktemp -d); trap 'rm -rf "$WS"' RETURN
cat > "$WS/data.json" << 'EOF'
{"name": "claude", "version": 3}
EOF
_run_claude_task "$WS" \
    "Read /workspace/data.json and write the value of the 'name' key into /workspace/name.txt." \
    > /dev/null
assert_file_exists "name.txt created" "$WS/name.txt"
content=$(cat "$WS/name.txt" 2>/dev/null | tr -d '[:space:]')
assert_equals "JSON field extracted correctly" "claude" "$content"

print_results
