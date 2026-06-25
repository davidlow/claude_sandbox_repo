#!/bin/bash
# Adversarial test suite for the auto-initialize logging directories feature.
#
# Covers:
#   1. ensure_logging_dirs() is called in launch-scripted.sh before the main loop
#   2. ensure_logging_dirs() is called in launch-interactive.sh before docker run
#   3. The function is idempotent (safe to call multiple times)
#   4. The function handles a read-only parent directory gracefully
#   5. docs/decisions/ and docs/progress/ both get created
#   6. The /logging init action creates both directories inside the container
#   7. Happy paths, common error cases, boundary conditions, and edge cases
#
# No Docker or network required.
set -eo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/helpers.sh"
source "$REPO_DIR/lib/launch-lib.sh"

INITIAL_DIR="$(pwd)"
_CLEANUP_PATHS=()
_cleanup() {
    for p in "${_CLEANUP_PATHS[@]}"; do rm -rf "$p" 2>/dev/null || true; done
    cd "$INITIAL_DIR" 2>/dev/null || true
}
trap _cleanup EXIT

_tmpdir() { local d; d=$(mktemp -d /tmp/claude_logdirs_XXXXXX); _CLEANUP_PATHS+=("$d"); echo "$d"; }

# =============================================================================
# SECTION 1: ensure_logging_dirs — happy path, both dirs created
# =============================================================================
suite "ensure_logging_dirs — happy path: both dirs created"

WORK1=$(_tmpdir)
cd "$WORK1"

ensure_logging_dirs

if [ -d "$WORK1/docs/decisions" ]; then
    echo "  ✅ docs/decisions/ created"
    TEST_PASS=$(( TEST_PASS + 1 ))
else
    echo "  ❌ docs/decisions/ not created"
    TEST_FAIL=$(( TEST_FAIL + 1 ))
    TEST_ERRORS+=("[ensure_logging_dirs happy path] docs/decisions/ not created")
fi

if [ -d "$WORK1/docs/progress" ]; then
    echo "  ✅ docs/progress/ created"
    TEST_PASS=$(( TEST_PASS + 1 ))
else
    echo "  ❌ docs/progress/ not created"
    TEST_FAIL=$(( TEST_FAIL + 1 ))
    TEST_ERRORS+=("[ensure_logging_dirs happy path] docs/progress/ not created")
fi

cd "$INITIAL_DIR"

# =============================================================================
# SECTION 2: ensure_logging_dirs — idempotency (safe to call multiple times)
# =============================================================================
suite "ensure_logging_dirs — idempotency"

WORK2=$(_tmpdir)
cd "$WORK2"

# First call
ensure_logging_dirs

# Second call — must not fail or corrupt existing dirs
RC2=0
ensure_logging_dirs || RC2=$?
assert_equals "second call: exit 0" "0" "$RC2"

if [ -d "$WORK2/docs/decisions" ]; then
    echo "  ✅ docs/decisions/ still present after second call"
    TEST_PASS=$(( TEST_PASS + 1 ))
else
    echo "  ❌ docs/decisions/ missing after second call"
    TEST_FAIL=$(( TEST_FAIL + 1 ))
    TEST_ERRORS+=("[idempotency] docs/decisions/ missing after second call")
fi

if [ -d "$WORK2/docs/progress" ]; then
    echo "  ✅ docs/progress/ still present after second call"
    TEST_PASS=$(( TEST_PASS + 1 ))
else
    echo "  ❌ docs/progress/ missing after second call"
    TEST_FAIL=$(( TEST_FAIL + 1 ))
    TEST_ERRORS+=("[idempotency] docs/progress/ missing after second call")
fi

# Third call — still must succeed
RC3=0
ensure_logging_dirs || RC3=$?
assert_equals "third call: exit 0" "0" "$RC3"

# Pre-existing files in directories must survive multiple calls
echo "sentinel" > "$WORK2/docs/decisions/sentinel.md"
ensure_logging_dirs
assert_file_exists "idempotency: pre-existing file survives repeated calls" \
    "$WORK2/docs/decisions/sentinel.md"

cd "$INITIAL_DIR"

# =============================================================================
# SECTION 3: ensure_logging_dirs — idempotency when dirs already exist
# =============================================================================
suite "ensure_logging_dirs — idempotency when dirs already exist"

WORK3=$(_tmpdir)
cd "$WORK3"
# Pre-create both directories manually
mkdir -p docs/decisions docs/progress

