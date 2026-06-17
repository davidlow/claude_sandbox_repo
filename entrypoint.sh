#!/bin/bash

# Claude Code expects a .claude.json config file in the home directory
# (not inside ~/.claude/). This file is created during `claude auth login`
# but lives outside the mounted credentials volume, so it's lost when an
# ephemeral container exits. The login process writes a backup into the
# mounted volume at ~/.claude/backups/. Restore from that backup here so
# every fresh container starts with the config in place.
if [ ! -f "$HOME/.claude.json" ]; then
    BACKUP=$(ls -t "$HOME/.claude/backups/.claude.json.backup."* 2>/dev/null | head -1)
    if [ -n "$BACKUP" ]; then
        cp "$BACKUP" "$HOME/.claude.json"
    fi
fi

exec "$@"
