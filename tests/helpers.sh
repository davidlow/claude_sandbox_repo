#!/bin/bash
# Test assertion framework. Source this file from test scripts.
# Guards against double-sourcing so counters survive across files.

if [ -n "${_HELPERS_LOADED:-}" ]; then return 0; fi
_HELPERS_LOADED=1

TEST_PASS=0
TEST_FAIL=0
TEST_ERRORS=()
_CURRENT_SUITE="(no suite)"

# ---------------------------------------------------------------------------
# suite <name>
# Labels a group of tests. Name appears in error reports.
# ---------------------------------------------------------------------------
suite() {
    _CURRENT_SUITE="$1"
    echo ""
    echo "▶ $1"
}

# ---------------------------------------------------------------------------
# assert_equals <desc> <expected> <actual>
# ---------------------------------------------------------------------------
assert_equals() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  ✅ $desc"
        TEST_PASS=$(( TEST_PASS + 1 ))
    else
        echo "  ❌ $desc"
        echo "       expected: $(printf '%s' "$expected" | head -3)"
        echo "       actual:   $(printf '%s' "$actual" | head -3)"
        TEST_FAIL=$(( TEST_FAIL + 1 ))
        TEST_ERRORS+=("[$_CURRENT_SUITE] $desc")
    fi
}

# ---------------------------------------------------------------------------
# assert_contains <desc> <literal_substring> <string>
# Uses bash [[ ]] for reliable literal substring matching — avoids ugrep/
# GNU grep behavioral differences with emoji, dots, and special chars.
# ---------------------------------------------------------------------------
assert_contains() {
    local desc="$1" pattern="$2" actual="$3"
    if [[ "$actual" == *"$pattern"* ]]; then
        echo "  ✅ $desc"
        TEST_PASS=$(( TEST_PASS + 1 ))
    else
        echo "  ❌ $desc"
        echo "       substring not found: $pattern"
        echo "       in: $(printf '%s' "$actual" | head -3)"
        TEST_FAIL=$(( TEST_FAIL + 1 ))
        TEST_ERRORS+=("[$_CURRENT_SUITE] $desc")
    fi
}

# ---------------------------------------------------------------------------
# assert_not_contains <desc> <literal_substring> <string>
# ---------------------------------------------------------------------------
assert_not_contains() {
    local desc="$1" pattern="$2" actual="$3"
    if [[ "$actual" != *"$pattern"* ]]; then
        echo "  ✅ $desc"
        TEST_PASS=$(( TEST_PASS + 1 ))
    else
        echo "  ❌ $desc"
        echo "       substring should NOT be present: $pattern"
        echo "       in: $(printf '%s' "$actual" | head -3)"
        TEST_FAIL=$(( TEST_FAIL + 1 ))
        TEST_ERRORS+=("[$_CURRENT_SUITE] $desc")
    fi
}

# ---------------------------------------------------------------------------
# assert_exit_code <desc> <expected_code> <cmd> [args...]
# ---------------------------------------------------------------------------
assert_exit_code() {
    local desc="$1" expected_code="$2"
    shift 2
    local actual_code=0
    "$@" >/dev/null 2>&1 || actual_code=$?
    if [ "$expected_code" -eq "$actual_code" ]; then
        echo "  ✅ $desc"
        TEST_PASS=$(( TEST_PASS + 1 ))
    else
        echo "  ❌ $desc"
        echo "       expected exit: $expected_code"
        echo "       actual exit:   $actual_code"
        TEST_FAIL=$(( TEST_FAIL + 1 ))
        TEST_ERRORS+=("[$_CURRENT_SUITE] $desc")
    fi
}

# ---------------------------------------------------------------------------
# assert_file_exists <desc> <path>
# ---------------------------------------------------------------------------
assert_file_exists() {
    local desc="$1" path="$2"
    if [ -f "$path" ]; then
        echo "  ✅ $desc"
        TEST_PASS=$(( TEST_PASS + 1 ))
    else
        echo "  ❌ $desc"
        echo "       file not found: $path"
        TEST_FAIL=$(( TEST_FAIL + 1 ))
        TEST_ERRORS+=("[$_CURRENT_SUITE] $desc")
    fi
}

# ---------------------------------------------------------------------------
# skip <reason>
# Marks a test as skipped (counts neither pass nor fail).
# ---------------------------------------------------------------------------
skip() {
    echo "  ⏭  SKIP: $1"
}

# ---------------------------------------------------------------------------
# print_results
# Prints summary and exits 1 if any tests failed.
# ---------------------------------------------------------------------------
print_results() {
    echo ""
    echo "══════════════════════════════════════════════"
    echo "  Results: ${TEST_PASS} passed, ${TEST_FAIL} failed"
    if [ ${#TEST_ERRORS[@]} -gt 0 ]; then
        echo ""
        echo "  Failed:"
        for err in "${TEST_ERRORS[@]}"; do
            echo "    ✗ $err"
        done
    fi
    echo "══════════════════════════════════════════════"
    [ "$TEST_FAIL" -eq 0 ]
}
