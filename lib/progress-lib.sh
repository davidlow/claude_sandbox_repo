#!/bin/bash
# Pure helper for writing real-time progress events to docs/progress/current.jsonl.
# Source this file; do not execute it directly.
#
# Usage:
#   source "$(dirname "$0")/lib/progress-lib.sh"
#   write_progress_event PHASE STATUS DETAIL [TASK]
#
# PHASE:  free-form label, e.g. "setup", "attempt-1", "compact", "done"
# STATUS: started | active | completed | failed | retrying | rate-limited
# DETAIL: human-readable string (max 200 chars recommended)
# TASK:   first 80 chars of the task prompt; defaults to "" if omitted
#
# Appends one JSON line to ./docs/progress/current.jsonl (relative to pwd).
# Creates docs/progress/ if it does not exist.
# Non-fatal: prints a warning to stderr on write failure and returns 0.

write_progress_event() {
    local phase="${1:-}"
    local status="${2:-}"
    local detail="${3:-}"
    local task="${4:-}"

    # Escape double-quotes in user-supplied strings to keep the JSON valid.
    local safe_detail safe_task
    safe_detail="${detail//\"/\\\"}"
    safe_task="${task//\"/\\\"}"

    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "")

    mkdir -p docs/progress 2>/dev/null || true

    local json_line
    json_line=$(printf '{"timestamp":"%s","source":"host","phase":"%s","status":"%s","detail":"%s","task":"%s"}' \
        "$timestamp" "$phase" "$status" "$safe_detail" "$safe_task")

    if ! printf '%s\n' "$json_line" >> docs/progress/current.jsonl 2>/dev/null; then
        printf '[progress-lib] warning: could not write to docs/progress/current.jsonl\n' >&2
    fi
    return 0
}
