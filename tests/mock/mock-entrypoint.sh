#!/bin/bash
# Minimal entrypoint for the mock sandbox image.
# Mirrors real entrypoint.sh structure (backup/restore .claude.json) but
# without the production paths, so test containers start fast and clean.
CLAUDE_HOME_CONFIG="$HOME/.claude.json"
MOUNTED_CONFIG="$HOME/.claude/.claude.json"
[ -f "$MOUNTED_CONFIG" ] && cp "$MOUNTED_CONFIG" "$CLAUDE_HOME_CONFIG"
trap 'cp "$CLAUDE_HOME_CONFIG" "$MOUNTED_CONFIG" 2>/dev/null || true' EXIT
"$@"
