#!/bin/bash

# ==============================================================================
# claude-box-auth — One-time Claude Pro OAuth setup
#
# Logs you into Claude.ai using your Claude Pro account and saves the
# credentials inside this repo's claude-auth/ directory. The launch scripts
# mount that directory into every sandbox container so you are never asked
# to log in again.
#
# Run this once after cloning the repo, or whenever your session expires.
#
# USAGE:
#    claude-box-auth
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTH_DIR="$SCRIPT_DIR/claude-auth"

if ! command -v claude &>/dev/null; then
    echo "❌ 'claude' CLI not found on this machine."
    echo "   Install it with:  npm install -g @anthropic-ai/claude-code"
    echo "   Then re-run this script."
    exit 1
fi

mkdir -p "$AUTH_DIR"

echo "🔐 Logging into Claude.ai (Claude Pro)..."
echo "   Credentials will be saved to: $AUTH_DIR"
echo "   A browser window will open — complete the login there."
echo ""

# CLAUDE_CONFIG_DIR redirects where Claude Code reads/writes its config and
# credentials, keeping this sandbox's session isolated from ~/.claude/ on the host.
CLAUDE_CONFIG_DIR="$AUTH_DIR" claude login

# Verify something was actually written
if [ -z "$(ls -A "$AUTH_DIR" 2>/dev/null)" ]; then
    echo ""
    echo "⚠️  Nothing was written to $AUTH_DIR."
    echo "   Your Claude Code version may not support CLAUDE_CONFIG_DIR."
    echo "   Falling back: copying credentials from ~/.claude/ ..."
    if [ -d "$HOME/.claude" ] && [ -n "$(ls -A "$HOME/.claude" 2>/dev/null)" ]; then
        cp -r "$HOME/.claude/." "$AUTH_DIR/"
        echo "✅ Credentials copied from ~/.claude/ to $AUTH_DIR"
    else
        echo ""
        echo "❌ No credentials found in ~/.claude/ either."
        echo "   Run:  claude login"
        echo "   Then: cp -r ~/.claude/. \"$AUTH_DIR/\""
        exit 1
    fi
fi

echo ""
echo "✅ Done! You can now run: claude-box"
