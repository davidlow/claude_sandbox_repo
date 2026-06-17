#!/bin/bash

# ==============================================================================
# claude-box — Interactive Claude Code Sandbox
#
# Drops you into a Claude Code session inside an isolated Docker container.
# The container sees only your current project directory. Claude will ask
# for confirmation before executing system-level actions (no auto-approve).
# The container is destroyed automatically when you exit.
#
# USAGE:
#    claude-box [model]
#
# ARGUMENTS:
#    model   (Optional) Claude model to use. Defaults to claude-sonnet-4-6.
#            Examples: claude-haiku-4-5, claude-opus-4-8, claude-fable-5
#
# EXAMPLES:
#    claude-box
#    claude-box claude-opus-4-8
#
# SETUP:
#    Run claude-box-auth once before first use to save your Claude Pro login.
# ==============================================================================

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    sed -n '/^# ====/,/^# ====/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTH_DIR="$SCRIPT_DIR/claude-auth"

if [ ! -d "$AUTH_DIR" ] || [ -z "$(ls -A "$AUTH_DIR" 2>/dev/null)" ]; then
    echo "❌ Error: No Claude credentials found in $AUTH_DIR"
    echo "   Run 'claude-box-auth' first to log in with your Claude Pro account."
    exit 1
fi

CHOSEN_MODEL="${1:-claude-sonnet-4-6}"
SANITIZED_DIR=$(basename "$(pwd)" | tr -cs '[:alnum:]-' '-' | tr '[:upper:]' '[:lower:]')
CONTAINER_NAME="claude-interactive-${SANITIZED_DIR:-sandbox}"

# Extract OAuth tokens from the credentials file and inject them as env vars.
# CLAUDE_CODE_OAUTH_TOKEN bypasses the first-run auth wizard entirely so the
# container goes straight to the chat (or at most the one-time theme picker).
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
    echo "❌ Error: Could not read OAuth token from $AUTH_DIR/.credentials.json"
    echo "   Run 'claude-box-auth' to refresh your credentials."
    exit 1
fi

echo "🛡️  Spawning interactive sandbox using model: $CHOSEN_MODEL"

docker run -it --rm \
  --name "$CONTAINER_NAME" \
  -v "$(pwd)":/workspace \
  -v "$AUTH_DIR":/home/claudeuser/.claude \
  -e CLAUDE_CODE_OAUTH_TOKEN="$OAUTH_TOKEN" \
  -e CLAUDE_CODE_OAUTH_REFRESH_TOKEN="$OAUTH_REFRESH" \
  claude-sandbox \
  claude --model "$CHOSEN_MODEL"
