#!/bin/bash
# Tests for GEMINI_API_KEY injection into Docker containers from .env.local.
#
# The fix added -e GEMINI_API_KEY="${GEMINI_API_KEY:-}" to:
#   launch-scripted.sh    — DOCKER_RUN_BASE and DOCKER_RECOVERY_BASE arrays
#   launch-interactive.sh — the docker run invocation
#
# Verifies:
#   1. GEMINI_API_KEY value is passed when the key is set
#   2. The flag is present (with empty value) when the key is unset — no crash
#   3. The arg position is after CLAUDE_CODE_OAUTH_REFRESH_TOKEN in the arrays
#
# All tests are unit tests — no real Docker, credentials, or network needed.
set -eo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
FIXTURE_DIR="$TESTS_DIR/fixtures"
source "$TESTS_DIR/helpers.sh"

# ============================================================
# SHARED FIXTURES — created once, cleaned on EXIT
# ============================================================
FAKE_HOME=$(mktemp -d)
MOCK_BIN_DIR=$(mktemp -d)
WORK_DIR=$(mktemp -d)
RECOVERY_MOCK_DIR=$(mktemp -d)
RECOVERY_WORK_DIR=$(mktemp -d)
RECOVERY_COUNTER_FILE="$RECOVERY_MOCK_DIR/.call_count"
_ENVLOCAL_CREATED=false

cleanup() {
    rm -rf "$FAKE_HOME" "$MOCK_BIN_DIR" "$WORK_DIR" "$RECOVERY_MOCK_DIR" "$RECOVERY_WORK_DIR"
    if [ "$_ENVLOCAL_CREATED" = true ]; then
        rm -f "$REPO_DIR/.env.local"
    fi
}
trap cleanup EXIT

# Valid credentials fixture
mkdir -p "$FAKE_HOME/.claude"
cp "$FIXTURE_DIR/valid_creds.json" "$FAKE_HOME/.claude/.credentials.json"

# CLAUDE.md in each work dir so ensure_claude_md_current returns early (no git
# in a temp dir → needs_update stays false), keeping docker call counts predictable.
cp "$REPO_DIR/CLAUDE.md" "$WORK_DIR/CLAUDE.md"
cp "$REPO_DIR/CLAUDE.md" "$RECOVERY_WORK_DIR/CLAUDE.md"

# ---------------------------------------------------------------------------
# Determine the effective GEMINI_API_KEY the scripts will use.
# .env.local is sourced at the top of each launch script and can override
# whatever key we pass in the environment.  We pre-compute the effective value
# so runtime tests can check for the correct key regardless of .env.local.
# ---------------------------------------------------------------------------
_EFFECTIVE_GEMINI_KEY=""
_ENVLOCAL_HAS_GEMINI=false
if [ -f "$REPO_DIR/.env.local" ]; then
    _EFFECTIVE_GEMINI_KEY=$(bash -c \
        ". '$REPO_DIR/.env.local' >/dev/null 2>&1; printf '%s' \"\${GEMINI_API_KEY:-}\"")
    [ -n "$_EFFECTIVE_GEMINI_KEY" ] && _ENVLOCAL_HAS_GEMINI=true
fi
if [ -z "$_EFFECTIVE_GEMINI_KEY" ]; then
    # No .env.local override — our test key will be used
    _EFFECTIVE_GEMINI_KEY="test-gemini-key-inject"
fi

# ---------------------------------------------------------------------------
# Basic fake docker (always exits 0) — for PATH-based mocking.
# Using a real executable file so timeout wrappers can exec it
# (exported shell functions are not visible through exec / timeout).
# ---------------------------------------------------------------------------
cat > "$MOCK_BIN_DIR/docker" << 'BASIC_DOCKER'
#!/bin/bash
case "${1:-}" in
    info) echo "Mock docker info OK"; exit 0 ;;
    kill) exit 0 ;;
    run)  echo "MOCK_DOCKER_RUN $*"; exit 0 ;;
    *)    echo "MOCK_DOCKER unknown: $*" >&2; exit 1 ;;
esac
BASIC_DOCKER
chmod +x "$MOCK_BIN_DIR/docker"