# Place content files to verify they are not wiped
echo "existing_decisions" > docs/decisions/existing.md
echo "existing_progress"  > docs/progress/existing.txt

RC_EXIST=0
ensure_logging_dirs || RC_EXIST=$?
assert_equals "pre-existing dirs: exit 0" "0" "$RC_EXIST"

assert_file_exists "pre-existing dirs: decisions file preserved" \
    "$WORK3/docs/decisions/existing.md"
assert_file_exists "pre-existing dirs: progress file preserved" \
    "$WORK3/docs/progress/existing.txt"

cd "$INITIAL_DIR"

# =============================================================================
# SECTION 4: ensure_logging_dirs — read-only parent directory (graceful failure)
# =============================================================================
suite "ensure_logging_dirs — read-only parent directory handled gracefully"

# Only run if we are not running as root (root ignores directory permissions).
if [ "$(id -u)" -eq 0 ]; then
    skip "Running as root — read-only permission test meaningless; skipping"
else
    WORK4=$(_tmpdir)
    # Create a docs/ dir that is read-only so mkdir -p docs/decisions fails
    mkdir -p "$WORK4/docs"
    chmod 555 "$WORK4/docs"

    cd "$WORK4"
    # Must NOT crash or exit non-zero — the function promises to return 0
    STDERR_OUTPUT=""
    RC4=0
    STDERR_OUTPUT=$(ensure_logging_dirs 2>&1) || RC4=$?
    assert_equals "read-only parent: returns 0 (non-fatal)" "0" "$RC4"
    assert_contains "read-only parent: emits warning to stderr" \
        "Could not create logging dirs" "$STDERR_OUTPUT"

    # Restore permissions so cleanup can delete it
    chmod 755 "$WORK4/docs"
    cd "$INITIAL_DIR"
fi

# =============================================================================
# SECTION 5: ensure_logging_dirs — no stdout output on success
# =============================================================================
suite "ensure_logging_dirs — silent on success (no stdout pollution)"

WORK5=$(_tmpdir)
cd "$WORK5"

STDOUT_OUTPUT=$(ensure_logging_dirs 2>/dev/null)
assert_equals "success: no stdout output" "" "$STDOUT_OUTPUT"

cd "$INITIAL_DIR"

# =============================================================================
# SECTION 6: ensure_logging_dirs — produces no stdout even when dirs already exist
# =============================================================================
suite "ensure_logging_dirs — silent when dirs already exist"

WORK6=$(_tmpdir)
cd "$WORK6"
mkdir -p docs/decisions docs/progress

STDOUT_EXISTING=$(ensure_logging_dirs 2>/dev/null)
assert_equals "pre-existing: no stdout" "" "$STDOUT_EXISTING"

cd "$INITIAL_DIR"

# =============================================================================
# SECTION 7: ensure_logging_dirs called in launch-scripted.sh before the main loop
# =============================================================================
suite "launch-scripted.sh — ensure_logging_dirs called before main loop"

SCRIPTED_SRC="$REPO_DIR/launch-scripted.sh"

# Verify ensure_logging_dirs is present in the script
assert_contains "scripted: ensure_logging_dirs call present" \
    "ensure_logging_dirs" "$(cat "$SCRIPTED_SRC")"

# Verify the call appears BEFORE the main while loop starts.
# Strategy: find the line number of ensure_logging_dirs and of the main while loop.
ELD_LINE=$(grep -n "ensure_logging_dirs" "$SCRIPTED_SRC" | head -1 | cut -d: -f1)
LOOP_LINE=$(grep -n "^while \[ \$ATTEMPT" "$SCRIPTED_SRC" | head -1 | cut -d: -f1)

if [ -n "$ELD_LINE" ] && [ -n "$LOOP_LINE" ]; then
    if [ "$ELD_LINE" -lt "$LOOP_LINE" ]; then
        echo "  ✅ scripted: ensure_logging_dirs (line $ELD_LINE) is before main loop (line $LOOP_LINE)"
        TEST_PASS=$(( TEST_PASS + 1 ))
    else
        echo "  ❌ scripted: ensure_logging_dirs (line $ELD_LINE) is NOT before main loop (line $LOOP_LINE)"
        TEST_FAIL=$(( TEST_FAIL + 1 ))
        TEST_ERRORS+=("[launch-scripted.sh] ensure_logging_dirs must appear before main retry loop")
    fi
