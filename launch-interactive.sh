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
# ENVIRONMENT:
#    ANTHROPIC_API_KEY   Required. Your Anthropic API key.
# ==============================================================================

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    sed -n '/^# ====/,/^# ====/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
    exit 0
fi

if [ -z "$ANTHROPIC_API_KEY" ]; then
    echo "❌ Error: ANTHROPIC_API_KEY environment variable is not set on your host system."
    exit 1
fi

CHOSEN_MODEL="${1:-claude-sonnet-4-6}"
SANITIZED_DIR=$(basename "$(pwd)" | tr -cs '[:alnum:]-' '-' | tr '[:upper:]' '[:lower:]')
CONTAINER_NAME="claude-interactive-${SANITIZED_DIR:-sandbox}"

echo "🛡️  Spawning interactive sandbox using model: $CHOSEN_MODEL"

docker run -it --rm \
  --name "$CONTAINER_NAME" \
  -v "$(pwd)":/workspace \
  -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  claude-sandbox \
  claude --model "$CHOSEN_MODEL"
