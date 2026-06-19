#!/bin/bash
# Extended unit tests for lib/launch-lib.sh.
# Complements test_pipelines.sh, test_argument_parsing.sh, test_model_tiers.sh,
# test_strip_ansi.sh, and test_build_prompt.sh with deeper coverage of edge cases
# and behaviours not yet exercised elsewhere.  No Docker or network required.
set -eo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/helpers.sh"
source "$REPO_DIR/lib/launch-lib.sh"

# ==============================================================================
suite "parse_args — special characters in task"
# ==============================================================================

parse_args "fix the login: it fails on UTF-8 names"
assert_equals "task with colon preserved" "fix the login: it fails on UTF-8 names" "$ORIGINAL_TASK_PROMPT"

parse_args "add 'single-quoted' feature"
assert_contains "task with quotes preserved" "single-quoted" "$ORIGINAL_TASK_PROMPT"

parse_args "task with   extra   spaces"
assert_equals "internal spaces preserved" "task with   extra   spaces" "$ORIGINAL_TASK_PROMPT"

# ==============================================================================
suite "parse_model_tier — boundary and substring matching"
# ==============================================================================

parse_model_tier "claude-haiku-4-5-20251001"
assert_equals "full haiku model string: MAX_MINUTES=15" "15" "$MAX_MINUTES"

parse_model_tier "claude-sonnet-4-6"
assert_equals "sonnet model: MAX_MINUTES=10" "10" "$MAX_MINUTES"
assert_equals "sonnet model: MAX_THINKING_TOKENS=10000" "10000" "$MAX_THINKING_TOKENS"

parse_model_tier "claude-opus-4-8"
assert_equals "opus model: MAX_MINUTES=5" "5" "$MAX_MINUTES"
assert_equals "opus model: MAX_RETRIES=2" "2" "$MAX_RETRIES"

parse_model_tier "claude-fable-5"
assert_equals "fable model: MAX_MINUTES=4" "4" "$MAX_MINUTES"
assert_equals "fable model: MAX_THINKING_TOKENS=0" "0" "$MAX_THINKING_TOKENS"

parse_model_tier "totally-unknown-model"
assert_equals "unknown model: falls back to sonnet defaults" "10" "$MAX_MINUTES"
assert_equals "unknown model: falls back to sonnet context" "80000" "$MAX_CONTEXT_TOKENS"

# ==============================================================================
suite "strip_ansi — additional escape sequences"
# ==============================================================================

TMPF=$(mktemp)
trap 'rm -f "$TMPF"' RETURN

# Cursor movement sequences (CSI codes used by Claude Code's TUI)
printf '\033[2Jhello\033[0m world\r\n' > "$TMPF"
OUT=$(strip_ansi "$TMPF")
assert_contains "cursor-clear sequence stripped" "hello world" "$OUT"
assert_not_contains "CSI J code absent from output" "[2J" "$OUT"

# Bold / colour sequences
printf '\033[1;32mGREEN\033[0m text\n' > "$TMPF"
OUT=$(strip_ansi "$TMPF")
assert_contains "colour stripped: text remains" "GREEN text" "$OUT"
assert_not_contains "colour stripped: escape absent" "[32m" "$OUT"

# Carriage returns (Windows-style CRLF)
printf 'line one\r\nline two\r\n' > "$TMPF"
OUT=$(strip_ansi "$TMPF")
assert_not_contains "carriage returns removed" $'\r' "$OUT"

rm -f "$TMPF"

# ==============================================================================
suite "build_prompt_with_advice — edge cases"
# ==============================================================================

# Empty advice should produce the base prompt unchanged
GEMINI_ADVICE_TEXT=""
OUT=$(build_prompt_with_advice "base task prompt")
assert_equals "empty advice: output equals base task" "base task prompt" "$OUT"

# Non-empty advice must prepend the delimiter block
GEMINI_ADVICE_TEXT="Use async I/O everywhere"
OUT=$(build_prompt_with_advice "base task prompt")
assert_contains "non-empty advice: advice text present" "Use async I/O everywhere" "$OUT"
assert_contains "non-empty advice: base task still present" "base task prompt" "$OUT"
assert_contains "non-empty advice: advice precedes task" "GEMINI ARCHITECT ADVICE" "$OUT"

# Advice with special characters (newlines, colons, brackets)
GEMINI_ADVICE_TEXT="Step 1: check [logs]\nStep 2: fix it"
OUT=$(build_prompt_with_advice "fix the bug")
assert_contains "special chars in advice: preserved" "Step 1: check [logs]" "$OUT"

GEMINI_ADVICE_TEXT=""

# ==============================================================================
suite "decision_log_init — directory creation and header fields"
# ==============================================================================