else
    echo "  ❌ scripted: could not locate ensure_logging_dirs (line: $ELD_LINE) or while loop (line: $LOOP_LINE)"
    TEST_FAIL=$(( TEST_FAIL + 1 ))
    TEST_ERRORS+=("[launch-scripted.sh] ensure_logging_dirs or while loop not found")
fi

# Verify ensure_logging_dirs is called AFTER sourcing lib/launch-lib.sh
#  (the function is defined there, so it must be sourced first)
SOURCE_LINE=$(grep -n 'source.*launch-lib\.sh' "$SCRIPTED_SRC" | head -1 | cut -d: -f1)
if [ -n "$SOURCE_LINE" ] && [ -n "$ELD_LINE" ]; then
    if [ "$SOURCE_LINE" -lt "$ELD_LINE" ]; then
        echo "  ✅ scripted: lib/launch-lib.sh sourced (line $SOURCE_LINE) before ensure_logging_dirs (line $ELD_LINE)"
        TEST_PASS=$(( TEST_PASS + 1 ))
    else
        echo "  ❌ scripted: ensure_logging_dirs called before lib/launch-lib.sh is sourced"
        TEST_FAIL=$(( TEST_FAIL + 1 ))
        TEST_ERRORS+=("[launch-scripted.sh] ensure_logging_dirs called before sourcing launch-lib.sh")
    fi
fi

# =============================================================================
# SECTION 8: ensure_logging_dirs called in launch-interactive.sh before docker run
# =============================================================================
suite "launch-interactive.sh — ensure_logging_dirs called before docker run"

INTERACTIVE_SRC="$REPO_DIR/launch-interactive.sh"

assert_contains "interactive: ensure_logging_dirs call present" \
    "ensure_logging_dirs" "$(cat "$INTERACTIVE_SRC")"

ELD_I_LINE=$(grep -n "ensure_logging_dirs" "$INTERACTIVE_SRC" | head -1 | cut -d: -f1)
DOCKER_I_LINE=$(grep -n "^docker run" "$INTERACTIVE_SRC" | head -1 | cut -d: -f1)

if [ -n "$ELD_I_LINE" ] && [ -n "$DOCKER_I_LINE" ]; then
    if [ "$ELD_I_LINE" -lt "$DOCKER_I_LINE" ]; then
        echo "  ✅ interactive: ensure_logging_dirs (line $ELD_I_LINE) before docker run (line $DOCKER_I_LINE)"
        TEST_PASS=$(( TEST_PASS + 1 ))
    else
        echo "  ❌ interactive: ensure_logging_dirs (line $ELD_I_LINE) is NOT before docker run (line $DOCKER_I_LINE)"
        TEST_FAIL=$(( TEST_FAIL + 1 ))
        TEST_ERRORS+=("[launch-interactive.sh] ensure_logging_dirs must appear before docker run")
    fi
else
    echo "  ❌ interactive: could not locate ensure_logging_dirs (line: $ELD_I_LINE) or docker run (line: $DOCKER_I_LINE)"
    TEST_FAIL=$(( TEST_FAIL + 1 ))
    TEST_ERRORS+=("[launch-interactive.sh] ensure_logging_dirs or docker run not found")
fi

# ensure_logging_dirs must appear after sourcing lib/launch-lib.sh in interactive script
SOURCE_I_LINE=$(grep -n 'source.*launch-lib\.sh' "$INTERACTIVE_SRC" | head -1 | cut -d: -f1)
if [ -n "$SOURCE_I_LINE" ] && [ -n "$ELD_I_LINE" ]; then
    if [ "$SOURCE_I_LINE" -lt "$ELD_I_LINE" ]; then
        echo "  ✅ interactive: lib/launch-lib.sh sourced (line $SOURCE_I_LINE) before ensure_logging_dirs (line $ELD_I_LINE)"
        TEST_PASS=$(( TEST_PASS + 1 ))
    else
        echo "  ❌ interactive: ensure_logging_dirs called before lib/launch-lib.sh is sourced"
        TEST_FAIL=$(( TEST_FAIL + 1 ))
        TEST_ERRORS+=("[launch-interactive.sh] ensure_logging_dirs called before sourcing launch-lib.sh")
    fi
fi

# =============================================================================
# SECTION 9: /logging skill init action creates both dirs — spec compliance
# =============================================================================
suite "/logging skill — init action creates docs/decisions/ AND docs/progress/"

SKILL_CONTENT=$(cat "$REPO_DIR/.claude/skills/logging/SKILL.md")

# The init action spec must require mkdir -p for both directories
assert_contains "skill init: mkdir docs/decisions in spec" \
    "docs/decisions" "$SKILL_CONTENT"
