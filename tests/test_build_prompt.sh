#!/bin/bash
# Unit tests for build_prompt_with_advice()
set -eo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TESTS_DIR/helpers.sh"
source "$TESTS_DIR/../lib/launch-lib.sh"

suite "build_prompt_with_advice()"

# No advice: base task returned verbatim
GEMINI_ADVICE_TEXT=""
result=$(build_prompt_with_advice "do the thing")
assert_equals "no advice: base task returned unchanged" "do the thing" "$result"

# No advice: no extra markers injected
assert_not_contains "no advice: no advice header injected" "GEMINI" "$result"

# With advice: contains all three expected sections
GEMINI_ADVICE_TEXT="Use approach X not Y"
result=$(build_prompt_with_advice "do the thing")
assert_contains "advice present: contains start marker" "=== GEMINI ARCHITECT ADVICE" "$result"
assert_contains "advice present: contains advice text" "Use approach X not Y" "$result"
assert_contains "advice present: contains end marker" "=== END ADVICE ===" "$result"
assert_contains "advice present: contains base task" "do the thing" "$result"

# With advice: advice block precedes base task
GEMINI_ADVICE_TEXT="my advice"
result=$(build_prompt_with_advice "original task")
advice_line=$(printf '%s' "$result" | grep -n "my advice" | head -1 | cut -d: -f1)
task_line=$(printf '%s' "$result" | grep -n "^original task$" | head -1 | cut -d: -f1)
assert_equals "advice block appears before base task" "true" \
    "$([ "${advice_line:-0}" -lt "${task_line:-0}" ] && echo true || echo false)"

# Idempotent: calling twice with same inputs yields identical output (no stacking)
GEMINI_ADVICE_TEXT="first advice"
first=$(build_prompt_with_advice "task A")
second=$(build_prompt_with_advice "task A")
assert_equals "repeated calls with same advice are identical (no stacking)" "$first" "$second"

# Multiline advice is preserved
GEMINI_ADVICE_TEXT=$'line one\nline two\nline three'
result=$(build_prompt_with_advice "base")
assert_contains "multiline advice: line one present" "line one" "$result"
assert_contains "multiline advice: line three present" "line three" "$result"

# Empty base task with advice still has the header
GEMINI_ADVICE_TEXT="some advice"
result=$(build_prompt_with_advice "")
assert_contains "empty base with advice: header still present" "GEMINI ARCHITECT ADVICE" "$result"

print_results
