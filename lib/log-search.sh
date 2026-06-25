#!/usr/bin/env bash
# lib/log-search.sh — Search decision logs in docs/decisions/
#
# Usage:
#   lib/log-search.sh [--date <date-spec>] [--commit <hash-or-msg>] [--keyword <term>] [--and]
#   lib/log-search.sh --help
#
# With no flags: prints the 10 most recent decision logs.
#
# Flags:
#   --date <date-spec>    Filter by date. Accepts:
#                           today, yesterday, last week
#                           2026-06-19  (exact date)
#                           2026-06-19..2026-06-24  (inclusive range)
#   --commit <ref>        Find logs active when a commit was made. Accepts a
#                         full or partial commit hash, or a commit message substring.
#                         Lists logs whose filename timestamp falls in the 24-hour
#                         window before that commit.
#   --keyword <term>      Case-insensitive search over log content.
#   --and                 When multiple flags are given, require all to match
#                         (default: any flag match qualifies a log).
#   --help                Print this usage and exit 0.

set -eo pipefail

# ---------------------------------------------------------------------------
# LOGS_DIR resolution
# ---------------------------------------------------------------------------
LOGS_DIR="${LOGS_DIR:-$(cd "$(dirname "$0")/.." && pwd)/docs/decisions}"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
DATE_SPEC=""
COMMIT_REF=""
KEYWORD=""
AND_MODE=false
NO_FLAGS=true

print_usage() {
    cat <<'EOF'
Usage: lib/log-search.sh [--date <date-spec>] [--commit <hash-or-msg>] [--keyword <term>] [--and] [--help]

Flags:
  --date <date-spec>    Filter by date: today, yesterday, "last week",
                        2026-06-19, or 2026-06-01..2026-06-30 (range)
  --commit <ref>        Find logs active when a commit was made
                        (accepts hash prefix or message substring)
  --keyword <term>      Case-insensitive search over log content
  --and                 Require ALL given filters to match (default: OR)
  --help                Print this usage and exit 0

With no flags: prints the 10 most recent decision logs.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --date)
            DATE_SPEC="$2"
            NO_FLAGS=false
            shift 2
            ;;
        --commit)
            COMMIT_REF="$2"
            NO_FLAGS=false
            shift 2
            ;;
        --keyword)
            KEYWORD="$2"
            NO_FLAGS=false
            shift 2
            ;;
        --and)
            AND_MODE=true
            shift
            ;;
        --help)
            print_usage
            exit 0
            ;;
        *)
            echo "Unknown flag: $1" >&2
            echo "" >&2
            print_usage >&2
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Helper: strip date dashes to get YYYYMMDD
# Handles both YYYY-MM-DD and YYYYMMDD formats.
# ---------------------------------------------------------------------------
strip_date_dashes() {
    echo "$1" | tr -d '-'
}

# ---------------------------------------------------------------------------
# Helper: extract the date prefix from a filename.
# Supports both YYYYMMDD_HHMM_... and YYYY-MM-DD_HHMM_... filename formats.
# Returns an 8-digit YYYYMMDD string for comparison.
# ---------------------------------------------------------------------------
filename_date() {
    local base
    base="$(basename "$1")"
    # Try YYYYMMDD_HHMM_ (no dashes in date)
    if [[ "$base" =~ ^([0-9]{8})_[0-9]{4}_ ]]; then
        echo "${BASH_REMATCH[1]}"
    # Try YYYY-MM-DD_HHMM_ (dashes in date)
    elif [[ "$base" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})_[0-9]{4}_ ]]; then
        echo "${BASH_REMATCH[1]}" | tr -d '-'
    else
        echo ""
    fi
}

# ---------------------------------------------------------------------------
# Helper: extract the datetime prefix YYYYMMDD_HHMM from a filename.
# Supports both YYYYMMDD_HHMM_... and YYYY-MM-DD_HHMM_... filename formats.
# ---------------------------------------------------------------------------
filename_datetime() {
    local base
    base="$(basename "$1")"
    # Try YYYYMMDD_HHMM_ (no dashes in date)
    if [[ "$base" =~ ^([0-9]{8}_[0-9]{4})_ ]]; then
        echo "${BASH_REMATCH[1]}"
    # Try YYYY-MM-DD_HHMM_ (dashes in date)
    elif [[ "$base" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{4})_ ]]; then
        # Normalize to YYYYMMDD_HHMM
        local raw="${BASH_REMATCH[1]}"
        local d="${raw:0:10}"  # YYYY-MM-DD
        local t="${raw:11:4}"  # HHMM
        echo "$(echo "$d" | tr -d '-')_${t}"
    else
        echo ""
    fi
}

