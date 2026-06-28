#!/bin/bash
# lib/logging.sh — bash implementation of all /logging skill actions
#
# Usage:
#   LOG_FILE=$(bash lib/logging.sh init <pipeline> <task-description> <model>)
#   bash lib/logging.sh section <log-file> <section-title> [content-file]
#   bash lib/logging.sh note    <log-file> <section-title> <text>
#   bash lib/logging.sh outcome <log-file> <status> [notes]
#   bash lib/logging.sh progress <phase> <status> <detail>
#   bash lib/logging.sh read [--task-id <id>] [pipeline]
#
# log-file: pass the absolute path captured from init, or "-" to auto-resolve
#           from docs/.logging-current (falls back to newest in docs/decisions/).
# init prints the absolute path to stdout — capture with $().

set -eo pipefail

ACTION="${1:?Usage: logging.sh <init|section|note|outcome|progress|read> <args>}"
shift

_resolve_log() {
    local arg="${1:-}"
    if [[ -n "$arg" && "$arg" != "-" && -f "$arg" ]]; then
        echo "$arg"; return 0
    fi
    local cur
    cur=$(cat "docs/.logging-current" 2>/dev/null | head -1 || true)
    if [[ -n "$cur" && -f "$cur" ]]; then
        echo "$cur"; return 0
    fi
    local newest
    newest=$(ls -t docs/decisions/*.md 2>/dev/null | head -1 || true)
    if [[ -n "$newest" ]]; then
        echo "$newest"; return 0
    fi
    echo "❌ logging.sh: no active log found" >&2
    return 1
}

case "$ACTION" in

# ---- init -------------------------------------------------------------------
init)
    PIPELINE="${1:?pipeline required}"
    TASK_DESC="${2:?task description required}"
    MODEL="${3:-claude-sonnet-4-6}"

    mkdir -p docs/decisions docs/progress

    TIMESTAMP=$(date '+%Y%m%d_%H%M')
    SLUG=$(echo "$TASK_DESC" \
           | tr '[:upper:]' '[:lower:]' \
           | sed 's/[^a-z0-9]/-/g' \
           | sed 's/-\{2,\}/-/g' \
           | sed 's/^-//;s/-$//' \
           | cut -c1-40)
    LOG_PATH="docs/decisions/${TIMESTAMP}_${SLUG}_${PIPELINE}.md"
    DATE_HUMAN=$(date '+%Y-%m-%d %H:%M')

    cat > "$LOG_PATH" <<EOF
# ${PIPELINE}: ${TASK_DESC}

**Date:** ${DATE_HUMAN}
**Pipeline:** ${PIPELINE}
**Model:** ${MODEL}
**Status:** in-progress

## Task

${TASK_DESC}
EOF

    ABS=$(realpath "$LOG_PATH")
    echo "$ABS" > docs/.logging-current
    echo "$ABS" > "docs/.logging-${PIPELINE}-last"
    echo "$ABS"
    ;;

# ---- section ----------------------------------------------------------------
section)
    LOG_FILE=$(_resolve_log "${1:-}")
    TITLE="${2:?section title required}"
    CONTENT_FILE="${3:-}"
    {
        echo ""
        echo "## ${TITLE}"
        echo ""
        if [[ -n "$CONTENT_FILE" && -f "$CONTENT_FILE" ]]; then
            cat "$CONTENT_FILE"
        else
            echo "*(not available)*"
        fi
    } >> "$LOG_FILE"
    ;;

# ---- note -------------------------------------------------------------------
note)
    LOG_FILE=$(_resolve_log "${1:-}")
    TITLE="${2:?note title required}"
    TEXT="${3:?note text required}"
    {
        echo ""
        echo "## ${TITLE}"
        echo ""
        echo "${TEXT}"
    } >> "$LOG_FILE"
    ;;

# ---- outcome ----------------------------------------------------------------
outcome)
    LOG_FILE=$(_resolve_log "${1:-}")
    STATUS="${2:?status required}"
    NOTES="${3:-}"

    sed -i "s/\*\*Status:\*\* in-progress/**Status:** ${STATUS}/g" "$LOG_FILE"
    {
        echo ""
        echo "## Outcome"
        echo ""
        echo "**Result:** ${STATUS}"
        [[ -n "$NOTES" ]] && { echo ""; echo "${NOTES}"; }
    } >> "$LOG_FILE"

    ABS=$(realpath "$LOG_FILE")
    echo "$ABS" > docs/.logging-last-completed
    rm -f docs/.logging-current
    ;;

# ---- progress ---------------------------------------------------------------
progress)
    PHASE="${1:?phase required}"
    STATUS="${2:?status required}"
    DETAIL="${3:-}"
    DETAIL="${DETAIL:0:200}"

    mkdir -p docs/progress
    TASK_LABEL="${ORIGINAL_TASK_PROMPT:0:80}"
    TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    printf '{"timestamp":"%s","source":"skill","phase":"%s","status":"%s","detail":"%s","task":"%s"}\n' \
        "$TS" "$PHASE" "$STATUS" "$DETAIL" "$TASK_LABEL" \
        >> docs/progress/current.jsonl
    ;;

# ---- read -------------------------------------------------------------------
read)
    TASK_ID=""
    PIPELINE_FILTER=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --task-id) TASK_ID="$2"; shift 2 ;;
            *)         PIPELINE_FILTER="$1"; shift ;;
        esac
    done

    if [[ -n "$TASK_ID" ]]; then
        LOG_DIR="docs/${TASK_ID}/decisions"
    else
        LOG_DIR="docs/decisions"
        if [[ -f "docs/.logging-current" ]]; then
            ACTIVE=$(cat docs/.logging-current 2>/dev/null || true)
            if [[ -n "$ACTIVE" && -f "$ACTIVE" ]]; then
                echo "=== Active log: $ACTIVE ==="
                head -20 "$ACTIVE"
                echo ""
            fi
        fi
    fi

    echo "=== Recent logs in ${LOG_DIR} ==="
    if [[ -n "$PIPELINE_FILTER" ]]; then
        ls -lt "${LOG_DIR}/"*"_${PIPELINE_FILTER}.md" 2>/dev/null | head -20 || echo "(none)"
    else
        ls -lt "${LOG_DIR}/"*.md 2>/dev/null | head -20 || echo "(none)"
    fi
    echo ""

    if [[ -n "$PIPELINE_FILTER" ]]; then
        RECENT=$(ls -t "${LOG_DIR}/"*"_${PIPELINE_FILTER}.md" 2>/dev/null | head -3 || true)
    else
        RECENT=$(ls -t "${LOG_DIR}/"*.md 2>/dev/null | head -3 || true)
    fi
    for f in $RECENT; do
        [[ -f "$f" ]] || continue
        echo "--- $f ---"
        head -20 "$f"
        echo ""
    done
    ;;

*)
    echo "❌ logging.sh: unknown action '$ACTION'" >&2
    echo "Usage: logging.sh <init|section|note|outcome|progress|read> <args>" >&2
    exit 1
    ;;
esac
