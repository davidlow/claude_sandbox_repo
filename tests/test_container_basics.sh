#!/bin/bash
# Integration tests: Docker image existence and container startup.
# Skipped if Docker is not running or the claude-sandbox image is absent.
set -eo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TESTS_DIR/helpers.sh"

CREDS="$HOME/.claude/.credentials.json"

suite "Container prerequisites"

# Check Docker is accessible
if ! docker info >/dev/null 2>&1; then
    skip "Docker not running — skipping all container tests"
    print_results
    exit 0
fi
echo "  ✅ Docker is running"
TEST_PASS=$(( TEST_PASS + 1 ))

# Check claude-sandbox image exists
if ! docker image inspect claude-sandbox >/dev/null 2>&1; then
    skip "claude-sandbox image not found — run: docker build -t claude-sandbox -f Dockerfile.claude ."
    print_results
    exit 0
fi
echo "  ✅ claude-sandbox image exists"
TEST_PASS=$(( TEST_PASS + 1 ))

# Check credentials present
if [ ! -f "$CREDS" ]; then
    skip "No credentials at $CREDS — run: claude auth login --claudeai && claude-box-auth"
    print_results
    exit 0
fi
echo "  ✅ Credentials file present"
TEST_PASS=$(( TEST_PASS + 1 ))

suite "Container startup and basic shell"

# Container starts and bash is available
output=$(docker run --rm claude-sandbox bash -c "echo CONTAINER_OK" 2>&1)
assert_equals "container starts and bash works" "CONTAINER_OK" "$output"

# claudeuser UID is 1000 (matches Debian/Crostini host default)
uid=$(docker run --rm claude-sandbox bash -c "id -u")
assert_equals "claudeuser UID is 1000" "1000" "$uid"

# Python3 is available (required for OAuth extraction)
py_ver=$(docker run --rm claude-sandbox bash -c "python3 --version 2>&1")
assert_contains "python3 is installed" "Python 3" "$py_ver"

# Node is available (Claude Code is a Node app)
node_ver=$(docker run --rm claude-sandbox bash -c "node --version 2>&1")
assert_contains "node is installed" "v" "$node_ver"

# claude binary is on PATH
claude_path=$(docker run --rm claude-sandbox bash -c "which claude 2>&1")
assert_contains "claude binary is on PATH" "claude" "$claude_path"

# claude --version returns something reasonable
claude_ver=$(docker run --rm claude-sandbox bash -c "claude --version 2>&1 || true")
assert_contains "claude --version returns output" "." "$claude_ver"

# Workspace mount point exists
ws=$(docker run --rm claude-sandbox bash -c "ls -d /workspace 2>&1")
assert_equals "workspace directory exists" "/workspace" "$ws"

suite "Container workspace isolation"

# Container cannot see the host filesystem outside of mounts
TMPWS=$(mktemp -d)
trap 'rm -rf "$TMPWS"' RETURN
echo "sentinel_content_12345" > "$TMPWS/sentinel.txt"

# Files placed in workspace are visible inside the container
visible=$(docker run --rm -v "$TMPWS":/workspace claude-sandbox \
    bash -c "cat /workspace/sentinel.txt 2>&1")
assert_equals "workspace files are readable inside container" "sentinel_content_12345" "$visible"

# Files outside the mounted workspace are NOT visible
not_visible=$(docker run --rm -v "$TMPWS":/workspace claude-sandbox \
    bash -c "ls /home/claudeuser/other_dir 2>&1 || echo INACCESSIBLE")
assert_contains "host paths outside workspace are inaccessible" "INACCESSIBLE" "$not_visible"

print_results
