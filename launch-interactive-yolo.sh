#!/bin/bash

[ -f "$(dirname "${BASH_SOURCE[0]}")/.env.local" ] && source "$(dirname "${BASH_SOURCE[0]}")/.env.local"

# ==============================================================================
# claude-box-yolo — Interactive Claude Code Sandbox (auto-approve mode)
#
# Like claude-box, but passes --dangerously-skip-permissions so Claude never
# stops to ask for confirmation before running commands or editing files.
# Use when you trust the task and want uninterrupted execution.
# The container is destroyed automatically when you exit.
#
# USAGE:
#    claude-box-yolo [model]
#
# ARGUMENTS:
#    model   (Optional) Claude model to use. Defaults to claude-sonnet-4-6.
#            Examples: claude-haiku-4-5, claude-opus-4-8, claude-fable-5
#
# EXAMPLES:
#    claude-box-yolo
#    claude-box-yolo claude-opus-4-8
#
# SETUP:
#    Run claude-box-auth once before first use to bootstrap the config.
# ==============================================================================

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    sed -n '/^# ====/,/^# ====/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
    exit 0
fi

CREDS="$HOME/.claude/.credentials.json"
if [ ! -f "$CREDS" ]; then
    echo "❌ Error: No Claude credentials found at $CREDS"
    echo "   Log in with: claude auth login --claudeai"
    exit 1
fi

CHOSEN_MODEL="${1:-claude-sonnet-4-6}"
SANITIZED_DIR=$(basename "$(pwd)" | tr -cs '[:alnum:]-' '-' | tr '[:upper:]' '[:lower:]')
CONTAINER_NAME="claude-interactive-yolo-${SANITIZED_DIR:-sandbox}-$$"

OAUTH_TOKEN=$(python3 -c "
import json
with open('$CREDS') as f:
    print(json.load(f)['claudeAiOauth']['accessToken'])
" 2>/dev/null)
OAUTH_REFRESH=$(python3 -c "
import json
with open('$CREDS') as f:
    print(json.load(f)['claudeAiOauth']['refreshToken'])
" 2>/dev/null)

if [ -z "$OAUTH_TOKEN" ]; then
    echo "❌ Error: Could not read OAuth token from $CREDS"
    echo "   Try: claude auth login --claudeai"
    exit 1
fi

echo "⚡ Spawning auto-approve interactive sandbox using model: $CHOSEN_MODEL"

source "$(dirname "$0")/lib/launch-lib.sh"
source "$(dirname "$0")/lib/progress-lib.sh"
write_progress_event "session" "started" "Interactive session starting (model: $CHOSEN_MODEL)" "interactive"
ensure_logging_dirs

docker run -it --rm \
  --name "$CONTAINER_NAME" \
  -v "$(pwd)":/workspace \
  -v "$HOME/.claude":/home/claudeuser/.claude \
  -e CLAUDE_CODE_OAUTH_TOKEN="$OAUTH_TOKEN" \
  -e CLAUDE_CODE_OAUTH_REFRESH_TOKEN="$OAUTH_REFRESH" \
  -e GEMINI_API_KEY="${GEMINI_API_KEY:-}" \
  claude-sandbox \
  claude --model "$CHOSEN_MODEL" --dangerously-skip-permissions
write_progress_event "session" "completed" "Interactive session ended" "interactive"
