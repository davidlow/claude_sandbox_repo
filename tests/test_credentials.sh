#!/bin/bash
# Unit tests for credential loading and OAuth token extraction.
# Uses fixture files — never touches real ~/.claude credentials.
set -eo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE_DIR="$TESTS_DIR/fixtures"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"

source "$TESTS_DIR/helpers.sh"

suite "OAuth token extraction from credentials JSON"

# Valid creds: access token extracted
OAUTH_TOKEN=$(python3 -c "
import json
with open('$FIXTURE_DIR/valid_creds.json') as f:
    print(json.load(f)['claudeAiOauth']['accessToken'])
" 2>/dev/null)
assert_equals "valid creds: accessToken extracted" \
    "fake-access-token-abc123" "$OAUTH_TOKEN"

# Valid creds: refresh token extracted
OAUTH_REFRESH=$(python3 -c "
import json
with open('$FIXTURE_DIR/valid_creds.json') as f:
    print(json.load(f)['claudeAiOauth']['refreshToken'])
" 2>/dev/null)
assert_equals "valid creds: refreshToken extracted" \
    "fake-refresh-token-xyz456" "$OAUTH_REFRESH"

# Missing file: python exits non-zero, variable stays empty
OAUTH_TOKEN=$(python3 -c "
import json
with open('/nonexistent/path.json') as f:
    print(json.load(f)['claudeAiOauth']['accessToken'])
" 2>/dev/null) || true
assert_equals "missing creds file: token is empty" "" "$OAUTH_TOKEN"

# Malformed JSON: python exits non-zero, variable stays empty
OAUTH_TOKEN=$(python3 -c "
import json
with open('$FIXTURE_DIR/malformed_creds.json') as f:
    print(json.load(f)['claudeAiOauth']['accessToken'])
" 2>/dev/null) || true
assert_equals "malformed JSON: token is empty" "" "$OAUTH_TOKEN"

# Missing field: python exits non-zero, variable stays empty
OAUTH_TOKEN=$(python3 -c "
import json
with open('$FIXTURE_DIR/valid_creds.json') as f:
    print(json.load(f)['claudeAiOauth']['nonExistentField'])
" 2>/dev/null) || true
assert_equals "missing JSON field: token is empty" "" "$OAUTH_TOKEN"

suite "launch-interactive.sh error paths"

# Missing credentials directory → script exits 1 with a helpful message
FAKE_HOME=$(mktemp -d)
trap 'rm -rf "$FAKE_HOME"' RETURN
set +e
output=$(HOME="$FAKE_HOME" bash "$REPO_DIR/launch-interactive.sh" 2>&1)
exit_code=$?
set -e
assert_equals "missing creds: exits with code 1" "1" "$exit_code"
assert_contains "missing creds: shows credential path error" "No Claude credentials found" "$output"
assert_contains "missing creds: tells user how to log in" "claude auth login" "$output"

suite "launch-scripted.sh error paths"

# Missing credentials directory → script exits 1 with helpful message
FAKE_HOME2=$(mktemp -d)
trap 'rm -rf "$FAKE_HOME2"' RETURN
set +e
output=$(HOME="$FAKE_HOME2" bash "$REPO_DIR/launch-scripted.sh" "some task" 2>&1)
exit_code=$?
set -e
assert_equals "scripted: missing creds exits with code 1" "1" "$exit_code"
assert_contains "scripted: missing creds error shown" "No Claude credentials found" "$output"

# Missing task prompt → script exits 1
# We need creds present but no task; use a fake creds dir
FAKE_HOME3=$(mktemp -d)
mkdir -p "$FAKE_HOME3/.claude"
cp "$FIXTURE_DIR/valid_creds.json" "$FAKE_HOME3/.claude/.credentials.json"
trap 'rm -rf "$FAKE_HOME3"' RETURN
set +e
output=$(HOME="$FAKE_HOME3" bash "$REPO_DIR/launch-scripted.sh" 2>&1)
exit_code=$?
set -e
assert_equals "scripted: missing task exits with code 1" "1" "$exit_code"
assert_contains "scripted: missing task error shown" "must provide an instruction" "$output"

print_results
