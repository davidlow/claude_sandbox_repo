#!/bin/bash

if [ -z "$ANTHROPIC_API_KEY" ]; then
    echo "❌ Error: ANTHROPIC_API_KEY environment variable is not set on your host system."
    exit 1
fi

# Default to sonnet if no model argument is passed
CHOSEN_MODEL="${1:-claude-sonnet-4-6}"

echo "🛡️  Spawning interactive sandbox using model: $CHOSEN_MODEL"

docker run -it --rm \
  --name "claude-interactive-$(basename "$(pwd)")" \
  -v "$(pwd)":/workspace \
  -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  claude-sandbox \
  claude --model "$CHOSEN_MODEL"
