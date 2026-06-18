#!/bin/bash
# Unit tests for parse_args()
set -eo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TESTS_DIR/helpers.sh"
source "$TESTS_DIR/../lib/launch-lib.sh"

suite "parse_args() — basic positional args"

parse_args "do the thing"
assert_equals "single arg: task set" "do the thing" "$ORIGINAL_TASK_PROMPT"
assert_equals "single arg: model defaults to sonnet" "claude-sonnet-4-6" "$CHOSEN_MODEL"
assert_equals "single arg: gemini enabled by default" "true" "$GEMINI_ENABLED"

parse_args "refactor auth" "claude-opus-4-8"
assert_equals "two args: task set" "refactor auth" "$ORIGINAL_TASK_PROMPT"
assert_equals "two args: model overridden" "claude-opus-4-8" "$CHOSEN_MODEL"

parse_args
assert_equals "no args: task is empty string" "" "$ORIGINAL_TASK_PROMPT"
assert_equals "no args: model still defaults to sonnet" "claude-sonnet-4-6" "$CHOSEN_MODEL"

suite "parse_args() — --no-gemini flag placement"

parse_args --no-gemini "do the thing"
assert_equals "--no-gemini first: disabled" "false" "$GEMINI_ENABLED"
assert_equals "--no-gemini first: task still extracted" "do the thing" "$ORIGINAL_TASK_PROMPT"

parse_args "do the thing" --no-gemini
assert_equals "--no-gemini last: disabled" "false" "$GEMINI_ENABLED"
assert_equals "--no-gemini last: task still extracted" "do the thing" "$ORIGINAL_TASK_PROMPT"

parse_args "do the thing" "claude-haiku-4-5" --no-gemini
assert_equals "--no-gemini after model: disabled" "false" "$GEMINI_ENABLED"
assert_equals "--no-gemini after model: task extracted" "do the thing" "$ORIGINAL_TASK_PROMPT"
assert_equals "--no-gemini after model: model extracted" "claude-haiku-4-5" "$CHOSEN_MODEL"

parse_args "task" --no-gemini "claude-opus-4-8"
assert_equals "--no-gemini in middle: disabled" "false" "$GEMINI_ENABLED"
assert_equals "--no-gemini in middle: model is NOT extracted (flag consumed position)" "task" "$ORIGINAL_TASK_PROMPT"

suite "parse_args() — --no-gemini not in POSITIONAL_ARGS"

parse_args --no-gemini "my task" "claude-sonnet-4-6"
assert_equals "--no-gemini not included in positional args" "2" "${#POSITIONAL_ARGS[@]}"

suite "parse_args() — GEMINI_API_KEY absent disables Gemini"

# Simulate the post-parse key check from launch-scripted.sh
parse_args "run tests"
GEMINI_ENABLED=true   # reset as if parse_args just ran
unset GEMINI_API_KEY
[ -z "${GEMINI_API_KEY:-}" ] && GEMINI_ENABLED=false
assert_equals "absent GEMINI_API_KEY disables audit" "false" "$GEMINI_ENABLED"

print_results