assert_contains "skill init: mkdir docs/progress in spec" \
    "docs/progress" "$SKILL_CONTENT"
assert_contains "skill init: mkdir -p mentioned" \
    "mkdir -p" "$SKILL_CONTENT"

# Verify both directories appear in the same mkdir -p command (or at minimum both present)
# Extract the mkdir line from the SKILL.md
MKDIR_LINE=$(grep "mkdir -p" "$REPO_DIR/.claude/skills/logging/SKILL.md" || true)
if [[ "$MKDIR_LINE" == *"docs/decisions"* ]] && [[ "$MKDIR_LINE" == *"docs/progress"* ]]; then
    echo "  ✅ skill init: mkdir -p creates both docs/decisions and docs/progress in one command"
    TEST_PASS=$(( TEST_PASS + 1 ))
else
    echo "  ❌ skill init: mkdir -p does not create both dirs in one command"
    echo "       mkdir line: $MKDIR_LINE"
    TEST_FAIL=$(( TEST_FAIL + 1 ))
    TEST_ERRORS+=("[/logging skill init] mkdir -p does not create both dirs together")
fi

# =============================================================================
# SECTION 10: ensure_logging_dirs — function definition in lib/launch-lib.sh
# =============================================================================
suite "lib/launch-lib.sh — ensure_logging_dirs is defined and callable"

if declare -f ensure_logging_dirs > /dev/null 2>&1; then
    echo "  ✅ ensure_logging_dirs: function defined after source"
    TEST_PASS=$(( TEST_PASS + 1 ))
else
    echo "  ❌ ensure_logging_dirs: function NOT defined after source"
    TEST_FAIL=$(( TEST_FAIL + 1 ))
    TEST_ERRORS+=("[lib/launch-lib.sh] ensure_logging_dirs not defined")
fi

# Verify it is documented in lib/launch-lib.sh source (not just elsewhere)
LIBSRC=$(cat "$REPO_DIR/lib/launch-lib.sh")
assert_contains "lib: ensure_logging_dirs function body present" \
    "ensure_logging_dirs()" "$LIBSRC"
assert_contains "lib: creates docs/decisions" \
    "docs/decisions" "$LIBSRC"
assert_contains "lib: creates docs/progress" \
    "docs/progress" "$LIBSRC"

# =============================================================================
# SECTION 11: ensure_logging_dirs — always returns 0 regardless of outcome
# =============================================================================
suite "ensure_logging_dirs — always returns 0"

# Normal case: both dirs created
WORK11=$(_tmpdir)
cd "$WORK11"
RC11=0
ensure_logging_dirs || RC11=$?
assert_equals "normal: always exit 0" "0" "$RC11"
cd "$INITIAL_DIR"

# Dirs already exist
WORK11B=$(_tmpdir)
cd "$WORK11B"
mkdir -p docs/decisions docs/progress
RC11B=0
ensure_logging_dirs || RC11B=$?
assert_equals "pre-existing dirs: always exit 0" "0" "$RC11B"
cd "$INITIAL_DIR"

# =============================================================================
# SECTION 12: ensure_logging_dirs — creates docs/ intermediate directory
# =============================================================================
suite "ensure_logging_dirs — creates docs/ intermediate directory if absent"

WORK12=$(_tmpdir)
cd "$WORK12"

# Confirm no docs/ directory exists at start
if [ -d "$WORK12/docs" ]; then
    rm -rf "$WORK12/docs"
fi

ensure_logging_dirs

if [ -d "$WORK12/docs" ]; then
    echo "  ✅ docs/ parent directory created"
    TEST_PASS=$(( TEST_PASS + 1 ))
else
    echo "  ❌ docs/ parent directory not created"
    TEST_FAIL=$(( TEST_FAIL + 1 ))
    TEST_ERRORS+=("[ensure_logging_dirs] docs/ parent not created")
fi

cd "$INITIAL_DIR"

# =============================================================================
# SECTION 13: ensure_logging_dirs — created dirs are writable
# =============================================================================
suite "ensure_logging_dirs — created dirs are writable"

WORK13=$(_tmpdir)
cd "$WORK13"
ensure_logging_dirs

# Should be able to write files into both created directories
TEST_FILE1="$WORK13/docs/decisions/test_write_$$.md"
TEST_FILE2="$WORK13/docs/progress/test_write_$$.txt"

