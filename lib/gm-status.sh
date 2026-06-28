#!/bin/bash
# lib/gm-status.sh — deterministic gm-status.md management
#
# Usage:
#   bash lib/gm-status.sh init     <base-branch> <total-tasks> [timestamp]
#   bash lib/gm-status.sh set-task <num> <skill> <task-text>
#   bash lib/gm-status.sh update   <num> <branch> <status>
#   bash lib/gm-status.sh done     <n-merged> <n-failed>
#
# init:     writes gm-status.md header + N placeholder rows
# set-task: fills skill + task-text for row N (called after task list is known)
# update:   fills branch + status for row N (called after branch created or task completes)
# done:     updates the progress header to COMPLETE
#
# Note: task-text must not contain the pipe character (|) as it is used as the
#       markdown table column separator.

set -eo pipefail

ACTION="${1:?Usage: gm-status.sh <init|set-task|update|done> <args>}"
shift
FILE="gm-status.md"

# Replace row N's fields using awk. Pass "" to leave a field unchanged.
# Args: num skill task branch status
_edit_row() {
    local num="$1" new_skill="$2" new_task="$3" new_branch="$4" new_status="$5"
    awk -F'|' -v n="$num" \
        -v ns="$new_skill" -v nt="$new_task" -v nb="$new_branch" -v nx="$new_status" \
    'BEGIN { OFS="|" }
    {
        # Only process data rows: 7 fields (| # | ... | ... | ... | ... |)
        if (NF == 7) {
            rn = $2; gsub(/ /, "", rn)
            if (rn+0 == n+0 && rn+0 > 0) {
                if (ns != "") $3 = " " ns " "
                if (nt != "") $4 = " " nt " "
                if (nb != "") $5 = " " nb " "
                if (nx != "") $6 = " " nx " "
            }
        }
        print
    }' "$FILE" > "${FILE}.tmp" && mv "${FILE}.tmp" "$FILE"
}

_update_progress_line() {
    local done total hhmm
    # Count data rows (first cell is a number > 0)
    total=$(awk -F'|' 'NF==7{rn=$2; gsub(/ /,"",rn); if(rn+0>0) c++} END{print c+0}' "$FILE")
    # Count rows where status cell does not contain "pending"
    done=$(awk -F'|' 'NF==7{rn=$2; gsub(/ /,"",rn); st=$6; gsub(/ /,"",st); if(rn+0>0 && st!="" && st!="⏳pending" && index(st,"pending")==0) c++} END{print c+0}' "$FILE")
    hhmm=$(date '+%H:%M')
    sed -i "s/\*\*Progress:\*\*.*/**Progress:** ${done} \/ ${total} tasks complete (last updated: ${hhmm})/" "$FILE"
}

case "$ACTION" in

# ---- init -------------------------------------------------------------------
init)
    BASE="${1:?base-branch required}"
    TOTAL="${2:?total-tasks required}"
    STARTED="${3:-$(date '+%Y-%m-%d %H:%M')}"
    {
        echo "# GM Status"
        echo ""
        echo "**Started:** ${STARTED}"
        echo "**Base branch:** ${BASE}"
        echo "**Progress:** 0 / ${TOTAL} tasks complete"
        echo ""
        echo "| # | Skill | Task | Branch | Status |"
        echo "|---|-------|------|--------|--------|"
        for i in $(seq 1 "$TOTAL"); do
            echo "| ${i} | - | (pending) | - | ⏳ pending |"
        done
    } > "$FILE"
    ;;

# ---- set-task ---------------------------------------------------------------
set-task)
    NUM="${1:?num required}"
    SKILL="${2:?skill required}"
    TASK_TEXT="${3:?task-text required}"
    _edit_row "$NUM" "$SKILL" "$TASK_TEXT" "" ""
    ;;

# ---- update -----------------------------------------------------------------
update)
    NUM="${1:?num required}"
    BRANCH="${2:?branch required}"
    STATUS="${3:?status required}"
    _edit_row "$NUM" "" "" "$BRANCH" "$STATUS"
    _update_progress_line
    ;;

# ---- done -------------------------------------------------------------------
done)
    MERGED="${1:-0}"
    FAILED="${2:-0}"
    sed -i "s/\*\*Progress:\*\*.*/**Status: COMPLETE** — ${MERGED} merged, ${FAILED} failed/" "$FILE"
    ;;

*)
    echo "❌ gm-status.sh: unknown action '$ACTION'" >&2
    exit 1
    ;;
esac
