#!/bin/bash
# Unit tests for the freshen_credentials function in lib/launch-lib.sh.
# Uses fixture credential files — never touches real ~/.claude credentials.
# No Docker or network required.
set -eo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
FIXTURE_DIR="$TESTS_DIR/fixtures"

source "$TESTS_DIR/helpers.sh"
source "$REPO_DIR/lib/launch-lib.sh"

# ---------------------------------------------------------------------------
# Mock `claude` — tracks whether it was called via stdout output.
# The mock prints "Authenticated" (as a real `claude auth status` would) and
# exits 0. Since freshen_credentials calls `claude auth status 2>/dev/null`,
# the mock's stdout passes through and can be detected in captured output.
# export -f makes the function available in the subshell created by $(...).
# ---------------------------------------------------------------------------
claude() { echo "Authenticated"; return 0; }
export -f claude

# ---------------------------------------------------------------------------
suite "freshen_credentials — expired token"
# ---------------------------------------------------------------------------
# expiresAt=1000 (1 second after Unix epoch = definitely in the past)

output=$(freshen_credentials "$FIXTURE_DIR/expired_creds.json" 2>&1)
assert_contains "expired: prints refreshing message" "[claude-box] Refreshing OAuth token..." "$output"
assert_contains "expired: calls claude auth status" "Authenticated" "$output"

# ---------------------------------------------------------------------------
suite "freshen_credentials — fresh token"
# ---------------------------------------------------------------------------
# expiresAt=9999999999000 (year 2286 = safely in the future)

output=$(freshen_credentials "$FIXTURE_DIR/fresh_creds.json" 2>&1)
assert_contains "fresh: prints fresh message" "[claude-box] OAuth token is fresh." "$output"
assert_not_contains "fresh: does NOT call claude" "Authenticated" "$output"

# ---------------------------------------------------------------------------
suite "freshen_credentials — missing expiresAt field"
# ---------------------------------------------------------------------------
# claudeAiOauth present but expiresAt absent → Python exits non-zero → refresh

output=$(freshen_credentials "$FIXTURE_DIR/no_expiry_creds.json" 2>&1)
assert_contains "no expiry: prints refreshing message" "[claude-box] Refreshing OAuth token..." "$output"
assert_contains "no expiry: calls claude auth status" "Authenticated" "$output"

# ---------------------------------------------------------------------------
suite "freshen_credentials — non-existent credentials file"
# ---------------------------------------------------------------------------
# Returns 0 immediately; the caller's own guard handles missing files

set +e
output=$(freshen_credentials "/nonexistent/path/.credentials.json" 2>&1)
exit_code=$?
set -e
assert_equals "missing file: returns 0" "0" "$exit_code"
assert_not_contains "missing file: prints nothing" "Refreshing" "$output"
assert_not_contains "missing file: does NOT call claude" "Authenticated" "$output"

# ---------------------------------------------------------------------------
suite "freshen_credentials — CREDS_REFRESH_BUFFER_SECONDS override"
# ---------------------------------------------------------------------------
# Set an extremely large buffer so fresh_creds appears expired relative to it.
# expiresAt = 9999999999000 ms ≈ year 2286. With buffer = 9999999999 seconds
# (~317 years), threshold = now + 317 years. Since expiresAt (year 2286) is
# within that buffer, the function should trigger a refresh.

output=$(CREDS_REFRESH_BUFFER_SECONDS=9999999999 \
    freshen_credentials "$FIXTURE_DIR/fresh_creds.json" 2>&1)
assert_contains "large buffer: triggers refresh on otherwise-fresh token" \
    "[claude-box] Refreshing OAuth token..." "$output"

print_results
