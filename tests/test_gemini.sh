#!/bin/bash
# Gemini API integration tests.
#
# Requires GEMINI_API_KEY to be set (from .env.local or the environment).
# Tests perform real API calls to verify:
#   - call_gemini works end-to-end with a valid key
#   - All three build_gemini_*_prompt functions produce usable prompts
#   - Error paths return non-zero without crashing
#
# Network access required; no Docker needed.
set -eo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/helpers.sh"
source "$REPO_DIR/lib/launch-lib.sh"

# Load .env.local from the repo root if it exists (contains GEMINI_API_KEY)
[ -f "$REPO_DIR/.env.local" ] && source "$REPO_DIR/.env.local"

# ---------------------------------------------------------------------------
suite "Gemini prerequisites"
# ---------------------------------------------------------------------------

if [ -z "${GEMINI_API_KEY:-}" ]; then
    skip "GEMINI_API_KEY not set — add it to .env.local or export it before running"
    print_results
    exit 0
fi
echo "  ✅ GEMINI_API_KEY is set"
TEST_PASS=$(( TEST_PASS + 1 ))

# ---------------------------------------------------------------------------
# Shared temp files (cleaned up on exit)
# ---------------------------------------------------------------------------
PROMPT_FILE=$(mktemp)
OUTPUT_FILE=$(mktemp)
trap 'rm -f "$PROMPT_FILE" "$OUTPUT_FILE"' EXIT

# ---------------------------------------------------------------------------
suite "call_gemini — basic success path"
# ---------------------------------------------------------------------------

printf 'Reply with exactly one word: "pong"' > "$PROMPT_FILE"

set +e
call_gemini "$PROMPT_FILE" "$OUTPUT_FILE"
RC=$?
set -e

assert_equals "valid key: returns 0" "0" "$RC"

RESPONSE=$(cat "$OUTPUT_FILE")
assert_equals "response is non-empty" "true" "$([ -n "$RESPONSE" ] && echo true || echo false)"
assert_contains "response contains expected word" "pong" "$(echo "$RESPONSE" | tr '[:upper:]' '[:lower:]')"

# ---------------------------------------------------------------------------
suite "call_gemini — error paths"
# ---------------------------------------------------------------------------

# Invalid / wrong key
INVALID_OUT=$(mktemp)
set +e
GEMINI_API_KEY="invalid-key-$$" call_gemini "$PROMPT_FILE" "$INVALID_OUT"
INVALID_RC=$?
set -e
assert_equals "invalid key: returns non-zero" "1" "$INVALID_RC"
INVALID_CONTENT=""
[ -s "$INVALID_OUT" ] && INVALID_CONTENT=$(cat "$INVALID_OUT")
assert_equals "invalid key: output file stays empty" "" "$INVALID_CONTENT"
rm -f "$INVALID_OUT"

# Empty / missing key
EMPTY_OUT=$(mktemp)
set +e
GEMINI_API_KEY="" call_gemini "$PROMPT_FILE" "$EMPTY_OUT"
EMPTY_RC=$?
set -e
assert_equals "empty key: returns non-zero" "1" "$EMPTY_RC"
rm -f "$EMPTY_OUT"

# Non-existent prompt file
BADPATH_OUT=$(mktemp)
set +e
call_gemini "/nonexistent/prompt_file_$$.txt" "$BADPATH_OUT"
BADPATH_RC=$?
set -e
assert_equals "missing prompt file: returns non-zero" "1" "$BADPATH_RC"
rm -f "$BADPATH_OUT"

# ---------------------------------------------------------------------------
suite "build_gemini_architectural_prompt → call_gemini round-trip"
# ---------------------------------------------------------------------------

ARCH_CANDS=$(mktemp)
cat > "$ARCH_CANDS" << 'EOF'
## Option A: Flat Files
Summary: store data as JSON on disk
## Option B: SQLite
Summary: embed SQLite for structured queries
## Option C: REST API
Summary: call an external service
EOF

build_gemini_architectural_prompt "add persistence to a todo list" "$ARCH_CANDS" > "$PROMPT_FILE"

# Verify the prompt itself looks sane before sending
PROMPT_CONTENT=$(cat "$PROMPT_FILE")
assert_contains "arch prompt: task embedded" "add persistence to a todo list" "$PROMPT_CONTENT"
assert_contains "arch prompt: candidates embedded" "Flat Files" "$PROMPT_CONTENT"
assert_contains "arch prompt: adversarial framing" "adversarial" "$PROMPT_CONTENT"

# Real API call
ARCH_OUT=$(mktemp)
set +e
call_gemini "$PROMPT_FILE" "$ARCH_OUT"
ARCH_RC=$?
set -e

assert_equals "arch round-trip: returns 0" "0" "$ARCH_RC"

ARCH_RESP=$(cat "$ARCH_OUT")
assert_equals "arch round-trip: response is non-empty" "true" "$([ -n "$ARCH_RESP" ] && echo true || echo false)"
# Gemini should critique each option — expect the word for at least one option name
assert_contains "arch round-trip: response mentions options" "Option" "$ARCH_RESP"