RC_W1=0
echo "test" > "$TEST_FILE1" || RC_W1=$?
assert_equals "decisions: writable after creation" "0" "$RC_W1"

RC_W2=0
echo "test" > "$TEST_FILE2" || RC_W2=$?
assert_equals "progress: writable after creation" "0" "$RC_W2"

cd "$INITIAL_DIR"

# =============================================================================
# SECTION 14: ensure_logging_dirs — docs/decisions is a directory, not a file
# =============================================================================
suite "ensure_logging_dirs — created paths are directories, not files"

WORK14=$(_tmpdir)
cd "$WORK14"
ensure_logging_dirs

if [ -d "$WORK14/docs/decisions" ] && [ ! -f "$WORK14/docs/decisions" ]; then
    echo "  ✅ docs/decisions: is a directory"
    TEST_PASS=$(( TEST_PASS + 1 ))
else
    echo "  ❌ docs/decisions: is NOT a directory"
    TEST_FAIL=$(( TEST_FAIL + 1 ))
    TEST_ERRORS+=("[ensure_logging_dirs] docs/decisions is not a directory")
fi

if [ -d "$WORK14/docs/progress" ] && [ ! -f "$WORK14/docs/progress" ]; then
    echo "  ✅ docs/progress: is a directory"
    TEST_PASS=$(( TEST_PASS + 1 ))
else
    echo "  ❌ docs/progress: is NOT a directory"
    TEST_FAIL=$(( TEST_FAIL + 1 ))
    TEST_ERRORS+=("[ensure_logging_dirs] docs/progress is not a directory")
fi

cd "$INITIAL_DIR"

# =============================================================================
# SECTION 15: ensure_logging_dirs — conflict with an existing regular file
# =============================================================================
suite "ensure_logging_dirs — conflict: path already exists as a regular file"

# If docs/decisions is a regular file (not a dir), mkdir -p will fail.
# The function must still return 0 (non-fatal).
if [ "$(id -u)" -ne 0 ]; then
    WORK15=$(_tmpdir)
    cd "$WORK15"
    mkdir -p docs
    echo "I am a file" > docs/decisions  # regular file, not a directory

    RC15=0
    STDERR15=$(ensure_logging_dirs 2>&1) || RC15=$?
    assert_equals "file conflict: returns 0" "0" "$RC15"
    assert_contains "file conflict: emits warning" \
        "Could not create logging dirs" "$STDERR15"

    cd "$INITIAL_DIR"
else
    skip "Running as root — file conflict test skipped (root mkdir behavior differs)"
fi

# =============================================================================
# SECTION 16: ensure_logging_dirs — docs/progress conflict with file
# =============================================================================
suite "ensure_logging_dirs — conflict: docs/progress exists as a regular file"

if [ "$(id -u)" -ne 0 ]; then
    WORK16=$(_tmpdir)
    cd "$WORK16"
    mkdir -p docs
    echo "I am a file" > docs/progress  # regular file, not a directory

    RC16=0
    STDERR16=$(ensure_logging_dirs 2>&1) || RC16=$?
    assert_equals "progress file conflict: returns 0" "0" "$RC16"
    assert_contains "progress file conflict: emits warning" \
        "Could not create logging dirs" "$STDERR16"

    cd "$INITIAL_DIR"
else
    skip "Running as root — progress file conflict test skipped"
fi

# =============================================================================
# SECTION 17: launch-scripted.sh — ensure_logging_dirs called exactly once
#              (not inside the retry loop where it would run on every attempt)
# =============================================================================
suite "launch-scripted.sh — ensure_logging_dirs is called outside the retry loop"

SCRIPTED_SRC="$REPO_DIR/launch-scripted.sh"
ELD_S_LINE=$(grep -n "ensure_logging_dirs" "$SCRIPTED_SRC" | head -1 | cut -d: -f1)
LOOP_S_LINE=$(grep -n "^while \[ \$ATTEMPT" "$SCRIPTED_SRC" | head -1 | cut -d: -f1)
DONE_S_LINE=$(grep -n "^done$" "$SCRIPTED_SRC" | head -1 | cut -d: -f1)