DEEP_DIR=$(mktemp -d)
DEEP_FILE="$DEEP_DIR/nested/path/to/log.md"
decision_log_init "$DEEP_FILE" "refactor" "fix the queue bug" "claude-haiku-4-5"
assert_file_exists "nested directory created" "$DEEP_FILE"

CONTENT=$(cat "$DEEP_FILE")
assert_contains "deep init: pipeline in header" "refactor" "$CONTENT"
assert_contains "deep init: task in body" "fix the queue bug" "$CONTENT"
assert_contains "deep init: model in header" "claude-haiku-4-5" "$CONTENT"
assert_contains "deep init: status starts in-progress" "in-progress" "$CONTENT"
assert_contains "deep init: date stamp present" "$(date '+%Y-%m-%d')" "$CONTENT"

# Empty task string should not crash
DL_EMPTY=$(mktemp)
decision_log_init "$DL_EMPTY" "qa" "" "claude-sonnet-4-6"
EMPTY_CONTENT=$(cat "$DL_EMPTY")
assert_contains "empty task: file created" "Pipeline" "$EMPTY_CONTENT"
rm -f "$DL_EMPTY"

rm -rf "$DEEP_DIR"

# ==============================================================================
suite "decision_log_section — ordering and multiple sections"
# ==============================================================================

MULTI_LOG=$(mktemp)
decision_log_init "$MULTI_LOG" "architect" "multi section test" "claude-sonnet-4-6"

TMP1=$(mktemp); printf 'Phase 1 output content' > "$TMP1"
TMP2=$(mktemp); printf 'Phase 2 output content' > "$TMP2"

decision_log_section "$MULTI_LOG" "Phase 1: Candidates" "$TMP1"
decision_log_section "$MULTI_LOG" "Phase 2: Selection"  "$TMP2"

ML=$(cat "$MULTI_LOG")
assert_contains "multi-section: phase 1 header present" "Phase 1: Candidates" "$ML"
assert_contains "multi-section: phase 1 content present" "Phase 1 output content" "$ML"
assert_contains "multi-section: phase 2 header present" "Phase 2: Selection" "$ML"
assert_contains "multi-section: phase 2 content present" "Phase 2 output content" "$ML"

# Phase 1 must appear before Phase 2 in the file
P1_LINE=$(grep -n "Phase 1" "$MULTI_LOG" | head -1 | cut -d: -f1)
P2_LINE=$(grep -n "Phase 2" "$MULTI_LOG" | head -1 | cut -d: -f1)
assert_equals "phase 1 appears before phase 2" "true" "$([ "$P1_LINE" -lt "$P2_LINE" ] && echo true || echo false)"

# Calling section on a nonexistent log should be a no-op (no crash)
set +e
decision_log_section "/nonexistent/log_$$.md" "Should not crash" "$TMP1"
NO_CRASH_RC=$?
set -e
assert_equals "section on missing log: no crash" "0" "$NO_CRASH_RC"

rm -f "$MULTI_LOG" "$TMP1" "$TMP2"

# ==============================================================================
suite "decision_log_note — multiline text and no-op on missing file"
# ==============================================================================

NOTE_LOG=$(mktemp)
decision_log_init "$NOTE_LOG" "qa" "note test" "claude-sonnet-4-6"

MULTILINE="Line one.\nLine two.\nLine three."
decision_log_note "$NOTE_LOG" "My Notes" "$MULTILINE"
NL=$(cat "$NOTE_LOG")
assert_contains "multiline note: section header" "My Notes" "$NL"
assert_contains "multiline note: text embedded" "Line one." "$NL"

# No-op on missing file
set +e
decision_log_note "/nonexistent/log_$$.md" "Header" "text"
NOTE_RC=$?
set -e
assert_equals "note on missing log: returns 0" "0" "$NOTE_RC"

rm -f "$NOTE_LOG"

# ==============================================================================
suite "decision_log_outcome — multiple calls and special status values"
# ==============================================================================

OUTCOME_LOG=$(mktemp)
decision_log_init "$OUTCOME_LOG" "refactor" "outcome edge cases" "claude-opus-4-8"

decision_log_outcome "$OUTCOME_LOG" "success"
OC=$(cat "$OUTCOME_LOG")
assert_contains "success: Outcome section added" "Outcome" "$OC"
assert_contains "success: status in outcome" "success" "$OC"
assert_not_contains "success: no lingering in-progress" "**Status:** in-progress" "$OC"

# Calling outcome a second time should append (not corrupt the file)
decision_log_outcome "$OUTCOME_LOG" "amended"
OC2=$(cat "$OUTCOME_LOG")
assert_contains "second outcome: amended status present" "amended" "$OC2"
assert_contains "second outcome: success section still present" "success" "$OC2"