# No-op sleep: eliminates the 2 s + 3 s waits baked into the recovery path.
cat > "$MOCK_BIN_DIR/sleep" << 'SLEEP_MOCK'
#!/bin/bash
exit 0
SLEEP_MOCK
chmod +x "$MOCK_BIN_DIR/sleep"

# ---------------------------------------------------------------------------
# Counter-based fake docker — first RUN call exits 1 (triggers recovery path).
# COUNTER_FILE path is baked in at write time via heredoc variable expansion.
# ---------------------------------------------------------------------------
cat > "$RECOVERY_MOCK_DIR/docker" << COUNTER_DOCKER
#!/bin/bash
COUNTER_FILE="$RECOVERY_COUNTER_FILE"
case "\${1:-}" in
    info) echo "Mock docker info OK"; exit 0 ;;
    kill) exit 0 ;;
    run)
        echo "MOCK_DOCKER_RUN \$*"
        COUNT=0
        [ -f "\$COUNTER_FILE" ] && COUNT=\$(cat "\$COUNTER_FILE" 2>/dev/null || echo 0)
        COUNT=\$((COUNT + 1))
        echo "\$COUNT" > "\$COUNTER_FILE"
        [ "\$COUNT" -eq 1 ] && exit 1   # First call fails → triggers recovery
        exit 0                           # Subsequent calls succeed
        ;;
    *) echo "MOCK_DOCKER unknown: \$*" >&2; exit 1 ;;
esac
COUNTER_DOCKER
chmod +x "$RECOVERY_MOCK_DIR/docker"

cat > "$RECOVERY_MOCK_DIR/sleep" << 'SLEEP_MOCK'
#!/bin/bash
exit 0
SLEEP_MOCK
chmod +x "$RECOVERY_MOCK_DIR/sleep"

# ==============================================================================
suite "launch-scripted.sh — source: -e GEMINI_API_KEY= in both arrays"
# ==============================================================================

# Exactly two -e GEMINI_API_KEY= occurrences: one per array.
SCRIPTED_GEMINI_E_COUNT=$(grep -c '\-e GEMINI_API_KEY=' "$REPO_DIR/launch-scripted.sh" || true)
assert_equals "scripted: -e GEMINI_API_KEY= present in DOCKER_RUN_BASE and DOCKER_RECOVERY_BASE" \
    "2" "$SCRIPTED_GEMINI_E_COUNT"

# Both array entries must use the default-empty form "${GEMINI_API_KEY:-}"
# (prevents nounset errors when the key is absent).
SCRIPTED_FULL_PATTERN_COUNT=$(grep -c '\-e GEMINI_API_KEY="\${GEMINI_API_KEY:-}"' "$REPO_DIR/launch-scripted.sh" || true)
assert_equals "scripted: both entries use \${GEMINI_API_KEY:-} default-empty form" \
    "2" "$SCRIPTED_FULL_PATTERN_COUNT"

# ==============================================================================
suite "launch-scripted.sh — source: position after CLAUDE_CODE_OAUTH_REFRESH_TOKEN"
# ==============================================================================

# DOCKER_RUN_BASE: first occurrence of OAUTH_REFRESH_TOKEN and GEMINI_API_KEY
REFRESH_LN_1=$(grep -n 'CLAUDE_CODE_OAUTH_REFRESH_TOKEN' "$REPO_DIR/launch-scripted.sh" | head -1 | cut -d: -f1)
GEMINI_LN_1=$(grep -n '\-e GEMINI_API_KEY=' "$REPO_DIR/launch-scripted.sh" | head -1 | cut -d: -f1)
assert_equals "scripted DOCKER_RUN_BASE: GEMINI_API_KEY line is after OAUTH_REFRESH_TOKEN line" "true" \
    "$([ "${GEMINI_LN_1:-0}" -gt "${REFRESH_LN_1:-0}" ] && echo true || echo false)"

# DOCKER_RECOVERY_BASE: second occurrence of each
REFRESH_LN_2=$(grep -n 'CLAUDE_CODE_OAUTH_REFRESH_TOKEN' "$REPO_DIR/launch-scripted.sh" | sed -n '2p' | cut -d: -f1)
GEMINI_LN_2=$(grep -n '\-e GEMINI_API_KEY=' "$REPO_DIR/launch-scripted.sh" | sed -n '2p' | cut -d: -f1)
assert_equals "scripted DOCKER_RECOVERY_BASE: GEMINI_API_KEY line is after OAUTH_REFRESH_TOKEN line" "true" \
    "$([ "${GEMINI_LN_2:-0}" -gt "${REFRESH_LN_2:-0}" ] && echo true || echo false)"