# ---------------------------------------------------------------------------
# parse_date_range
# Sets DATE_FROM and DATE_TO (both YYYYMMDD, no dashes) from DATE_SPEC.
# ---------------------------------------------------------------------------
parse_date_range() {
    case "$DATE_SPEC" in
        today)
            DATE_FROM="$(date '+%Y%m%d')"
            DATE_TO="$DATE_FROM"
            ;;
        yesterday)
            DATE_FROM="$(date -d yesterday '+%Y%m%d')"
            DATE_TO="$DATE_FROM"
            ;;
        "last week")
            DATE_FROM="$(date -d '7 days ago' '+%Y%m%d')"
            DATE_TO="$(date -d yesterday '+%Y%m%d')"
            ;;
        *..*)
            local left="${DATE_SPEC%..*}"
            local right="${DATE_SPEC#*..}"
            DATE_FROM="$(strip_date_dashes "$left")"
            DATE_TO="$(strip_date_dashes "$right")"
            ;;
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])
            DATE_FROM="$(strip_date_dashes "$DATE_SPEC")"
            DATE_TO="$DATE_FROM"
            ;;
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9])
            DATE_FROM="$DATE_SPEC"
            DATE_TO="$DATE_SPEC"
            ;;
        *)
            echo "Unrecognized date spec: '$DATE_SPEC'" >&2
            echo "Supported: today, yesterday, 'last week', YYYY-MM-DD, YYYY-MM-DD..YYYY-MM-DD" >&2
            exit 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# resolve_commit_window
# Sets COMMIT_FROM and COMMIT_TO (both YYYYMMDD_HHMM strings).
# ---------------------------------------------------------------------------
resolve_commit_window() {
    local author_date=""

    # Try hash prefix match first
    local hash_match
    hash_match="$(git log --all --format='%H %aI' 2>/dev/null | grep -m1 "^${COMMIT_REF}" || true)"
    if [[ -n "$hash_match" ]]; then
        author_date="$(echo "$hash_match" | awk '{print $2}')"
    fi

    # If no hash match, try commit message substring
    if [[ -z "$author_date" ]]; then
        author_date="$(git log --all --grep="${COMMIT_REF}" --format='%aI' -1 2>/dev/null || true)"
    fi

    if [[ -z "$author_date" ]]; then
        echo "Could not resolve commit ref: ${COMMIT_REF}" >&2
        exit 1
    fi

    COMMIT_TO="$(date -d "${author_date}" '+%Y%m%d_%H%M')"
    COMMIT_FROM="$(date -d "${author_date} - 1 day" '+%Y%m%d_%H%M')"
}

# ---------------------------------------------------------------------------
# format_log_header
# Takes a log filepath and prints the human-readable block.
# ---------------------------------------------------------------------------
format_log_header() {
    local filepath="$1"
    local base
    base="$(basename "$filepath")"

    # Extract metadata from file content (first 15 lines)
    local head_content
    head_content="$(head -15 "$filepath" 2>/dev/null || true)"

    local file_date file_pipeline file_status
    file_date="$(echo "$head_content" | grep -m1 '^\*\*Date:\*\*' | sed 's/\*\*Date:\*\*[[:space:]]*//' || true)"
    file_pipeline="$(echo "$head_content" | grep -m1 '^\*\*Pipeline:\*\*' | sed 's/\*\*Pipeline:\*\*[[:space:]]*//' || true)"
    file_status="$(echo "$head_content" | grep -m1 '^\*\*Status:\*\*' | sed 's/\*\*Status:\*\*[[:space:]]*//' || true)"

    # Derive task slug from filename
    # Remove YYYYMMDD_HHMM_ prefix (or YYYY-MM-DD_HHMM_ prefix) and _<pipeline>.md suffix
    local task_slug="$base"
    # Strip date prefix (handles both formats)
    task_slug="${task_slug#*_*_}"  # strip through second underscore (removes YYYYMMDD_HHMM_ or YYYY-MM-DD_HHMM_)
    # But the YYYY-MM-DD format has dashes so we need a more robust approach
    if [[ "$base" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{4}_(.+)$ ]]; then
        task_slug="${BASH_REMATCH[1]}"
    elif [[ "$base" =~ ^[0-9]{8}_[0-9]{4}_(.+)$ ]]; then
        task_slug="${BASH_REMATCH[1]}"
    fi
    # Strip _<pipeline>.md suffix
    if [[ -n "$file_pipeline" ]]; then
        task_slug="${task_slug%_${file_pipeline}.md}"
    else
        task_slug="${task_slug%.md}"
    fi

    echo "--- docs/decisions/${base}"
    echo "Date:     ${file_date}"
    echo "Pipeline: ${file_pipeline}"
    echo "Status:   ${file_status}"
    echo "Task:     ${task_slug}"
}

