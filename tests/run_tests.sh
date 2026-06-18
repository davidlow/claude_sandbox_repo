#!/bin/bash
# Main test runner for the claude-sandbox test suite.
#
# Usage:
#   ./tests/run_tests.sh           # run all tests (unit + integration)
#   ./tests/run_tests.sh --unit    # run unit tests only (no Docker/credentials needed)
#   ./tests/run_tests.sh --int     # run integration tests only
set -eo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE="${1:-all}"

UNIT_TESTS=(
    test_strip_ansi.sh
    test_build_prompt.sh
    test_argument_parsing.sh
    test_model_tiers.sh
    test_rate_limit_detection.sh
    test_wait_for_quota.sh
    test_credentials.sh
    test_interactive_script.sh
)

INTEGRATION_TESTS=(
    test_container_basics.sh
    test_claude_tasks.sh
)

echo "╔══════════════════════════════════════════════╗"
echo "║       Claude Sandbox Test Suite              ║"
echo "╚══════════════════════════════════════════════╝"

TOTAL_PASS=0
TOTAL_FAIL=0
OVERALL_EXIT=0
FAILED_FILES=()

run_file() {
    local file="$TESTS_DIR/$1"
    echo ""
    echo "┌─ $1"
    local output exit_code
    output=$(bash "$file" 2>&1) || exit_code=$?
    exit_code="${exit_code:-0}"
    echo "$output" | sed 's/^/│ /'
    echo "└─"

    local file_pass file_fail
    file_pass=$(printf '%s' "$output" | grep -c '✅' || true)
    file_fail=$(printf '%s' "$output" | grep -c '❌' || true)
    TOTAL_PASS=$(( TOTAL_PASS + file_pass ))
    TOTAL_FAIL=$(( TOTAL_FAIL + file_fail ))
    if [ "$exit_code" -ne 0 ]; then
        OVERALL_EXIT=1
        FAILED_FILES+=("$1")
    fi
}

case "$MODE" in
    --unit)
        echo "Mode: unit tests only"
        for t in "${UNIT_TESTS[@]}"; do run_file "$t"; done
        ;;
    --int)
        echo "Mode: integration tests only"
        for t in "${INTEGRATION_TESTS[@]}"; do run_file "$t"; done
        ;;
    *)
        echo "Mode: all tests"
        for t in "${UNIT_TESTS[@]}";        do run_file "$t"; done
        for t in "${INTEGRATION_TESTS[@]}"; do run_file "$t"; done
        ;;
esac

echo ""
echo "╔══════════════════════════════════════════════╗"
printf "║  Total: %-5s passed  %-5s failed           ║\n" "$TOTAL_PASS" "$TOTAL_FAIL"
if [ ${#FAILED_FILES[@]} -gt 0 ]; then
    echo "║                                              ║"
    echo "║  Files with failures:                        ║"
    for f in "${FAILED_FILES[@]}"; do
        printf "║    ✗ %-42s║\n" "$f"
    done
fi
echo "╚══════════════════════════════════════════════╝"

exit $OVERALL_EXIT