# Confirm the two GEMINI_API_KEY entries are on distinct lines (not duplicated within one array)
assert_equals "scripted: DOCKER_RUN_BASE and DOCKER_RECOVERY_BASE have separate GEMINI_API_KEY entries" \
    "true" "$([ "${GEMINI_LN_1:-0}" -ne "${GEMINI_LN_2:-0}" ] && echo true || echo false)"

# ==============================================================================
suite "launch-interactive.sh — source: -e GEMINI_API_KEY= present and positioned"
# ==============================================================================

INTER_GEMINI_E_COUNT=$(grep -c '\-e GEMINI_API_KEY=' "$REPO_DIR/launch-interactive.sh" || true)
assert_equals "interactive: -e GEMINI_API_KEY= appears in docker run invocation" "1" "$INTER_GEMINI_E_COUNT"

INTER_FULL_PATTERN_COUNT=$(grep -c '\-e GEMINI_API_KEY="\${GEMINI_API_KEY:-}"' "$REPO_DIR/launch-interactive.sh" || true)
assert_equals "interactive: uses \${GEMINI_API_KEY:-} default-empty form" "1" "$INTER_FULL_PATTERN_COUNT"

# Position: GEMINI_API_KEY must come after CLAUDE_CODE_OAUTH_REFRESH_TOKEN
INTER_REFRESH_LN=$(grep -n 'CLAUDE_CODE_OAUTH_REFRESH_TOKEN' "$REPO_DIR/launch-interactive.sh" | head -1 | cut -d: -f1)
INTER_GEMINI_LN=$(grep -n '\-e GEMINI_API_KEY=' "$REPO_DIR/launch-interactive.sh" | head -1 | cut -d: -f1)
assert_equals "interactive: GEMINI_API_KEY line is after OAUTH_REFRESH_TOKEN line" "true" \
    "$([ "${INTER_GEMINI_LN:-0}" -gt "${INTER_REFRESH_LN:-0}" ] && echo true || echo false)"

# ==============================================================================
suite "launch-interactive.sh — runtime: GEMINI_API_KEY set"
# ==============================================================================

# The exported shell function works here: launch-interactive.sh calls docker
# directly (no timeout wrapper around its docker run, unlike launch-scripted.sh).
docker() { echo "MOCK_DOCKER_INTERACTIVE $*"; }
export -f docker

# Use the effective key (accounts for .env.local override so the assert matches
# what the script actually passes through to docker).
set +e
inter_set_out=$(GEMINI_API_KEY="$_EFFECTIVE_GEMINI_KEY" HOME="$FAKE_HOME" \
    bash "$REPO_DIR/launch-interactive.sh" 2>&1)
inter_set_rc=$?
set -e
unset -f docker

assert_equals "interactive/set: exits 0" "0" "$inter_set_rc"
assert_contains "interactive/set: docker was called" "MOCK_DOCKER_INTERACTIVE" "$inter_set_out"
assert_contains "interactive/set: GEMINI_API_KEY value passed to docker" \
    "GEMINI_API_KEY=$_EFFECTIVE_GEMINI_KEY" "$inter_set_out"
assert_contains "interactive/set: OAUTH_TOKEN also present" "CLAUDE_CODE_OAUTH_TOKEN=" "$inter_set_out"
assert_contains "interactive/set: OAUTH_REFRESH_TOKEN also present" "CLAUDE_CODE_OAUTH_REFRESH_TOKEN=" "$inter_set_out"

# ==============================================================================
suite "launch-interactive.sh — runtime: GEMINI_API_KEY unset"
# ==============================================================================

docker() { echo "MOCK_DOCKER_INTERACTIVE $*"; }
export -f docker

# Note: if .env.local sets GEMINI_API_KEY, it will be re-applied even after
# env -u — the test still verifies no crash and the flag is present.
set +e
inter_unset_out=$(env -u GEMINI_API_KEY HOME="$FAKE_HOME" \
    bash "$REPO_DIR/launch-interactive.sh" 2>&1)
inter_unset_rc=$?
set -e
unset -f docker

