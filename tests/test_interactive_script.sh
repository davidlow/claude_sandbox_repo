#!/bin/bash
# Tests for launch-interactive.sh behavior.
# Error paths are testable without Docker. The actual interactive session
# requires a real TTY so we only validate the script-level guards.
set -eo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
FIXTURE_DIR="$TESTS_DIR/fixtures"
source "$TESTS_DIR/helpers.sh"

suite "launch-interactive.sh — credential guard"

# Missing ~/.claude dir entirely
FAKE_HOME=$(mktemp -d)
trap 'rm -rf "$FAKE_HOME"' RETURN
set +e
output=$(HOME="$FAKE_HOME" bash "$REPO_DIR/launch-interactive.sh" 2>&1)
rc=$?
set -e
assert_equals "missing creds: exit code 1" "1" "$rc"
assert_contains "missing creds: error message shown" "No Claude credentials found" "$output"
assert_contains "missing creds: login hint shown" "claude auth login" "$output"

# Credentials directory exists but credentials.json absent
FAKE_HOME2=$(mktemp -d)
mkdir -p "$FAKE_HOME2/.claude"
trap 'rm -rf "$FAKE_HOME2"' RETURN
set +e
output=$(HOME="$FAKE_HOME2" bash "$REPO_DIR/launch-interactive.sh" 2>&1)
rc=$?
set -e
assert_equals "empty .claude dir: exit code 1" "1" "$rc"
assert_contains "empty .claude dir: error message" "No Claude credentials found" "$output"

# Malformed credentials: python fails → token empty → script exits 1
FAKE_HOME3=$(mktemp -d)
mkdir -p "$FAKE_HOME3/.claude"
cp "$FIXTURE_DIR/malformed_creds.json" "$FAKE_HOME3/.claude/.credentials.json"
trap 'rm -rf "$FAKE_HOME3"' RETURN
set +e
output=$(HOME="$FAKE_HOME3" bash "$REPO_DIR/launch-interactive.sh" 2>&1)
rc=$?
set -e
assert_equals "malformed creds: exit code 1" "1" "$rc"
assert_contains "malformed creds: token read error shown" "Could not read OAuth token" "$output"

suite "launch-interactive.sh — model selection"

# Test model selection by mocking docker so the script doesn't actually launch.
# The mock captures CHOSEN_MODEL from the script's local scope via the
# command line that docker receives (the script passes --model "$CHOSEN_MODEL").
FAKE_HOME4=$(mktemp -d)
mkdir -p "$FAKE_HOME4/.claude"
cp "$FIXTURE_DIR/valid_creds.json" "$FAKE_HOME4/.claude/.credentials.json"
trap 'rm -rf "$FAKE_HOME4"' RETURN

docker() { echo "MOCK_DOCKER args=$*"; }
export -f docker
set +e
output=$(HOME="$FAKE_HOME4" bash "$REPO_DIR/launch-interactive.sh" 2>&1)
set -e
unset -f docker
assert_contains "no model arg: docker called with default sonnet" "claude-sonnet-4-6" "$output"

docker() { echo "MOCK_DOCKER args=$*"; }
export -f docker
set +e
output=$(HOME="$FAKE_HOME4" bash "$REPO_DIR/launch-interactive.sh" "claude-opus-4-8" 2>&1)
set -e
unset -f docker
assert_contains "explicit model arg: docker called with opus" "claude-opus-4-8" "$output"

suite "launch-interactive.sh — container name sanitization"

# Container name must only contain alphanumerics and hyphens.
# Run from a directory with special chars in its name.
WEIRD_DIR=$(mktemp -d)
WEIRD_PATH="$WEIRD_DIR/my project (v2)!"
mkdir -p "$WEIRD_PATH"
FAKE_HOME5=$(mktemp -d)
mkdir -p "$FAKE_HOME5/.claude"
cp "$FIXTURE_DIR/valid_creds.json" "$FAKE_HOME5/.claude/.credentials.json"
trap 'rm -rf "$WEIRD_DIR" "$FAKE_HOME5"' RETURN

docker() {
    # Capture the --name argument
    local prev=""
    for arg in "$@"; do
        [ "$prev" = "--name" ] && echo "CONTAINER_NAME=$arg"
        prev="$arg"
    done
}
export -f docker
output=$(cd "$WEIRD_PATH" && HOME="$FAKE_HOME5" bash "$REPO_DIR/launch-interactive.sh" 2>&1) || true
unset -f docker

assert_contains "container name captured" "CONTAINER_NAME=" "$output"
container_name=$(printf '%s' "$output" | grep "CONTAINER_NAME=" | sed 's/CONTAINER_NAME=//')
# Must match [a-z0-9-] only (Docker name rules)
sanitized=$(printf '%s' "$container_name" | sed 's/[^a-z0-9-]//g')
assert_equals "container name contains only safe characters" "$container_name" "$sanitized"

print_results
