#!/bin/bash
# Unit tests for strip_ansi()
set -eo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TESTS_DIR/helpers.sh"
source "$TESTS_DIR/../lib/launch-lib.sh"

# Helper: write content to a temp file and return the path
_tmpfile() { local f; f=$(mktemp); printf '%s' "$1" > "$f"; echo "$f"; }

suite "strip_ansi()"

# Plain text must pass through unchanged
result=$(strip_ansi "$(_tmpfile "hello world")")
assert_equals "plain text is unchanged" "hello world" "$result"

# ANSI color code removed
result=$(strip_ansi "$(_tmpfile $'\x1b[31mred\x1b[0m')")
assert_equals "foreground color codes stripped" "red" "$result"

# Bold + color combo
result=$(strip_ansi "$(_tmpfile $'\x1b[1m\x1b[32mbold green\x1b[0m')")
assert_equals "bold+color combo stripped" "bold green" "$result"

# Carriage returns removed (emitted by Claude TUI progress lines)
result=$(strip_ansi "$(_tmpfile $'line1\r\nline2')")
assert_equals "carriage returns stripped" $'line1\nline2' "$result"

# Cursor movement codes (Claude TUI clears screen with these)
result=$(strip_ansi "$(_tmpfile $'\x1b[2J\x1b[H text')")
assert_equals "cursor movement codes stripped" " text" "$result"

# Mixed content
result=$(strip_ansi "$(_tmpfile $'\x1b[33mwarning:\x1b[0m check this')")
assert_equals "mixed ANSI and plain text" "warning: check this" "$result"

# Empty file
result=$(strip_ansi "$(_tmpfile "")")
assert_equals "empty input produces empty output" "" "$result"

# Rate-limit message survives stripping (critical: detection regex must still match)
result=$(strip_ansi "$(_tmpfile $'\x1b[31mtry again after 14:00\x1b[0m')")
assert_equals "rate limit time string preserved through strip" "try again after 14:00" "$result"

# Numeric params with semicolons (256-color codes)
result=$(strip_ansi "$(_tmpfile $'\x1b[38;5;196mdeep red\x1b[0m')")
assert_equals "256-color sequences stripped" "deep red" "$result"

print_results
