#!/bin/bash
# Unit tests for the pipeline helper functions in lib/launch-lib.sh.
# All tests run without Docker or network access.
set -eo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/helpers.sh"
source "$REPO_DIR/lib/launch-lib.sh"

# ==============================================================================
suite "call_gemini — API key guard"
# ==============================================================================

# Without GEMINI_API_KEY, call_gemini must return non-zero and write nothing.
TMPOUT=$(mktemp)
trap 'rm -f "$TMPOUT"' RETURN

TMPPRP=$(mktemp)
printf 'test prompt' > "$TMPPRP"

set +e
GEMINI_API_KEY="" call_gemini "$TMPPRP" "$TMPOUT"
RC=$?
set -e

assert_equals "no key: returns non-zero" "1" "$RC"

FILE_CONTENT=""
[ -s "$TMPOUT" ] && FILE_CONTENT=$(cat "$TMPOUT")
assert_equals "no key: output file stays empty" "" "$FILE_CONTENT"

rm -f "$TMPPRP"

# ==============================================================================
suite "call_gemini — missing prompt file"
# ==============================================================================

TMPOUT2=$(mktemp)
trap 'rm -f "$TMPOUT2"' RETURN

set +e
GEMINI_API_KEY="fake-key" call_gemini "/nonexistent/path/$$_prompt.txt" "$TMPOUT2"
RC2=$?
set -e

assert_equals "missing prompt file: returns non-zero" "1" "$RC2"

# ==============================================================================
suite "build_gemini_architectural_prompt"
# ==============================================================================

CAND_FILE=$(mktemp)
trap 'rm -f "$CAND_FILE"' RETURN
cat > "$CAND_FILE" <<'EOF'
## Option A: Event-Driven
Summary: use events
## Option B: Direct Coupling
Summary: call functions directly
## Option C: Plugin System
Summary: dynamic loading
EOF

OUTPUT=$(build_gemini_architectural_prompt "add a plugin system to the CLI" "$CAND_FILE")

assert_contains "arch prompt: contains adversarial framing" "adversarial" "$OUTPUT"
assert_contains "arch prompt: contains Principal Engineer" "Principal Engineer" "$OUTPUT"
assert_contains "arch prompt: contains maintainability" "maintainability" "$OUTPUT"
assert_contains "arch prompt: embeds candidates content" "Option A" "$OUTPUT"
assert_contains "arch prompt: does not select a winner" "Do NOT select a winner" "$OUTPUT"
assert_contains "arch prompt: contains task description" "add a plugin system to the CLI" "$OUTPUT"

rm -f "$CAND_FILE"

# ==============================================================================
suite "build_gemini_architectural_prompt — missing file"
# ==============================================================================

OUTPUT_MISSING=$(build_gemini_architectural_prompt "some task" "/nonexistent/file_$$_candidates.md")
assert_contains "arch prompt: handles missing file gracefully" "candidates file not found" "$OUTPUT_MISSING"

# ==============================================================================
suite "build_gemini_qa_prompt"
# ==============================================================================

PAYLOAD_FILE=$(mktemp)
trap 'rm -f "$PAYLOAD_FILE"' RETURN
cat > "$PAYLOAD_FILE" <<'PAYEOF'
--- src/auth.py ---
def login(user, pwd): pass
--- tests/test_auth.py ---
def test_login(): pass
PAYEOF

QA_OUTPUT=$(build_gemini_qa_prompt "write tests for the auth module" "$PAYLOAD_FILE")

assert_contains "qa prompt: contains adversarial framing" "adversarial" "$QA_OUTPUT"
assert_contains "qa prompt: mentions Red Team" "Red Team" "$QA_OUTPUT"
assert_contains "qa prompt: asks for numbered list" "numbered list" "$QA_OUTPUT"
assert_contains "qa prompt: mentions production" "production" "$QA_OUTPUT"
assert_contains "qa prompt: embeds payload content" "auth.py" "$QA_OUTPUT"
assert_contains "qa prompt: contains task description" "write tests for the auth module" "$QA_OUTPUT"

rm -f "$PAYLOAD_FILE"

# ==============================================================================
suite "build_gemini_qa_prompt — missing file"
# ==============================================================================

QA_MISSING=$(build_gemini_qa_prompt "some task" "/nonexistent/payload_$$.txt")
assert_contains "qa prompt: handles missing file gracefully" "payload file not found" "$QA_MISSING"

# ==============================================================================
suite "build_gemini_refactor_prompt"
# ==============================================================================

CTX_FILE=$(mktemp)
trap 'rm -f "$CTX_FILE"' RETURN
printf 'Task: fix the queue\nError: NullPointerException at line 42\ndiff --git a/queue.py\n' > "$CTX_FILE"

RF_OUTPUT=$(build_gemini_refactor_prompt "fix the queue" "$CTX_FILE")

assert_contains "refactor prompt: mentions autonomous agent" "autonomous" "$RF_OUTPUT"
assert_contains "refactor prompt: asks for diagnosis" "Diagnose" "$RF_OUTPUT"
assert_contains "refactor prompt: asks what went wrong" "what it got wrong" "$RF_OUTPUT"
assert_contains "refactor prompt: embeds context content" "NullPointerException" "$RF_OUTPUT"
assert_contains "refactor prompt: is actionable" "actionable" "$RF_OUTPUT"
assert_contains "refactor prompt: contains task description" "fix the queue" "$RF_OUTPUT"

rm -f "$CTX_FILE"

# ==============================================================================
suite "build_gemini_refactor_prompt — missing file"
# ==============================================================================

RF_MISSING=$(build_gemini_refactor_prompt "some task" "/nonexistent/context_$$.txt")
assert_contains "refactor prompt: handles missing file gracefully" "context file not found" "$RF_MISSING"

# ==============================================================================
suite "pipeline scripts — help flags"
# ==============================================================================

ARCH_HELP=$(bash "$REPO_DIR/launch-architect.sh" --help 2>&1) || true
assert_contains "architect --help: shows usage" "USAGE" "$ARCH_HELP"
assert_contains "architect --help: mentions phases" "Phase" "$ARCH_HELP"

QA_HELP=$(bash "$REPO_DIR/launch-qa.sh" --help 2>&1) || true
assert_contains "qa --help: shows usage" "USAGE" "$QA_HELP"

RF_HELP=$(bash "$REPO_DIR/launch-refactor.sh" --help 2>&1) || true
assert_contains "refactor --help: shows usage" "USAGE" "$RF_HELP"

# ==============================================================================
suite "pipeline scripts — missing task argument"
# ==============================================================================

set +e
ARCH_NO_ARGS=$(bash "$REPO_DIR/launch-architect.sh" 2>&1)
ARCH_RC=$?
set -e
assert_equals "architect: exits 1 with no args" "1" "$ARCH_RC"
assert_contains "architect: shows error message" "Error" "$ARCH_NO_ARGS"

set +e
QA_NO_ARGS=$(bash "$REPO_DIR/launch-qa.sh" 2>&1)
QA_RC=$?
set -e
assert_equals "qa: exits 1 with no args" "1" "$QA_RC"
assert_contains "qa: shows error message" "Error" "$QA_NO_ARGS"

set +e
RF_NO_ARGS=$(bash "$REPO_DIR/launch-refactor.sh" 2>&1)
RF_RC=$?
set -e
assert_equals "refactor: exits 1 with no args" "1" "$RF_RC"
assert_contains "refactor: shows error message" "Error" "$RF_NO_ARGS"

print_results
