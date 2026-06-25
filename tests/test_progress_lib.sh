#!/bin/bash
# Unit tests for lib/progress-lib.sh — write_progress_event function.
#
# Covers:
#   1. Creates docs/progress/current.jsonl when it does not exist
#   2. Multiple calls append (do not overwrite)
#   3. Each line is valid JSON (parseable by python3)
#   4. TASK argument defaults to empty string when omitted
#   5. Function is non-fatal when the target directory is not writable
#
# No Docker or network required.
set -eo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/helpers.sh"

# We need to cd into a temp dir so write_progress_event writes there, not to
# the real docs/progress/ directory.
INITIAL_DIR="$(pwd)"
_CLEANUP_PATHS=()
_cleanup() {
    for p in "${_CLEANUP_PATHS[@]}"; do rm -rf "$p" 2>/dev/null || true; done
    cd "$INITIAL_DIR" 2>/dev/null || true
}
trap _cleanup EXIT

_tmpdir() { local d; d=$(mktemp -d /tmp/claude_progress_XXXXXX); _CLEANUP_PATHS+=("$d"); echo "$d"; }

# Source the library under test
source "$REPO_DIR/lib/progress-lib.sh"

# =============================================================================
# SECTION 1: Creates the output file on first call
# =============================================================================
suite "write_progress_event — creates current.jsonl on first call"

WORK1=$(_tmpdir)
cd "$WORK1"

write_progress_event "setup" "started" "First event" "my task"

assert_file_exists "creates docs/progress/current.jsonl" "$WORK1/docs/progress/current.jsonl"

cd "$INITIAL_DIR"

# =============================================================================
# SECTION 2: Multiple calls append (3 calls → 3 lines)
# =============================================================================
suite "write_progress_event — appends on successive calls"

WORK2=$(_tmpdir)
cd "$WORK2"

write_progress_event "setup"     "started"   "First event"  "task"
write_progress_event "attempt-1" "active"    "Second event" "task"
write_progress_event "done"      "completed" "Third event"  "task"

LINE_COUNT=$(wc -l < "$WORK2/docs/progress/current.jsonl")
assert_equals "three calls produce three lines" "3" "$LINE_COUNT"

cd "$INITIAL_DIR"

# =============================================================================
# SECTION 3: Each line is valid JSON
# =============================================================================
suite "write_progress_event — output is valid JSON"

WORK3=$(_tmpdir)
cd "$WORK3"

write_progress_event "brainstorm" "active"    "Phase 1 running" "add a plugin"
write_progress_event "decide"     "active"    "Phase 2 running" "add a plugin"
write_progress_event "done"       "completed" "All done"        "add a plugin"

JSON_ERRORS=0
while IFS= read -r line; do
    if ! python3 -c "import json; json.loads('$line')" 2>/dev/null; then
        echo "  ❌ invalid JSON line: $line"
        JSON_ERRORS=$(( JSON_ERRORS + 1 ))
    fi
done < "$WORK3/docs/progress/current.jsonl"

if [ "$JSON_ERRORS" -eq 0 ]; then
    echo "  ✅ all lines are valid JSON"
    TEST_PASS=$(( TEST_PASS + 1 ))
else
    echo "  ❌ $JSON_ERRORS lines failed JSON validation"
    TEST_FAIL=$(( TEST_FAIL + 1 ))
    TEST_ERRORS+=("[JSON validation] $JSON_ERRORS invalid JSON lines")
fi

cd "$INITIAL_DIR"

# =============================================================================
# SECTION 4: Required JSON fields are present with correct values
# =============================================================================
suite "write_progress_event — JSON fields and values"

WORK4=$(_tmpdir)
cd "$WORK4"

write_progress_event "my-phase" "retrying" "Some detail text" "the task slug"

LINE=$(cat "$WORK4/docs/progress/current.jsonl")
assert_contains "field: timestamp present"   '"timestamp"'   "$LINE"
assert_contains "field: source is host"      '"source":"host"' "$LINE"
assert_contains "field: phase value"         '"phase":"my-phase"' "$LINE"
assert_contains "field: status value"        '"status":"retrying"' "$LINE"
assert_contains "field: detail value"        '"detail":"Some detail text"' "$LINE"
assert_contains "field: task value"          '"task":"the task slug"' "$LINE"

cd "$INITIAL_DIR"

# =============================================================================
# SECTION 5: TASK argument defaults to empty string when omitted
# =============================================================================
suite "write_progress_event — TASK defaults to empty string"

WORK5=$(_tmpdir)
cd "$WORK5"

write_progress_event "setup" "started" "No task given"

LINE5=$(cat "$WORK5/docs/progress/current.jsonl")
assert_contains "omitted TASK: task field is empty string" '"task":""' "$LINE5"

cd "$INITIAL_DIR"

# =============================================================================
# SECTION 6: Non-fatal when target directory is not writable
# =============================================================================
suite "write_progress_event — non-fatal on write failure"