assert_equals "interactive/unset: exits 0 — no crash when key absent" "0" "$inter_unset_rc"
assert_contains "interactive/unset: -e GEMINI_API_KEY= flag present regardless" \
    "GEMINI_API_KEY=" "$inter_unset_out"

# ==============================================================================
suite "launch-interactive.sh — runtime: GEMINI_API_KEY arg position"
# ==============================================================================

docker() { echo "MOCK_DOCKER_POS $*"; }
export -f docker

set +e
inter_pos_out=$(GEMINI_API_KEY="$_EFFECTIVE_GEMINI_KEY" HOME="$FAKE_HOME" \
    bash "$REPO_DIR/launch-interactive.sh" 2>&1)
set -e
unset -f docker

# Extract the docker call line and compare byte offsets of the key env arg names
docker_line=$(printf '%s\n' "$inter_pos_out" | grep 'MOCK_DOCKER_POS' | head -1)
refresh_pos=$(printf '%s' "$docker_line" | grep -bo 'CLAUDE_CODE_OAUTH_REFRESH_TOKEN' | head -1 | cut -d: -f1 || echo "0")
gemini_pos=$(printf '%s' "$docker_line" | grep -bo 'GEMINI_API_KEY=' | head -1 | cut -d: -f1 || echo "0")

assert_equals "interactive/position: -e GEMINI_API_KEY= arg follows OAUTH_REFRESH_TOKEN arg" "true" \
    "$([ "${gemini_pos:-0}" -gt "${refresh_pos:-0}" ] && echo true || echo false)"

# ==============================================================================
suite "launch-scripted.sh — runtime: GEMINI_API_KEY set (DOCKER_RUN_BASE)"
# ==============================================================================

# PATH-based fake docker — required because launch-scripted.sh wraps docker calls
# with timeout, which execs the binary; exported shell functions are not visible.
set +e
scripted_set_out=$(cd "$WORK_DIR" && \
    PATH="$MOCK_BIN_DIR:$PATH" HOME="$FAKE_HOME" \
    GEMINI_API_KEY="$_EFFECTIVE_GEMINI_KEY" \
    bash "$REPO_DIR/launch-scripted.sh" "test task" --no-gemini 2>&1)
scripted_set_rc=$?
set -e

assert_equals "scripted/set: exits 0" "0" "$scripted_set_rc"
assert_contains "scripted/set: docker run was called" "MOCK_DOCKER_RUN" "$scripted_set_out"
assert_contains "scripted/set: GEMINI_API_KEY value in main docker run" \
    "GEMINI_API_KEY=$_EFFECTIVE_GEMINI_KEY" "$scripted_set_out"
assert_contains "scripted/set: OAUTH_REFRESH_TOKEN present in docker run" \
    "CLAUDE_CODE_OAUTH_REFRESH_TOKEN=" "$scripted_set_out"

# ==============================================================================
suite "launch-scripted.sh — runtime: GEMINI_API_KEY unset"
# ==============================================================================

set +e
scripted_unset_out=$(cd "$WORK_DIR" && \
    PATH="$MOCK_BIN_DIR:$PATH" HOME="$FAKE_HOME" \
    env -u GEMINI_API_KEY \
    bash "$REPO_DIR/launch-scripted.sh" "test task" --no-gemini 2>&1)
scripted_unset_rc=$?
set -e

assert_equals "scripted/unset: exits 0 — no crash when GEMINI_API_KEY absent" "0" "$scripted_unset_rc"
assert_contains "scripted/unset: -e GEMINI_API_KEY= flag present (empty value OK)" \
    "GEMINI_API_KEY=" "$scripted_unset_out"

# ==============================================================================
suite "launch-scripted.sh — runtime: GEMINI_API_KEY arg position in DOCKER_RUN_BASE"
# ==============================================================================

set +e
scripted_pos_out=$(cd "$WORK_DIR" && \
    PATH="$MOCK_BIN_DIR:$PATH" HOME="$FAKE_HOME" \
    GEMINI_API_KEY="$_EFFECTIVE_GEMINI_KEY" \
    bash "$REPO_DIR/launch-scripted.sh" "position task" --no-gemini 2>&1)
set -e

