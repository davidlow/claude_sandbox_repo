#!/bin/bash
# Unit tests for wait_for_quota()
set -eo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TESTS_DIR/helpers.sh"
source "$TESTS_DIR/../lib/launch-lib.sh"

suite "wait_for_quota()"

# If target_epoch is in the past, wait_for_quota() must return immediately
# (the while-loop breaks on remaining <= 0 before ever calling sleep).
PAST_EPOCH=$(( $(date +%s) - 300 ))
start_ns=$(date +%s%N)
wait_for_quota "$PAST_EPOCH" "already-past" > /dev/null
end_ns=$(date +%s%N)
elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
assert_equals "exits immediately when target is in the past" "true" \
    "$([ "$elapsed_ms" -lt 2000 ] && echo true || echo false)"

# Output includes the standby message with the display time
output=$(wait_for_quota "$PAST_EPOCH" "TEST_DISPLAY_TIME")
assert_contains "standby message contains display time" "TEST_DISPLAY_TIME" "$output"

# Output includes the resume message
assert_contains "resume message printed on exit" "Quota window open" "$output"

print_results
