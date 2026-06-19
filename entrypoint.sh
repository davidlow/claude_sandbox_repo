#!/bin/bash

# Claude Code requires ~/.claude.json in the home directory (not inside ~/.claude/).
# This file is outside the mounted credentials volume, so it's lost when the
# ephemeral container exits. We restore it from the mounted volume on start and
# save it back on exit so settings (theme, onboarding state) survive across runs.

CLAUDE_HOME_CONFIG="$HOME/.claude.json"
MOUNTED_CONFIG="$HOME/.claude/.claude.json"

# Restore from the persisted copy inside the mounted volume.
# On the very first run neither file exists; Claude's setup wizard fires once,
# the user picks a theme, and the trap below saves the result for future runs.
if [ -f "$MOUNTED_CONFIG" ]; then
    cp "$MOUNTED_CONFIG" "$CLAUDE_HOME_CONFIG"
fi

# Save .claude.json back to the mounted volume on exit so theme and onboarding
# state survive the next container start.
trap 'cp "$CLAUDE_HOME_CONFIG" "$MOUNTED_CONFIG" 2>/dev/null || true' EXIT

"$@"