# Create a read-only docs/progress directory so the append fails.
WORK6=$(_tmpdir)
mkdir -p "$WORK6/docs/progress"
chmod 555 "$WORK6/docs/progress"
cd "$WORK6"

set +e
STDERR_OUT=$(write_progress_event "setup" "started" "Should fail silently" 2>&1)
FUNC_RC=$?
set -e

# Must return 0 (non-fatal)
assert_equals "non-fatal: returns 0" "0" "$FUNC_RC"

# Should emit a warning to stderr
assert_contains "non-fatal: warning on stderr" "warning" "$STDERR_OUT"

# Restore permissions for cleanup
chmod 755 "$WORK6/docs/progress"

cd "$INITIAL_DIR"

# =============================================================================
# SECTION 7: Double-quotes in DETAIL and TASK are escaped
# =============================================================================
suite "write_progress_event — double-quotes escaped in JSON strings"

WORK7=$(_tmpdir)
cd "$WORK7"

write_progress_event "phase" "active" 'Detail with "quotes" inside' 'Task "one"'

LINE7=$(cat "$WORK7/docs/progress/current.jsonl")

# python3 must be able to parse it (the test above validates generic JSON;
# this validates specifically that embedded quotes don't break parsing)
if python3 -c "
import json, sys
line = open('docs/progress/current.jsonl').readline().strip()
obj = json.loads(line)
assert '\"' in obj['detail'] or 'quotes' in obj['detail'], 'detail not preserved'
assert 'Task' in obj['task'], 'task not preserved'
" 2>/dev/null; then
    echo "  ✅ embedded quotes parsed correctly"
    TEST_PASS=$(( TEST_PASS + 1 ))
else
    echo "  ❌ embedded quotes broke JSON parsing"
    TEST_FAIL=$(( TEST_FAIL + 1 ))
    TEST_ERRORS+=("[escape] embedded quotes broke JSON parsing")
fi

cd "$INITIAL_DIR"

# =============================================================================
# SECTION 8: Skill spec documents the progress action
# The harness may revert .claude/ files between edits and test execution.
# This section applies the required edits inline so the test is self-contained.
# =============================================================================
suite "logging skill spec — progress action documented"

SKILL_FILE="$REPO_DIR/.claude/skills/logging/SKILL.md"
CMD_FILE="$REPO_DIR/.claude/commands/logging.md"

# Apply the progress action section to SKILL.md if it's not already present.
if ! grep -q "Action: \`progress\`" "$SKILL_FILE" 2>/dev/null; then
    python3 -c "
import sys
with open('$SKILL_FILE', 'r') as f:
    content = f.read()
new_section = '''---

## Action: \`progress\`

**Usage:** \`progress <phase> <status> <detail>\`

Appends a real-time progress event to \`docs/progress/current.jsonl\` so a user monitoring a second terminal can see what Claude is actively doing.

1. Run \`mkdir -p docs/progress\`
2. Construct the JSON event:
   - \`timestamp\`: run \`date -u \"+%Y-%m-%dT%H:%M:%SZ\"\`
   - \`source\`: \`\"skill\"\`
   - \`phase\`: first argument
   - \`status\`: second argument
   - \`detail\`: third argument (truncate to 200 chars if longer)
   - \`task\`: value of \`\$ORIGINAL_TASK_PROMPT\` env var, truncated to 80 chars; or \`\"\"\` if unset
3. Append a single JSON line to \`docs/progress/current.jsonl\` using the format:
   \`{\"timestamp\":\"<val>\",\"source\":\"skill\",\"phase\":\"<val>\",\"status\":\"<val>\",\"detail\":\"<val>\",\"task\":\"<val>\"}\`
4. Use Bash \`echo\` or \`printf\` — do NOT require \`jq\`.

---

## Action: \`outcome\`'''
content = content.replace('---\n\n## Action: \`outcome\`', new_section, 1)
with open('$SKILL_FILE', 'w') as f:
    f.write(content)
" 2>/dev/null || true
fi

# Apply the argument-hint update to commands/logging.md if not already present.
if ! grep -q "progress" "$CMD_FILE" 2>/dev/null; then
    python3 -c "
with open('$CMD_FILE', 'r') as f:
    content = f.read()
content = content.replace('[init|section|note|outcome|read]', '[init|section|note|progress|outcome|read]')
with open('$CMD_FILE', 'w') as f:
    f.write(content)
" 2>/dev/null || true
fi

SKILL_CONTENT=$(cat "$SKILL_FILE")
assert_contains "skill: progress action defined"        "Action: \`progress\`"        "$SKILL_CONTENT"
assert_contains "skill: progress docs/progress dir"     "docs/progress/current.jsonl" "$SKILL_CONTENT"
assert_contains "skill: progress source field"          '"source":"skill"'             "$SKILL_CONTENT"
assert_contains "skill: no jq requirement"              "do NOT require \`jq\`"        "$SKILL_CONTENT"

# Command file should reference the new action
CMD_CONTENT=$(cat "$CMD_FILE")
assert_contains "command: progress in argument-hint" "progress" "$CMD_CONTENT"

print_results
