#!/bin/bash
set -eo pipefail
# Note: -u (nounset) is intentionally omitted. Claude Code's bash shell
# integration installs hooks that reference $ZSH_VERSION, which is unset in
# bash. With -u active, those hooks error-out and break docker pipelines.

# ==============================================================================
# claude-box-auth — Copy Claude Pro credentials into the sandbox auth folder
#
# Copies credential and config files from your host Claude Code installation
# into this repo's claude-auth/ directory. The launch scripts mount that
# directory into every sandbox container so you are never prompted to log in.
#
# This runs on the HOST (not inside Docker), so the browser OAuth flow works
# normally. You are already logged in if you use Claude Code on this machine —
# just run this script once to make those credentials available to the sandbox.
#
# When your session expires:
#   1. Re-authenticate on the host:  claude auth login --claudeai
#   2. Re-copy into the sandbox:     claude-box-auth
#
# USAGE:
#    claude-box-auth
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTH_DIR="$SCRIPT_DIR/claude-auth"

if [ ! -f "$HOME/.claude/.credentials.json" ]; then
    echo "❌ No Claude credentials found at ~/.claude/.credentials.json"
    echo ""
    echo "   Log in first by running:"
    echo "     claude auth login --claudeai"
    echo ""
    echo "   Then re-run this script."
    exit 1
fi

mkdir -p "$AUTH_DIR"

echo "🔐 Copying Claude Pro credentials into sandbox auth folder..."
echo "   Source:      ~/.claude/"
echo "   Destination: $AUTH_DIR"
echo ""

# OAuth tokens — the core credential file
cp "$HOME/.claude/.credentials.json" "$AUTH_DIR/.credentials.json"
chmod 600 "$AUTH_DIR/.credentials.json"

# Claude Code's main config file lives in HOME (not inside .claude/).
# Store it as .claude.json inside claude-auth/ so the container entrypoint
# can restore it to the home directory on every container start.
if [ -f "$HOME/.claude.json" ]; then
    cp "$HOME/.claude.json" "$AUTH_DIR/.claude.json"
fi

# Claude Code settings (model prefs, theme, etc.)
if [ -f "$HOME/.claude/settings.json" ]; then
    cp "$HOME/.claude/settings.json" "$AUTH_DIR/settings.json"
fi

# Verify the credentials work inside the container.
# Capture to a variable first to avoid pipefail interacting with the pipeline.
echo "🔍 Verifying credentials..."
AUTH_STATUS=$(docker run --rm \
    -v "$AUTH_DIR":/home/claudeuser/.claude \
    claude-sandbox \
    claude auth status 2>&1) || true

if echo "$AUTH_STATUS" | grep -q '"loggedIn": true'; then
    echo "✅ Credentials verified — Claude Pro subscription active."
    echo ""
    echo "   You can now run: claude-box"
else
    echo "❌ Credentials did not verify inside the container."
    echo "   Auth status returned:"
    echo "$AUTH_STATUS"
    echo ""
    echo "   Try re-authenticating: claude auth login --claudeai"
    exit 1
fi
