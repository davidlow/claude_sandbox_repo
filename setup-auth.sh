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

# Claude Code settings (model prefs, theme, etc.)
if [ -f "$HOME/.claude/settings.json" ]; then
    cp "$HOME/.claude/settings.json" "$AUTH_DIR/settings.json"
fi

# Extract OAuth tokens so we can inject them into the bootstrap container.
OAUTH_TOKEN=$(python3 -c "
import json
with open('$AUTH_DIR/.credentials.json') as f:
    print(json.load(f)['claudeAiOauth']['accessToken'])
" 2>/dev/null)
OAUTH_REFRESH=$(python3 -c "
import json
with open('$AUTH_DIR/.credentials.json') as f:
    print(json.load(f)['claudeAiOauth']['refreshToken'])
" 2>/dev/null)

if [ -z "$OAUTH_TOKEN" ]; then
    echo "❌ Could not extract OAuth token from credentials file."
    exit 1
fi

# Bootstrap ~/.claude.json inside the container with a quick non-interactive
# run. Claude Code writes machineID, userID, and feature flags on first start;
# without these fields every TUI launch shows the first-run wizard (theme
# picker + browser auth step). The entrypoint's EXIT trap saves the resulting
# ~/.claude.json back to claude-auth/ so subsequent runs skip the wizard.
echo "🔧 Bootstrapping Claude config (skip first-run wizard)..."
docker run --rm \
    -v "$AUTH_DIR":/home/claudeuser/.claude \
    -v /tmp:/workspace \
    -e CLAUDE_CODE_OAUTH_TOKEN="$OAUTH_TOKEN" \
    -e CLAUDE_CODE_OAUTH_REFRESH_TOKEN="$OAUTH_REFRESH" \
    claude-sandbox \
    claude -p "hello" > /dev/null 2>&1 || true

if [ -f "$AUTH_DIR/.claude.json" ]; then
    echo "✅ Config bootstrapped — first-run wizard will be skipped."
else
    echo "⚠️  Could not bootstrap config. First run may show a setup wizard."
fi
echo ""
echo "✅ Setup complete. Run: claude-box"
