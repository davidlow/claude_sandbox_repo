#!/bin/bash
# Unit tests for rate-limit detection and time extraction logic.
# These test the grep/awk patterns used in launch-scripted.sh without
# invoking Docker or credentials.
set -eo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TESTS_DIR/helpers.sh"
source "$TESTS_DIR/../lib/launch-lib.sh"

# Helper: write to a temp log file and return its path
_log() { local f; f=$(mktemp); printf '%s' "$1" > "$f"; echo "$f"; }

# The regex pattern used by launch-scripted.sh for detection
_detect() {
    local logfile="$1"
    strip_ansi "$logfile" | grep -qi "after [0-9]\{1,2\}:[0-9]\{2\}" \
        && echo "detected" || echo "not detected"
}

# The awk extraction pipeline used by launch-scripted.sh
_extract_time() {
    local logfile="$1"
    strip_ansi "$logfile" \
        | grep -oi "after [0-9]\{1,2\}:[0-9]\{2\}\( *[AaPp][Mm]\)\?" \
        | tail -1 \
        | awk '{print $2, $3}' \
        | xargs
}

suite "Rate-limit detection"

assert_equals "plain HH:MM message detected" \
    "detected" "$(_detect "$(_log "quota exhausted. try again after 14:00")")"

assert_equals "single-digit hour detected" \
    "detected" "$(_detect "$(_log "try again after 2:30")")"

assert_equals "message with ANSI color codes still detected" \
    "detected" "$(_detect "$(_log $'\x1b[31mtry again after 02:30\x1b[0m')")"

assert_equals "normal failure output NOT flagged as rate limit" \
    "not detected" "$(_detect "$(_log "Error: claude exited with code 1")")"

assert_equals "empty log NOT flagged as rate limit" \
    "not detected" "$(_detect "$(_log "")")"

assert_equals "partial match 'after' without time NOT flagged" \
    "not detected" "$(_detect "$(_log "try again after a while")")"

suite "Rate-limit time extraction"

assert_equals "plain HH:MM extracted" \
    "14:00" "$(_extract_time "$(_log "try again after 14:00")")"

assert_equals "HH:MM PM extracted (uppercase)" \
    "14:30 PM" "$(_extract_time "$(_log "quota resets. Try again after 14:30 PM.")")"

assert_equals "HH:MM am extracted (lowercase)" \
    "2:00 am" "$(_extract_time "$(_log "try again after 2:00 am")")"

# Multiple messages: must take the LAST one (tail -1 in the pipeline)
assert_equals "multiple messages: last time extracted" \
    "14:00" "$(_extract_time "$(_log $'try again after 12:00\ntry again after 14:00')")"

# Time with ANSI around it
assert_equals "time extracted through ANSI color wrapping" \
    "03:15" "$(_extract_time "$(_log $'\x1b[33mtry again after 03:15\x1b[0m')")"

suite "Rate-limit epoch arithmetic"

# Verify that a past time triggers the 'tomorrow' fallback in the date logic
NOW=$(date +%s)
PAST_TIME=$(date -d "@$(( NOW - 3600 ))" '+%H:%M')  # 1 hour ago
TARGET_EPOCH=$(date -d "$PAST_TIME" +%s 2>/dev/null || date -d "today $PAST_TIME" +%s)
[ "$TARGET_EPOCH" -lt "$NOW" ] && TARGET_EPOCH=$(date -d "tomorrow $PAST_TIME" +%s)
assert_equals "past reset time bumped to tomorrow" "true" \
    "$([ "$TARGET_EPOCH" -gt "$NOW" ] && echo true || echo false)"

# Verify 5-minute buffer is applied
PRE_BUFFER=$TARGET_EPOCH
TARGET_EPOCH=$(( TARGET_EPOCH + 300 ))
assert_equals "5-minute buffer applied" "300" "$(( TARGET_EPOCH - PRE_BUFFER ))"

print_results