# ---------------------------------------------------------------------------
# Build candidate list
# ---------------------------------------------------------------------------
mapfile -t ALL_LOGS < <(ls -t "$LOGS_DIR"/*.md 2>/dev/null || true)

if [[ ${#ALL_LOGS[@]} -eq 0 ]]; then
    echo "No decision logs found in docs/decisions/"
    exit 0
fi

# ---------------------------------------------------------------------------
# Default mode: no flags — print 10 most recent logs
# ---------------------------------------------------------------------------
if [[ "$NO_FLAGS" == "true" ]]; then
    echo "Showing 10 most recent decision logs:"
    for filepath in "${ALL_LOGS[@]:0:10}"; do
        format_log_header "$filepath"
    done
    exit 0
fi

# ---------------------------------------------------------------------------
# Apply date filter
# ---------------------------------------------------------------------------
DATE_CANDIDATES=()
if [[ -n "$DATE_SPEC" ]]; then
    DATE_FROM=""
    DATE_TO=""
    parse_date_range
    for filepath in "${ALL_LOGS[@]}"; do
        local_date="$(filename_date "$filepath")"
        if [[ -z "$local_date" ]]; then
            continue
        fi
        if [[ ( "$local_date" > "$DATE_FROM" || "$local_date" == "$DATE_FROM" ) && \
              ( "$local_date" < "$DATE_TO"   || "$local_date" == "$DATE_TO"   ) ]]; then
            DATE_CANDIDATES+=("$filepath")
        fi
    done
fi

# ---------------------------------------------------------------------------
# Apply commit filter
# ---------------------------------------------------------------------------
COMMIT_CANDIDATES=()
if [[ -n "$COMMIT_REF" ]]; then
    COMMIT_FROM=""
    COMMIT_TO=""
    resolve_commit_window
    for filepath in "${ALL_LOGS[@]}"; do
        local_dt="$(filename_datetime "$filepath")"
        if [[ -z "$local_dt" ]]; then
            continue
        fi
        if [[ ( "$local_dt" > "$COMMIT_FROM" || "$local_dt" == "$COMMIT_FROM" ) && \
              ( "$local_dt" < "$COMMIT_TO"   || "$local_dt" == "$COMMIT_TO"   ) ]]; then
            COMMIT_CANDIDATES+=("$filepath")
        fi
    done
fi

# ---------------------------------------------------------------------------
# Apply keyword filter
# ---------------------------------------------------------------------------
KEYWORD_CANDIDATES=()
if [[ -n "$KEYWORD" ]]; then
    for filepath in "${ALL_LOGS[@]}"; do
        if grep -qil "${KEYWORD}" "$filepath" 2>/dev/null; then
            KEYWORD_CANDIDATES+=("$filepath")
        fi
    done
fi

# ---------------------------------------------------------------------------
# Combine filter results
# ---------------------------------------------------------------------------
# Determine which filter sets are active
declare -a ACTIVE_NON_KEYWORD=()
[[ -n "$DATE_SPEC" ]]   && ACTIVE_NON_KEYWORD+=("date")
[[ -n "$COMMIT_REF" ]]  && ACTIVE_NON_KEYWORD+=("commit")

if [[ "$AND_MODE" == "true" ]]; then
    # AND mode: a file must pass every active filter
    # Start with all logs, intersect with each active filter
    declare -A and_map
    for f in "${ALL_LOGS[@]}"; do and_map["$f"]=1; done

    if [[ -n "$DATE_SPEC" ]]; then
        declare -A date_map
        for f in "${DATE_CANDIDATES[@]}"; do date_map["$f"]=1; done
        for f in "${!and_map[@]}"; do
            [[ -z "${date_map[$f]+_}" ]] && unset and_map["$f"]
        done
    fi
    if [[ -n "$COMMIT_REF" ]]; then
        declare -A commit_map
        for f in "${COMMIT_CANDIDATES[@]}"; do commit_map["$f"]=1; done
        for f in "${!and_map[@]}"; do
            [[ -z "${commit_map[$f]+_}" ]] && unset and_map["$f"]
        done
    fi
    if [[ -n "$KEYWORD" ]]; then
        declare -A kw_map
        for f in "${KEYWORD_CANDIDATES[@]}"; do kw_map["$f"]=1; done
        for f in "${!and_map[@]}"; do
            [[ -z "${kw_map[$f]+_}" ]] && unset and_map["$f"]
        done
    fi

    # Rebuild final list in ls -t order
    FINAL_CANDIDATES=()
    for f in "${ALL_LOGS[@]}"; do
        [[ -n "${and_map[$f]+_}" ]] && FINAL_CANDIDATES+=("$f")
    done
else
    # OR mode: a file qualifies if it passed ANY active filter
    declare -A or_map
    for f in "${DATE_CANDIDATES[@]}";   do or_map["$f"]=1; done
    for f in "${COMMIT_CANDIDATES[@]}"; do or_map["$f"]=1; done
    for f in "${KEYWORD_CANDIDATES[@]}"; do or_map["$f"]=1; done

    FINAL_CANDIDATES=()
    for f in "${ALL_LOGS[@]}"; do
        [[ -n "${or_map[$f]+_}" ]] && FINAL_CANDIDATES+=("$f")
    done
fi

# ---------------------------------------------------------------------------
# Print results
# ---------------------------------------------------------------------------
if [[ ${#FINAL_CANDIDATES[@]} -eq 0 ]]; then
    echo "No matching decision logs found."
    exit 0
fi

for filepath in "${FINAL_CANDIDATES[@]}"; do
    format_log_header "$filepath"
    if [[ -n "$KEYWORD" ]]; then
        grep -in --color=never -A2 -B2 "${KEYWORD}" "$filepath" 2>/dev/null \
            | sed 's/^/  > /' || true
    fi
done
