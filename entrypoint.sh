#!/bin/bash

# Claude Code requires ~/.claude.json in the home directory (not inside ~/.claude/).
# This file lives outside the mounted credentials volume so it's lost when an
# ephemeral container exits. Restore it here on every container start from
# the copy that setup-auth.sh places inside the mounted volume.
if [ ! -f "$HOME/.claude.json" ]; then
    if [ -f "$HOME/.claude/.claude.json" ]; then
        # Explicit copy placed by claude-box-auth (setup-auth.sh)
        cp "$HOME/.claude/.claude.json" "$HOME/.claude.json"
    else
        # Fallback: use the auto-generated backup from a prior login
        BACKUP=$(ls -t "$HOME/.claude/backups/.claude.json.backup."* 2>/dev/null | head -1)
        if [ -n "$BACKUP" ]; then
            cp "$BACKUP" "$HOME/.claude.json"
        fi
    fi
fi

exec "$@"
