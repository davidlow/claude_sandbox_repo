#!/bin/bash
set -eo pipefail
# Note: -u (nounset) omitted — Claude Code's bash hooks reference $ZSH_VERSION
# which is unset in bash; -u would break docker pipelines.

# ==============================================================================
# claude-box-auth — One-time sandbox config bootstrap
#
# Copies ~/.claude.json into ~/.claude/ so the Docker entrypoint can restore
# it inside the container (Claude Code expects it in HOME, not inside ~/.claude).
# Then runs a quick non-interactive call inside the container to ensure Claude's
# first-run wizard state is fully initialised — after this, claude-box goes
# straight to the chat with no wizard.
#
# You only need to run this once, or after re-installing Claude Code.
#
# USAGE:
#    claude-box-auth
# ==============================================================================

CREDS="$HOME/.claude/.credentials.json"

if [ ! -f "$CREDS" ]; then
    echo "❌ No Claude credentials found at $CREDS"
    echo "   Log in first:  claude auth login --claudeai"
    exit 1
fi

# Store ~/.claude.json inside ~/.claude/ so the container entrypoint can
# restore it to the home directory on every run.
if [ -f "$HOME/.claude.json" ]; then
    cp "$HOME/.claude.json" "$HOME/.claude/.claude.json"
    echo "✅ Copied ~/.claude.json into ~/.claude/.claude.json"
else
    echo "⚠️  ~/.claude.json not found — will be created on first run."
fi

# Token freshness is checked automatically by launch-interactive.sh and
# launch-scripted.sh; this script is only needed for first-time bootstrap
# or after a full re-login.
# Extract tokens for the bootstrap call.
OAUTH_TOKEN=$(python3 -c "
import json
with open('$CREDS') as f:
    print(json.load(f)['claudeAiOauth']['accessToken'])
" 2>/dev/null)

if [ -z "$OAUTH_TOKEN" ]; then
    echo "❌ Could not read OAuth token from $CREDS"
    exit 1
fi

# Run one non-interactive call inside the sandbox to let Claude Code write
# machineID, userID, and feature flags into ~/.claude.json. Without this
# the TUI shows the first-run wizard on every launch.
echo "🔧 Bootstrapping first-run config..."
docker run --rm \
    -v "$HOME/.claude":/home/claudeuser/.claude \
    -v /tmp:/workspace \
    -e CLAUDE_CODE_OAUTH_TOKEN="$OAUTH_TOKEN" \
    claude-sandbox \
    claude -p "hello" > /dev/null 2>&1 || true

echo "✅ Done. Run: claude-box"
