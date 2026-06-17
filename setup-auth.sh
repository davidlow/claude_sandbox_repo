#!/bin/bash
set -euo pipefail

# ==============================================================================
# claude-box-auth — One-time Claude Pro OAuth setup
#
# Runs `claude auth login` inside the sandbox container so the same Claude Code
# version is used for auth as for actual runs. --network host shares the host's
# localhost so the browser OAuth callback (http://localhost:PORT/callback) is
# reachable when you complete the login. Credentials are saved into claude-auth/
# in this repo and mounted into every future sandbox run — you are never
# prompted to log in again.
#
# Run this once after cloning the repo, or whenever your session expires.
#
# USAGE:
#    claude-box-auth
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTH_DIR="$SCRIPT_DIR/claude-auth"

mkdir -p "$AUTH_DIR"

echo "🔐 Logging into Claude.ai (Claude Pro)..."
echo "   A browser window will open — complete the login there."
echo "   Credentials will be saved to: $AUTH_DIR"
echo ""

# Run login inside the sandbox container, not on the host:
#   - Guarantees the same Claude Code version is used for auth and execution.
#   - --network host shares the host's localhost so the OAuth callback URL
#     (http://localhost:PORT/callback) opened in your browser can reach the
#     local HTTP server that Claude Code starts inside the container.
#   - claude-auth/ is mounted as ~/.claude so credentials persist after exit.
docker run -it --rm \
  --network host \
  -v "$AUTH_DIR":/home/claudeuser/.claude \
  claude-sandbox \
  claude auth login --claudeai

if [ -z "$(ls -A "$AUTH_DIR" 2>/dev/null)" ]; then
    echo ""
    echo "❌ No credentials were saved to $AUTH_DIR."
    echo "   Try running this script again."
    exit 1
fi

echo ""
echo "✅ Done! You can now run: claude-box"
