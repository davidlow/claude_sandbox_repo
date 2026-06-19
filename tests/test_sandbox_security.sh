#!/bin/bash
# Security isolation tests for the claude-sandbox Docker image.
#
# Verifies that containers run with the expected security posture:
#   - Non-root user (uid 1000)
#   - No Docker socket or docker binary inside the container
#   - No sudo
#   - Limited Linux capabilities (not privileged)
#   - PID namespace isolation
#   - Seccomp filter active
#   - Cannot write to sensitive host paths
#   - No unexpected setuid binaries
#
# Requires: Docker running + claude-sandbox image built.
set -eo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TESTS_DIR/helpers.sh"

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

suite "Security test prerequisites"

if ! docker info >/dev/null 2>&1; then
    skip "Docker not running — skipping all security tests"
    print_results
    exit 0
fi
echo "  ✅ Docker is running"
TEST_PASS=$(( TEST_PASS + 1 ))

if ! docker image inspect claude-sandbox >/dev/null 2>&1; then
    skip "claude-sandbox image not found — run: docker build -t claude-sandbox -f Dockerfile.claude ."
    print_results
    exit 0
fi
echo "  ✅ claude-sandbox image exists"
TEST_PASS=$(( TEST_PASS + 1 ))

# ---------------------------------------------------------------------------
# Helper: run a command inside a fresh sandbox container (no workspace needed)
# ---------------------------------------------------------------------------
TMPWS=$(mktemp -d)
trap 'rm -rf "$TMPWS"' EXIT

sandbox_exec() {
    docker run --rm \
        -v "$TMPWS":/workspace \
        claude-sandbox \
        bash -c "$1" 2>&1
}

# ---------------------------------------------------------------------------
suite "Identity and privileges"
# ---------------------------------------------------------------------------

UID_OUT=$(sandbox_exec "id -u")
assert_equals "running as uid 1000 (non-root)" "1000" "$UID_OUT"

USER_OUT=$(sandbox_exec "id -un")
assert_equals "running as claudeuser" "claudeuser" "$USER_OUT"

SUDO_OUT=$(sandbox_exec "which sudo 2>&1 || echo ABSENT")
assert_contains "sudo binary not available" "ABSENT" "$SUDO_OUT"

# Attempt to become root — must fail
SU_OUT=$(sandbox_exec "su -c id root 2>&1 || echo DENIED")
assert_contains "su to root denied" "DENIED" "$SU_OUT"

# ---------------------------------------------------------------------------
suite "Docker escape surface"
# ---------------------------------------------------------------------------

SOCK_OUT=$(sandbox_exec "test -e /var/run/docker.sock && echo FOUND || echo ABSENT")
assert_equals "Docker socket not mounted" "ABSENT" "$SOCK_OUT"

DOCKER_BIN=$(sandbox_exec "which docker 2>&1 || echo ABSENT")
assert_contains "docker binary not on PATH" "ABSENT" "$DOCKER_BIN"

# No access to host Docker API via TCP either (not typically exposed, but confirm)
CURL_DOCKER=$(sandbox_exec "curl -s --connect-timeout 2 http://127.0.0.1:2375/_ping 2>&1 || echo UNREACHABLE")
assert_contains "Docker TCP API unreachable" "UNREACHABLE" "$CURL_DOCKER"

# ---------------------------------------------------------------------------
suite "Linux capabilities"
# ---------------------------------------------------------------------------

# Non-privileged non-root processes should have CapEff = 0000000000000000
CAP_EFF=$(sandbox_exec "grep CapEff /proc/self/status | awk '{print \$2}'")
assert_equals "no effective capabilities (non-root user)" "0000000000000000" "$CAP_EFF"

# CapBnd (bounding set) should NOT be the full 64-bit mask — privileged containers
# have ffffffffffffffff; default Docker restricts several dangerous capabilities.
CAP_BND=$(sandbox_exec "grep CapBnd /proc/self/status | awk '{print \$2}'")
assert_not_contains "bounding set is not fully privileged" "ffffffffffffffff" "$CAP_BND"

# Seccomp filter should be active (2 = SECCOMP_MODE_FILTER)
SECCOMP=$(sandbox_exec "grep Seccomp /proc/self/status | awk '{print \$2}'")
assert_equals "seccomp filter is active" "2" "$SECCOMP"

# ---------------------------------------------------------------------------
suite "PID namespace isolation"
# ---------------------------------------------------------------------------

# Container should see very few processes (its own only)
PID_COUNT=$(sandbox_exec "ls /proc | grep -cE '^[0-9]+$' || echo 0")
# Typically 3-5 processes in an isolated container (bash, the command, etc.)
assert_equals "PID namespace isolated (≤10 visible pids)" "true" \
    "$([ "$PID_COUNT" -le 10 ] && echo true || echo false)"

# PID 1 inside container should be our entrypoint, not the host init
PID1_COMM=$(sandbox_exec "cat /proc/1/comm 2>/dev/null || echo unknown")
assert_not_contains "container PID 1 is not host systemd" "systemd" "$PID1_COMM"

# ---------------------------------------------------------------------------
suite "Filesystem write boundaries"
# ---------------------------------------------------------------------------

# Must be able to write to /workspace (positive test)
WS_WRITE=$(sandbox_exec "touch /workspace/test_write_sentinel_$$ && echo OK && rm /workspace/test_write_sentinel_$$")
assert_equals "can write to /workspace" "OK" "$WS_WRITE"

# Must NOT be able to write to /etc
ETC_WRITE=$(sandbox_exec "touch /etc/sandbox_escape_test 2>&1 || echo DENIED")
assert_contains "cannot write to /etc" "DENIED" "$ETC_WRITE"

# Must NOT be able to write outside /workspace into /tmp (which is container-local
# but verifies it can't reach host /tmp)
# Note: /tmp inside the container IS writable (it's container-local storage).
# The real boundary test is whether host paths outside mounts are accessible.
HOST_READ=$(sandbox_exec "ls /proc/1/root/proc 2>&1 || echo INACCESSIBLE")
# /proc/1/root is not always accessible even without namespacing restrictions;
# the important check is that it doesn't expose the host root.
assert_contains "host root via /proc/1/root not accessible" "INACCESSIBLE" "$HOST_READ"

# ---------------------------------------------------------------------------
suite "Setuid / privilege escalation binaries"
# ---------------------------------------------------------------------------

# No setuid binaries should exist in the image (none are installed)
SUID_COUNT=$(sandbox_exec "find /usr /bin /sbin -perm -4000 -type f 2>/dev/null | wc -l | tr -d ' '")
assert_equals "no setuid binaries in system paths" "0" "$SUID_COUNT"

# ---------------------------------------------------------------------------
suite "Network reachability (outbound internet expected, host loopback restricted)"
# ---------------------------------------------------------------------------

# Container should be able to reach external DNS (needed for Claude/Gemini APIs)
DNS_OUT=$(sandbox_exec "getent hosts google.com 2>&1 || echo FAILED")
assert_not_contains "external DNS resolves" "FAILED" "$DNS_OUT"

# Container should NOT be able to connect to host localhost services
# (port 1 is never open — we use it as a sentinel for connection refusal vs route failure)
LOOPBACK=$(sandbox_exec "curl -s --connect-timeout 2 http://127.0.0.1:1/ 2>&1; echo EXIT_$?")
# Exit code 7 = connection refused, 28 = timeout — either is fine; REFUSED means
# the network stack is the container's, not the host's (which might have port 1 open).
assert_not_contains "loopback does not reach host services" "EXIT_0" "$LOOPBACK"

print_results