# No notes argument should not append a blank line with unexpected content
NONNOTE_LOG=$(mktemp)
decision_log_init "$NONNOTE_LOG" "qa" "no notes" "claude-sonnet-4-6"
decision_log_outcome "$NONNOTE_LOG" "success"
NN=$(cat "$NONNOTE_LOG")
assert_contains "no-notes outcome: Outcome header present" "Outcome" "$NN"

rm -f "$OUTCOME_LOG" "$NONNOTE_LOG"

# ==============================================================================
suite "build_gemini prompts — CLAUDE.md embedding"
# ==============================================================================

CLAUDE_TMPDIR=$(mktemp -d)
trap 'rm -rf "$CLAUDE_TMPDIR"' RETURN

# Create a CLAUDE.md in the temp dir and test from there
cat > "$CLAUDE_TMPDIR/CLAUDE.md" << 'CEOF'
# Test Project Context
Build: pytest -v
Architecture: monorepo
CEOF

FAKE_CANDIDATES=$(mktemp)
printf 'Option A: simple\nOption B: complex\n' > "$FAKE_CANDIDATES"

FAKE_PAYLOAD=$(mktemp)
printf 'def login(): pass\n' > "$FAKE_PAYLOAD"

FAKE_CONTEXT=$(mktemp)
printf 'Task: fix bug\nError: NullPointerException\n' > "$FAKE_CONTEXT"

# Run prompt builders from the temp dir (so CLAUDE.md is in CWD)
(
    cd "$CLAUDE_TMPDIR"
    ARCH_OUT=$(build_gemini_architectural_prompt "add feature" "$FAKE_CANDIDATES")
    printf '%s' "$ARCH_OUT" > /tmp/arch_out_$$.txt

    QA_OUT=$(build_gemini_qa_prompt "test auth" "$FAKE_PAYLOAD")
    printf '%s' "$QA_OUT" > /tmp/qa_out_$$.txt

    RF_OUT=$(build_gemini_refactor_prompt "fix bug" "$FAKE_CONTEXT")
    printf '%s' "$RF_OUT" > /tmp/rf_out_$$.txt
)

ARCH_OUT=$(cat /tmp/arch_out_$$.txt)
QA_OUT=$(cat /tmp/qa_out_$$.txt)
RF_OUT=$(cat /tmp/rf_out_$$.txt)
rm -f /tmp/arch_out_$$.txt /tmp/qa_out_$$.txt /tmp/rf_out_$$.txt

assert_contains "arch prompt: CLAUDE.md content embedded" "Test Project Context" "$ARCH_OUT"
assert_contains "arch prompt: Build command embedded" "pytest -v" "$ARCH_OUT"

assert_contains "qa prompt: CLAUDE.md content embedded" "Test Project Context" "$QA_OUT"

assert_contains "refactor prompt: CLAUDE.md content embedded" "Test Project Context" "$RF_OUT"

rm -f "$FAKE_CANDIDATES" "$FAKE_PAYLOAD" "$FAKE_CONTEXT"
rm -rf "$CLAUDE_TMPDIR"

# ==============================================================================
suite "build_gemini prompts — no CLAUDE.md does not crash"
# ==============================================================================

NOCLAUDE_DIR=$(mktemp -d)
FAKE_CANDS2=$(mktemp)
printf 'Option X\n' > "$FAKE_CANDS2"
(
    cd "$NOCLAUDE_DIR"
    OUT2=$(build_gemini_architectural_prompt "some task" "$FAKE_CANDS2")
    printf '%s' "$OUT2" > /tmp/noclaude_out_$$.txt
)
OUT2=$(cat /tmp/noclaude_out_$$.txt)
rm -f /tmp/noclaude_out_$$.txt "$FAKE_CANDS2"
rm -rf "$NOCLAUDE_DIR"

assert_contains "no CLAUDE.md: task still in output" "some task" "$OUT2"
assert_contains "no CLAUDE.md: candidates still in output" "Option X" "$OUT2"
assert_not_contains "no CLAUDE.md: no PROJECT CONTEXT section" "PROJECT CONTEXT" "$OUT2"

# ==============================================================================
suite "CLAUDE_SANDBOX_IMAGE — run_headless_phase uses env override"
# ==============================================================================

# Create a real mock 'docker' executable on a temp PATH so 'timeout' can find it
# (exported shell functions are invisible to external commands like timeout).
MOCK_DOCKER_DIR=$(mktemp -d)
DOCKER_LOG=$(mktemp)
# Write the actual path of DOCKER_LOG into the script so it's self-contained.
cat > "$MOCK_DOCKER_DIR/docker" << MOCKEOF
#!/bin/bash
printf 'DOCKER_ARGS: %s\n' "\$*" >> "$DOCKER_LOG"
exit 0
MOCKEOF
chmod +x "$MOCK_DOCKER_DIR/docker"