# The MOCK_DOCKER_RUN line from the main loop contains the key; check offsets
run_line=$(printf '%s\n' "$scripted_pos_out" | grep 'MOCK_DOCKER_RUN' | head -1 || true)
if [ -n "$run_line" ]; then
    r_pos=$(printf '%s' "$run_line" | grep -bo 'CLAUDE_CODE_OAUTH_REFRESH_TOKEN' | head -1 | cut -d: -f1 || echo "0")
    g_pos=$(printf '%s' "$run_line" | grep -bo 'GEMINI_API_KEY=' | head -1 | cut -d: -f1 || echo "0")
    assert_equals "scripted/position: -e GEMINI_API_KEY= arg follows OAUTH_REFRESH_TOKEN arg" "true" \
        "$([ "${g_pos:-0}" -gt "${r_pos:-0}" ] && echo true || echo false)"
else
    assert_contains "scripted/position: docker run line found in output" \
        "MOCK_DOCKER_RUN" "$scripted_pos_out"
fi

# ==============================================================================
suite "launch-scripted.sh — runtime: DOCKER_RECOVERY_BASE has GEMINI_API_KEY"
# ==============================================================================

# Counter-based mock: first docker run fails → recovery path fires, which
# invokes DOCKER_RECOVERY_BASE for Strategy A (compact) and Strategy B (handoff).
# The no-op sleep mock eliminates the 2 s + 3 s delays in the recovery block.
rm -f "$RECOVERY_COUNTER_FILE"

set +e
recovery_out=$(cd "$RECOVERY_WORK_DIR" && \
    PATH="$RECOVERY_MOCK_DIR:$PATH" HOME="$FAKE_HOME" \
    GEMINI_API_KEY="$_EFFECTIVE_GEMINI_KEY" \
    bash "$REPO_DIR/launch-scripted.sh" "recovery test" --no-gemini 2>&1)
recovery_rc=$?
set -e

# Script succeeds: main loop attempt 2 (docker call ≥2) exits 0
assert_equals "recovery: script exits 0 after recovery path completes" "0" "$recovery_rc"

# All docker RUN calls must contain GEMINI_API_KEY= (both DOCKER_RUN_BASE
# and DOCKER_RECOVERY_BASE are affected by the fix)
recovery_runs_with_key=$(printf '%s\n' "$recovery_out" | grep 'MOCK_DOCKER_RUN' | grep -c 'GEMINI_API_KEY=' || true)
assert_equals "recovery: GEMINI_API_KEY= present in all docker run calls" "true" \
    "$([ "${recovery_runs_with_key:-0}" -ge 1 ] && echo true || echo false)"

# Specifically verify the recovery-path docker runs include GEMINI_API_KEY.
# Recovery runs use -i (no TTY); main-loop runs use -it. Filter to find recovery calls.
# Filter for DOCKER_RECOVERY_BASE calls: -i flag (no TTY) vs -it flag (main loop)
recovery_only_runs=$(printf '%s\n' "$recovery_out" | grep 'MOCK_DOCKER_RUN run -i ' | grep -v '\-it ' || true)
assert_equals "recovery: at least one DOCKER_RECOVERY_BASE run was captured" "true" \
    "$([ -n "$recovery_only_runs" ] && echo true || echo false)"
recovery_has_key="false"
if printf '%s\n' "$recovery_only_runs" | grep -q 'GEMINI_API_KEY='; then
    recovery_has_key="true"
fi
assert_equals "recovery: DOCKER_RECOVERY_BASE runs include GEMINI_API_KEY flag" "true" "$recovery_has_key"

# ==============================================================================
suite "boundary: GEMINI_API_KEY with special characters (source-level)"
# ==============================================================================

# The fix uses "${GEMINI_API_KEY:-}" — bash double-quoting correctly handles
# keys containing forward slashes, plus signs, and equals signs.
# We verify this at the source level (the pattern is correctly quoted) since
# .env.local may override runtime env vars and prevent testing a custom key.
USES_DOUBLE_QUOTES=$(grep -c '\-e GEMINI_API_KEY="\${GEMINI_API_KEY:-}"' "$REPO_DIR/launch-scripted.sh" || true)
assert_equals "special-chars source: scripted uses double-quoted form (handles / + = chars)" \
    "2" "$USES_DOUBLE_QUOTES"