rm -f "$ARCH_CANDS" "$ARCH_OUT"

# ---------------------------------------------------------------------------
suite "build_gemini_qa_prompt → call_gemini round-trip"
# ---------------------------------------------------------------------------

QA_PAYLOAD=$(mktemp)
cat > "$QA_PAYLOAD" << 'PYEOF'
--- src/auth.py ---
def login(username, password):
    if not username or not password:
        raise ValueError("credentials required")
    return username == "admin" and password == "secret"

--- tests/test_auth.py ---
import pytest
from src.auth import login

def test_login_success():
    assert login("admin", "secret") is True

def test_login_fail():
    assert login("user", "wrong") is False
PYEOF

build_gemini_qa_prompt "improve test coverage of the auth module" "$QA_PAYLOAD" > "$PROMPT_FILE"

QA_PROMPT=$(cat "$PROMPT_FILE")
assert_contains "qa prompt: scope embedded" "improve test coverage" "$QA_PROMPT"
assert_contains "qa prompt: source code embedded" "login" "$QA_PROMPT"
assert_contains "qa prompt: Red Team framing" "Red Team" "$QA_PROMPT"

QA_OUT=$(mktemp)
set +e
call_gemini "$PROMPT_FILE" "$QA_OUT"
QA_RC=$?
set -e

assert_equals "qa round-trip: returns 0" "0" "$QA_RC"

QA_RESP=$(cat "$QA_OUT")
assert_equals "qa round-trip: response is non-empty" "true" "$([ -n "$QA_RESP" ] && echo true || echo false)"
# Expect at least one numbered item in the missing-coverage list
assert_contains "qa round-trip: response contains numbered items" "1." "$QA_RESP"


rm -f "$QA_PAYLOAD" "$QA_OUT"

# ---------------------------------------------------------------------------
suite "build_gemini_refactor_prompt → call_gemini round-trip"
# ---------------------------------------------------------------------------

RF_CTX=$(mktemp)
cat > "$RF_CTX" << 'EOF'
Task: fix race condition in BoundedQueue.put()
Error: AssertionError: Queue exceeded maxsize=10 during concurrent puts
Stack: test_concurrent_puts_never_exceed_maxsize FAILED
Diff:
-    if len(self._items) >= self.maxsize:
-        raise Full(...)
-    with self._lock:
-        self._items.append(item)
+    with self._lock:
+        if len(self._items) >= self.maxsize:
+            raise Full(...)
+        self._items.append(item)
EOF

build_gemini_refactor_prompt "fix race condition in BoundedQueue" "$RF_CTX" > "$PROMPT_FILE"

RF_PROMPT=$(cat "$PROMPT_FILE")
assert_contains "refactor prompt: task embedded" "fix race condition" "$RF_PROMPT"
assert_contains "refactor prompt: error embedded" "AssertionError" "$RF_PROMPT"
assert_contains "refactor prompt: diff embedded" "self._lock" "$RF_PROMPT"
assert_contains "refactor prompt: autonomous agent framing" "autonomous" "$RF_PROMPT"

RF_OUT=$(mktemp)
set +e
call_gemini "$PROMPT_FILE" "$RF_OUT"
RF_RC=$?
set -e

assert_equals "refactor round-trip: returns 0" "0" "$RF_RC"

RF_RESP=$(cat "$RF_OUT")
assert_equals "refactor round-trip: response is non-empty" "true" "$([ -n "$RF_RESP" ] && echo true || echo false)"
# Response should contain diagnostic language
LOWER_RESP=$(echo "$RF_RESP" | tr '[:upper:]' '[:lower:]')
assert_contains "refactor round-trip: mentions lock or atomic" "lock" "$LOWER_RESP"

rm -f "$RF_CTX" "$RF_OUT"

# ---------------------------------------------------------------------------
suite "build_gemini prompts — CLAUDE.md inclusion"
# ---------------------------------------------------------------------------

CLAUDEN_DIR=$(mktemp -d)
cat > "$CLAUDEN_DIR/CLAUDE.md" << 'EOF'
# My Project
Build: make test
Language: Go 1.22
EOF

CANDS_FOR_CONTEXT=$(mktemp)
printf 'Option A: microservices\nOption B: monolith\n' > "$CANDS_FOR_CONTEXT"

(
    cd "$CLAUDEN_DIR"
    build_gemini_architectural_prompt "refactor the API layer" "$CANDS_FOR_CONTEXT" > "$PROMPT_FILE"
)

CONTEXT_PROMPT=$(cat "$PROMPT_FILE")
assert_contains "CLAUDE.md: project context section present" "PROJECT CONTEXT" "$CONTEXT_PROMPT"
assert_contains "CLAUDE.md: build command embedded" "make test" "$CONTEXT_PROMPT"
assert_contains "CLAUDE.md: language embedded" "Go 1.22" "$CONTEXT_PROMPT"

rm -f "$CANDS_FOR_CONTEXT"
rm -rf "$CLAUDEN_DIR"

print_results
