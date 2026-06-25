#!/usr/bin/env bash
# lib/why.sh — Enhanced git-blame with decision log context.
#
# Usage:
#   lib/why.sh <file>[:<line>]
#   lib/why.sh <file>[:<function-name>]
#   lib/why.sh --help
#
# Shows git blame for a file or specific line/function, then surfaces decision
# log entries from docs/decisions/ that were active when those lines were committed.

set -eo pipefail

# ---------------------------------------------------------------------------
# Resolve sibling dependency
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_SEARCH="${SCRIPT_DIR}/log-search.sh"

if [[ ! -f "$LOG_SEARCH" || ! -x "$LOG_SEARCH" ]]; then
    echo "Error: log-search.sh not found or not executable at: $LOG_SEARCH" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
print_usage() {
    cat <<'EOF'
Usage: lib/why.sh [--window <hours>] <file>[:<line>|:<function>]
       lib/why.sh --help

Positional argument:
  <file>              Blame the entire file (up to 5 distinct commits shown)
  <file>:<line>       Blame a specific line number
  <file>:<function>   Blame lines matching the function/identifier name

Flags:
  --window <hours>    Informational: look-back window in hours (default: 24).
                      log-search.sh always uses a 24h window for commit lookup.
  --help              Print this usage and exit 0

Environment:
  LOGS_DIR            Override the decision logs directory (default: docs/decisions/)
EOF
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
TARGET=""
WINDOW_HOURS="24"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help)
            print_usage
            exit 0
            ;;
        --window)
            if [[ -z "${2:-}" ]]; then
                echo "Error: --window requires a value" >&2
                exit 1
            fi
            WINDOW_HOURS="$2"
            shift 2
            ;;
        -*)
            echo "Error: unknown flag: $1" >&2
            echo "" >&2
            print_usage >&2
            exit 1
            ;;
        *)
            if [[ -z "$TARGET" ]]; then
                TARGET="$1"
                shift
            else
                echo "Error: unexpected argument: $1" >&2
                echo "" >&2
                print_usage >&2
                exit 1
            fi
            ;;
    esac
done

if [[ -z "$TARGET" ]]; then
    print_usage >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Parse TARGET into FILE and SPECIFIER
# ---------------------------------------------------------------------------
FILE="${TARGET%%:*}"
SPECIFIER=""
if [[ "$TARGET" == *:* ]]; then
    SPECIFIER="${TARGET#*:}"
fi

if [[ ! -f "$FILE" ]]; then
    echo "Error: file not found: $FILE" >&2
    exit 1
fi

# Determine SPEC_TYPE
SPEC_TYPE="file"
LINE=""
FUNC_PATTERN=""

if [[ -n "$SPECIFIER" ]]; then
    if [[ "$SPECIFIER" =~ ^[0-9]+$ ]]; then
        SPEC_TYPE="line"
        LINE="$SPECIFIER"
    else
        SPEC_TYPE="function"
        FUNC_PATTERN="$SPECIFIER"
    fi
fi

# ---------------------------------------------------------------------------
# Run git blame
# ---------------------------------------------------------------------------
BLAME_OUT=""
case "$SPEC_TYPE" in
    file)
        BLAME_OUT="$(git blame --date=iso-strict "$FILE")"
        ;;
    line)
        BLAME_OUT="$(git blame --date=iso-strict -L "${LINE},${LINE}" "$FILE")"
        ;;
    function)
        set +e
        BLAME_OUT="$(git blame --date=iso-strict -L "/^[[:space:]]*${FUNC_PATTERN}/,+20" "$FILE" 2>/dev/null)"
        BLAME_RC=$?
        set -e
        if [[ $BLAME_RC -ne 0 || -z "$BLAME_OUT" ]]; then
            echo "Warning: function pattern '${FUNC_PATTERN}' not matched, falling back to full file blame" >&2
            BLAME_OUT="$(git blame --date=iso-strict "$FILE")"
        fi
        ;;
esac

# ---------------------------------------------------------------------------
# Print blame section
# ---------------------------------------------------------------------------
echo "=== git blame: ${TARGET} ==="
echo "$BLAME_OUT"
echo ""

# ---------------------------------------------------------------------------
# Extract distinct commits (cap at 5)
# ---------------------------------------------------------------------------
mapfile -t COMMITS < <(echo "$BLAME_OUT" | awk '{print $1}' | sed 's/^\^//' | grep -v '^0\{8\}' | sort -u | head -5)

# ---------------------------------------------------------------------------
# Print context section
# ---------------------------------------------------------------------------
echo "=== Decision log context ==="

if [[ ${#COMMITS[@]} -eq 0 ]]; then
    echo "[File has no committed lines — no decision log context available]"
    exit 0
fi

FIRST_COMMIT=true
for COMMIT in "${COMMITS[@]}"; do
    if [[ "$FIRST_COMMIT" != "true" ]]; then
        echo ""
    fi
    FIRST_COMMIT=false

    COMMIT_DATE="$(git log --format='%aI' -1 "$COMMIT" 2>/dev/null || true)"
    if [[ -z "$COMMIT_DATE" ]]; then
        echo "[Warning: could not resolve commit ${COMMIT:0:7}]"
        continue
    fi

    COMMIT_MSG="$(git log --format='%h %s' -1 "$COMMIT" 2>/dev/null || true)"
    echo "Commit ${COMMIT_MSG} (${COMMIT_DATE}) — searching decision logs within ${WINDOW_HOURS}h before this commit..."

    set +e
    SEARCH_OUT="$(LOGS_DIR="${LOGS_DIR:-}" bash "$LOG_SEARCH" --commit "$COMMIT" 2>&1)"
    SEARCH_RC=$?
    set -e

    if [[ "$SEARCH_OUT" == *"No matching decision logs found"* || \
          "$SEARCH_OUT" == *"No decision logs found"* || \
          $SEARCH_RC -ne 0 ]]; then
        echo "[No decision logs found for commit ${COMMIT:0:7} — no logs in the ${WINDOW_HOURS}h window before ${COMMIT_DATE}]"
    else
        echo "$SEARCH_OUT"
    fi
done