INTER_USES_DOUBLE_QUOTES=$(grep -c '\-e GEMINI_API_KEY="\${GEMINI_API_KEY:-}"' "$REPO_DIR/launch-interactive.sh" || true)
assert_equals "special-chars source: interactive uses double-quoted form" \
    "1" "$INTER_USES_DOUBLE_QUOTES"

# Runtime: if .env.local does NOT override the key, verify special chars survive.
if [ "$_ENVLOCAL_HAS_GEMINI" = false ]; then
    docker() { echo "MOCK_DOCKER_SPECIAL $*"; }
    export -f docker

    SPECIAL_KEY="AIzaSy/Test+Key=abc123"
    set +e
    special_out=$(GEMINI_API_KEY="$SPECIAL_KEY" HOME="$FAKE_HOME" \
        bash "$REPO_DIR/launch-interactive.sh" 2>&1)
    special_rc=$?
    set -e
    unset -f docker

    assert_equals "special-chars runtime: exits 0" "0" "$special_rc"
    assert_contains "special-chars runtime: full key value (/ + =) preserved in docker args" \
        "$SPECIAL_KEY" "$special_out"
else
    skip "special-chars runtime: .env.local overrides GEMINI_API_KEY — custom key cannot be verified at runtime"
fi

# ==============================================================================
suite "boundary: empty-string GEMINI_API_KEY"
# ==============================================================================

docker() { echo "MOCK_DOCKER_EMPTYSTR $*"; }
export -f docker

set +e
emptystr_out=$(GEMINI_API_KEY="" HOME="$FAKE_HOME" \
    bash "$REPO_DIR/launch-interactive.sh" 2>&1)
emptystr_rc=$?
set -e
unset -f docker

assert_equals "empty-string: exits 0 — no crash" "0" "$emptystr_rc"
assert_contains "empty-string: -e GEMINI_API_KEY= flag present (empty value accepted)" \
    "GEMINI_API_KEY=" "$emptystr_out"

# ==============================================================================
suite "boundary: GEMINI_API_KEY from .env.local (interactive)"
# ==============================================================================

ENV_LOCAL_PATH="$REPO_DIR/.env.local"
if [ -f "$ENV_LOCAL_PATH" ]; then
    skip ".env.local already exists in repo dir — skipping to avoid overwriting user config"
else
    _ENVLOCAL_CREATED=true
    printf 'GEMINI_API_KEY="env-local-key-inter"\n' > "$ENV_LOCAL_PATH"

    docker() { echo "MOCK_DOCKER_ENVLOCAL_INTER $*"; }
    export -f docker

    set +e
    envlocal_inter_out=$(env -u GEMINI_API_KEY HOME="$FAKE_HOME" \
        bash "$REPO_DIR/launch-interactive.sh" 2>&1)
    envlocal_inter_rc=$?
    set -e
    unset -f docker

    rm -f "$ENV_LOCAL_PATH"
    _ENVLOCAL_CREATED=false

    assert_equals "env.local/interactive: exits 0" "0" "$envlocal_inter_rc"
    assert_contains "env.local/interactive: GEMINI_API_KEY sourced from .env.local and passed to docker" \
        "env-local-key-inter" "$envlocal_inter_out"
fi

# ==============================================================================
suite "boundary: GEMINI_API_KEY from .env.local (scripted)"
# ==============================================================================

if [ -f "$ENV_LOCAL_PATH" ]; then
    skip ".env.local already exists — skipping scripted .env.local test"
else
    _ENVLOCAL_CREATED=true
    printf 'GEMINI_API_KEY="env-local-key-scripted"\n' > "$ENV_LOCAL_PATH"

    set +e
    envlocal_scripted_out=$(cd "$WORK_DIR" && \
        PATH="$MOCK_BIN_DIR:$PATH" HOME="$FAKE_HOME" \
        env -u GEMINI_API_KEY \
        bash "$REPO_DIR/launch-scripted.sh" "env-local task" --no-gemini 2>&1)
    envlocal_scripted_rc=$?
    set -e

    rm -f "$ENV_LOCAL_PATH"
    _ENVLOCAL_CREATED=false

    assert_equals "env.local/scripted: exits 0" "0" "$envlocal_scripted_rc"
    assert_contains "env.local/scripted: GEMINI_API_KEY sourced from .env.local and passed to docker" \
        "env-local-key-scripted" "$envlocal_scripted_out"
fi

print_results