# Prepend mock dir to PATH so timeout finds our stub first.
_SAVED_PATH="$PATH"
PATH="$MOCK_DOCKER_DIR:$PATH"

OAUTH_TOKEN="fake-token"
OAUTH_REFRESH="fake-refresh"

# With CLAUDE_SANDBOX_IMAGE unset, should default to 'claude-sandbox'
unset CLAUDE_SANDBOX_IMAGE
set +e
run_headless_phase "test-container" "claude-haiku-4-5" "1" "echo test" 2>/dev/null
set -e
DEFAULT_CALLS=$(cat "$DOCKER_LOG")
assert_contains "default image: claude-sandbox used" "claude-sandbox" "$DEFAULT_CALLS"
assert_not_contains "default image: mock image not used" "claude-sandbox-mock" "$DEFAULT_CALLS"

# With CLAUDE_SANDBOX_IMAGE set, should use the override
> "$DOCKER_LOG"
set +e
CLAUDE_SANDBOX_IMAGE="claude-sandbox-mock" \
    run_headless_phase "test-container-2" "claude-haiku-4-5" "1" "echo test" 2>/dev/null
set -e
MOCK_CALLS=$(cat "$DOCKER_LOG")
assert_contains "image override: mock image used" "claude-sandbox-mock" "$MOCK_CALLS"
assert_not_contains "image override: default image absent" " claude-sandbox " "$MOCK_CALLS"

# run_headless_phase must pass the model flag
assert_contains "model flag passed to docker" "--model claude-haiku-4-5" "$MOCK_CALLS"

# run_headless_phase must pass --dangerously-skip-permissions
assert_contains "permissions flag passed" "dangerously-skip-permissions" "$MOCK_CALLS"

# With MOCK_CLAUDE_EXIT set, it must be forwarded as a docker -e flag
> "$DOCKER_LOG"
set +e
CLAUDE_SANDBOX_IMAGE="claude-sandbox-mock" MOCK_CLAUDE_EXIT=1 \
    run_headless_phase "test-container-3" "claude-haiku-4-5" "1" "echo test" 2>/dev/null
set -e
EXIT_CALLS=$(cat "$DOCKER_LOG")
assert_contains "MOCK_CLAUDE_EXIT propagated to docker" "MOCK_CLAUDE_EXIT=1" "$EXIT_CALLS"

# Without MOCK_CLAUDE_EXIT, it must NOT appear in the docker args
> "$DOCKER_LOG"
unset MOCK_CLAUDE_EXIT
set +e
CLAUDE_SANDBOX_IMAGE="claude-sandbox-mock" \
    run_headless_phase "test-container-4" "claude-haiku-4-5" "1" "echo test" 2>/dev/null
set -e
NO_EXIT_CALLS=$(cat "$DOCKER_LOG")
assert_not_contains "MOCK_CLAUDE_EXIT absent when unset" "MOCK_CLAUDE_EXIT" "$NO_EXIT_CALLS"

PATH="$_SAVED_PATH"
rm -f "$DOCKER_LOG"
rm -rf "$MOCK_DOCKER_DIR"

# ==============================================================================
suite "feature slug generation — pipeline script inline logic"
# ==============================================================================

# Test the slug pipeline used inside the three pipeline scripts.
# Extract it here so edge cases can be checked without running the full script.
make_slug() {
    printf '%s' "$1" \
        | tr '[:upper:]' '[:lower:]' \
        | tr -cs 'a-z0-9' '-' \
        | sed 's/-\{2,\}/-/g; s/^-//; s/-$//' \
        | cut -c1-40 \
        | sed 's/-$//'
}

assert_equals "slug: basic lowercase" "add-a-feature" "$(make_slug 'Add a Feature')"
assert_equals "slug: strips leading/trailing hyphens" "fix-queue-bug" "$(make_slug '  fix queue bug  ')"
assert_equals "slug: collapses consecutive separators" "fix-auth" "$(make_slug 'fix   auth!!!')"
assert_equals "slug: strips non-alphanumeric" "hello-world" "$(make_slug 'hello, world!')"
LONG_SLUG_INPUT=$(python3 -c "print('a'*60)")
LONG_SLUG=$(make_slug "$LONG_SLUG_INPUT")
assert_equals "slug: max 40 chars" "40" "${#LONG_SLUG}"

# Slug must not end with a hyphen after truncation
LONG_SLUG=$(make_slug "add some really long feature description that goes past forty chars")
LAST_CHAR="${LONG_SLUG: -1}"
assert_not_contains "slug: no trailing hyphen after truncation" "-" "$LAST_CHAR"

print_results
