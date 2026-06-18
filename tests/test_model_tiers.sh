#!/bin/bash
# Unit tests for parse_model_tier()
set -eo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TESTS_DIR/helpers.sh"
source "$TESTS_DIR/../lib/launch-lib.sh"

suite "parse_model_tier() — haiku"

parse_model_tier "claude-haiku-4-5"
assert_equals "haiku: MAX_MINUTES=15"             "15"    "$MAX_MINUTES"
assert_equals "haiku: MAX_RETRIES=3"               "3"     "$MAX_RETRIES"
assert_equals "haiku: MAX_CONTEXT_TOKENS=50000"   "50000" "$MAX_CONTEXT_TOKENS"
assert_equals "haiku: TARGET_INPUT_TOKENS=25000"  "25000" "$TARGET_INPUT_TOKENS"
assert_equals "haiku: MAX_THINKING_TOKENS=0"       "0"     "$MAX_THINKING_TOKENS"

suite "parse_model_tier() — sonnet (default)"

parse_model_tier "claude-sonnet-4-6"
assert_equals "sonnet: MAX_MINUTES=10"             "10"    "$MAX_MINUTES"
assert_equals "sonnet: MAX_RETRIES=3"               "3"     "$MAX_RETRIES"
assert_equals "sonnet: MAX_CONTEXT_TOKENS=80000"  "80000" "$MAX_CONTEXT_TOKENS"
assert_equals "sonnet: TARGET_INPUT_TOKENS=40000" "40000" "$TARGET_INPUT_TOKENS"
assert_equals "sonnet: MAX_THINKING_TOKENS=10000" "10000" "$MAX_THINKING_TOKENS"

suite "parse_model_tier() — opus"

parse_model_tier "claude-opus-4-8"
assert_equals "opus: MAX_MINUTES=5"                "5"     "$MAX_MINUTES"
assert_equals "opus: MAX_RETRIES=2"                "2"     "$MAX_RETRIES"
assert_equals "opus: MAX_CONTEXT_TOKENS=120000"  "120000" "$MAX_CONTEXT_TOKENS"
assert_equals "opus: TARGET_INPUT_TOKENS=60000"  "60000"  "$TARGET_INPUT_TOKENS"
assert_equals "opus: MAX_THINKING_TOKENS=24000"  "24000"  "$MAX_THINKING_TOKENS"

suite "parse_model_tier() — fable"

parse_model_tier "claude-fable-5"
assert_equals "fable: MAX_MINUTES=4"               "4"     "$MAX_MINUTES"
assert_equals "fable: MAX_RETRIES=2"               "2"     "$MAX_RETRIES"
assert_equals "fable: MAX_CONTEXT_TOKENS=120000" "120000"  "$MAX_CONTEXT_TOKENS"
assert_equals "fable: TARGET_INPUT_TOKENS=60000"  "60000"  "$TARGET_INPUT_TOKENS"
assert_equals "fable: MAX_THINKING_TOKENS=0 (manages own reasoning)" "0" "$MAX_THINKING_TOKENS"

suite "parse_model_tier() — unknown model falls back to sonnet defaults"

parse_model_tier "some-new-model-99"
assert_equals "unknown model: MAX_MINUTES=10"            "10"    "$MAX_MINUTES"
assert_equals "unknown model: MAX_RETRIES=3"              "3"     "$MAX_RETRIES"
assert_equals "unknown model: MAX_CONTEXT_TOKENS=80000" "80000"  "$MAX_CONTEXT_TOKENS"
assert_equals "unknown model: MAX_THINKING_TOKENS=10000" "10000" "$MAX_THINKING_TOKENS"

suite "parse_model_tier() — substring matching"

# "haiku" anywhere in model name triggers the tier
parse_model_tier "experimental-haiku-v2-preview"
assert_equals "haiku substring match works" "15" "$MAX_MINUTES"

# "opus" anywhere in model name
parse_model_tier "my-opus-custom"
assert_equals "opus substring match works" "5" "$MAX_MINUTES"

print_results