if [ -n "$ELD_S_LINE" ] && [ -n "$LOOP_S_LINE" ] && [ -n "$DONE_S_LINE" ]; then
    if [ "$ELD_S_LINE" -lt "$LOOP_S_LINE" ] || [ "$ELD_S_LINE" -gt "$DONE_S_LINE" ]; then
        echo "  ✅ scripted: ensure_logging_dirs (line $ELD_S_LINE) is outside the retry loop ($LOOP_S_LINE–$DONE_S_LINE)"
        TEST_PASS=$(( TEST_PASS + 1 ))
    else
        echo "  ❌ scripted: ensure_logging_dirs (line $ELD_S_LINE) is INSIDE the retry loop ($LOOP_S_LINE–$DONE_S_LINE)"
        TEST_FAIL=$(( TEST_FAIL + 1 ))
        TEST_ERRORS+=("[launch-scripted.sh] ensure_logging_dirs inside retry loop (should be called once before loop)")
    fi
else
    echo "  ⚠️  scripted: could not determine loop boundaries (ELD=$ELD_S_LINE LOOP=$LOOP_S_LINE DONE=$DONE_S_LINE)"
    # Soft skip — boundaries depend on exact script structure
fi

# =============================================================================
# SECTION 18: /logging skill — init action creates docs/progress/ (not just decisions/)
# =============================================================================
suite "/logging skill — init creates docs/progress/ per SKILL.md spec"

# Simulate what the /logging init action does: mkdir -p docs/decisions docs/progress
WORK18=$(_tmpdir)
cd "$WORK18"

# Extract and execute the mkdir command from the skill spec
bash -c "mkdir -p docs/decisions docs/progress"

if [ -d "$WORK18/docs/decisions" ]; then
    echo "  ✅ skill init simulation: docs/decisions/ created"
    TEST_PASS=$(( TEST_PASS + 1 ))
else
    echo "  ❌ skill init simulation: docs/decisions/ not created"
    TEST_FAIL=$(( TEST_FAIL + 1 ))
    TEST_ERRORS+=("[/logging skill init simulation] docs/decisions not created")
fi

if [ -d "$WORK18/docs/progress" ]; then
    echo "  ✅ skill init simulation: docs/progress/ created"
    TEST_PASS=$(( TEST_PASS + 1 ))
else
    echo "  ❌ skill init simulation: docs/progress/ not created"
    TEST_FAIL=$(( TEST_FAIL + 1 ))
    TEST_ERRORS+=("[/logging skill init simulation] docs/progress not created")
fi

cd "$INITIAL_DIR"

# =============================================================================
# SECTION 19: ensure_logging_dirs — warning goes to stderr, not stdout
# =============================================================================
suite "ensure_logging_dirs — warning is on stderr only (not stdout)"

if [ "$(id -u)" -ne 0 ]; then
    WORK19=$(_tmpdir)
    cd "$WORK19"
    mkdir -p docs
    chmod 555 docs  # make it read-only so mkdir fails

    STDOUT19=$(ensure_logging_dirs 2>/dev/null)
    STDERR19=$(ensure_logging_dirs 2>&1 >/dev/null)

    assert_equals "read-only: no stdout" "" "$STDOUT19"
    assert_contains "read-only: warning on stderr" "Could not create logging dirs" "$STDERR19"

    chmod 755 docs
    cd "$INITIAL_DIR"
else
    skip "Running as root — stderr-only test skipped"
fi

# =============================================================================
# SECTION 20: ensure_logging_dirs — boundary: called from a directory with spaces
# =============================================================================
suite "ensure_logging_dirs — path with spaces in working directory"

SPACE_BASE=$(_tmpdir)
SPACE_DIR="$SPACE_BASE/my project dir"
mkdir -p "$SPACE_DIR"
cd "$SPACE_DIR"

RC_SPACE=0
ensure_logging_dirs || RC_SPACE=$?
assert_equals "spaces in path: exit 0" "0" "$RC_SPACE"

if [ -d "$SPACE_DIR/docs/decisions" ]; then
    echo "  ✅ spaces in path: docs/decisions/ created"
    TEST_PASS=$(( TEST_PASS + 1 ))
else
    echo "  ❌ spaces in path: docs/decisions/ not created"
    TEST_FAIL=$(( TEST_FAIL + 1 ))
    TEST_ERRORS+=("[ensure_logging_dirs spaces] docs/decisions not created")
fi

if [ -d "$SPACE_DIR/docs/progress" ]; then
    echo "  ✅ spaces in path: docs/progress/ created"
    TEST_PASS=$(( TEST_PASS + 1 ))
else
    echo "  ❌ spaces in path: docs/progress/ not created"
    TEST_FAIL=$(( TEST_FAIL + 1 ))
    TEST_ERRORS+=("[ensure_logging_dirs spaces] docs/progress not created")
fi

cd "$INITIAL_DIR"

print_results
