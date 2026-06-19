#!/bin/bash
# Main test runner for the claude-sandbox test suite.
#
# Usage:
#   ./tests/run_tests.sh                  # run all tests except E2E
#   ./tests/run_tests.sh --unit           # unit tests only (no Docker/credentials/network)
#   ./tests/run_tests.sh --int            # legacy integration tests (Docker + credentials)
#   ./tests/run_tests.sh --security       # Docker sandbox security checks
#   ./tests/run_tests.sh --gemini         # Gemini API integration tests (needs GEMINI_API_KEY)
#   ./tests/run_tests.sh --orchestration  # pipeline orchestration with mock Docker image
#   ./tests/run_tests.sh --e2e            # full end-to-end (Docker + credentials, slow)
set -eo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE="${1:-all}"

# ---------------------------------------------------------------------------
# Test file lists by category
# ---------------------------------------------------------------------------

UNIT_TESTS=(
    test_strip_ansi.sh
    test_build_prompt.sh
    test_argument_parsing.sh
    test_model_tiers.sh
    test_rate_limit_detection.sh
    test_wait_for_quota.sh
    test_credentials.sh
    test_interactive_script.sh
    test_pipelines.sh
    test_unit_lib_extended.sh
)

# Legacy integration tests (Docker + credentials, run the actual Claude binary)
INTEGRATION_TESTS=(
    test_container_basics.sh
    test_claude_tasks.sh
)

# Docker sandbox security isolation tests (Docker only, no credentials needed)
SECURITY_TESTS=(
    test_sandbox_security.sh
)

# Gemini API tests (network only, no Docker)
GEMINI_TESTS=(
    test_gemini.sh
)

# Pipeline orchestration tests (Docker + mock image, no real credentials needed)
ORCHESTRATION_TESTS=(
    test_orchestration.sh
)

# Full end-to-end tests (Docker + real credentials, slow — excluded from --all)
E2E_TESTS=(
    test_e2e.sh
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
        echo "Mode: unit tests only (no external dependencies)"
        for t in "${UNIT_TESTS[@]}"; do run_file "$t"; done
        ;;
    --int)
        echo "Mode: integration tests (Docker + credentials required)"
        for t in "${INTEGRATION_TESTS[@]}"; do run_file "$t"; done
        ;;
    --security)
        echo "Mode: sandbox security tests (Docker required)"
        for t in "${SECURITY_TESTS[@]}"; do run_file "$t"; done
        ;;
    --gemini)
        echo "Mode: Gemini API integration tests (GEMINI_API_KEY required, lite models)"
        export GEMINI_MODEL_TIER="lite"
        for t in "${GEMINI_TESTS[@]}"; do run_file "$t"; done
        unset GEMINI_MODEL_TIER
        ;;
    --orchestration)
        echo "Mode: pipeline orchestration tests (Docker required, builds mock image)"
        for t in "${ORCHESTRATION_TESTS[@]}"; do run_file "$t"; done
        ;;
    --e2e)
        echo "Mode: full end-to-end tests (Docker + credentials required, SLOW)"
        for t in "${E2E_TESTS[@]}"; do run_file "$t"; done
        ;;
    *)
        echo "Mode: all tests except E2E (unit + integration + security + gemini + orchestration)"
        for t in "${UNIT_TESTS[@]}";        do run_file "$t"; done
        for t in "${INTEGRATION_TESTS[@]}"; do run_file "$t"; done
        for t in "${SECURITY_TESTS[@]}";    do run_file "$t"; done
        export GEMINI_MODEL_TIER="lite"
        for t in "${GEMINI_TESTS[@]}";      do run_file "$t"; done
        unset GEMINI_MODEL_TIER
        for t in "${ORCHESTRATION_TESTS[@]}"; do run_file "$t"; done
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
