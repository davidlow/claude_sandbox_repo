#!/bin/bash
# Mock claude binary used in pipeline orchestration tests.
#
# Parses the -p PROMPT argument and writes expected output files to /workspace
# based on what the prompt asks for.  This lets the test suite verify pipeline
# orchestration logic (phase ordering, decision logs, retry handling) without
# spending real Claude tokens or requiring network access.
#
# Env vars:
#   MOCK_CLAUDE_EXIT     Override exit code (default 0). Set to 1 to simulate failure.
#   MOCK_CLAUDE_DELAY    Sleep this many seconds before exiting (for timeout tests).

PROMPT=""
PREV=""
for arg in "$@"; do
    if [ "$PREV" = "-p" ]; then
        PROMPT="$arg"
    fi
    PREV="$arg"
done

EXIT_CODE="${MOCK_CLAUDE_EXIT:-0}"
[ -n "${MOCK_CLAUDE_DELAY:-}" ] && sleep "$MOCK_CLAUDE_DELAY"

# Only write workspace output files on success — a failing mock must not produce
# output files, otherwise pipeline scripts see the file and treat the phase as
# succeeded despite the non-zero exit code.
if [ "$EXIT_CODE" -eq 0 ]; then

# CLAUDE.md bootstrap phase
if echo "$PROMPT" | grep -q "CLAUDE.md"; then
    cat > /workspace/CLAUDE.md << 'EOF'
# CLAUDE.md
Mock project context generated for testing.
## Commands
- Run tests: echo "all tests pass"
## Architecture
Single module project used in pipeline orchestration tests.
EOF
fi

# Architect Phase 1 — brainstorm candidates
if echo "$PROMPT" | grep -q "architecture_candidates.md"; then
    mkdir -p /workspace/docs
    cat > /workspace/docs/architecture_candidates.md << 'EOF'
## Option A: Direct Implementation
**Summary:** Minimal abstraction, direct function calls, single module.
**Key design decisions:** No interfaces; one concrete class; inline logic.
**Trade-offs:** Lowest complexity; easiest to reason about; hard to swap implementations.
**Risks:** Refactoring burden grows as requirements evolve.

## Option B: Interface-Based Design
**Summary:** Protocol/interface abstraction separating concerns.
**Key design decisions:** Define contracts first; inject dependencies; use factory.
**Trade-offs:** Moderate complexity; testable with mocks; flexible for future changes.
**Risks:** Slightly over-engineered for small codebases.

## Option C: Plugin Architecture
**Summary:** Fully extensible plugin registry with lifecycle hooks.
**Key design decisions:** Plugin discovery at startup; event bus; lazy loading.
**Trade-offs:** Maximum extensibility; highest initial complexity; runtime overhead.
**Risks:** Significant implementation effort; difficult to debug plugin interactions.
EOF
fi

# Architect Phase 2 — select and write spec
if echo "$PROMPT" | grep -q "approved_architecture.md"; then
    mkdir -p /workspace/docs
    cat > /workspace/docs/approved_architecture.md << 'EOF'
# Approved Architecture: Option B (Interface-Based Design)

## Selection Rationale
Option A is too rigid for the stated growth requirements.
Option C introduces unnecessary complexity at this maturity stage.
Option B provides the right abstraction boundary with manageable overhead.

## File and Directory Changes
- src/interfaces/__init__.py  (new) — define core protocol
- src/interfaces/default.py   (new) — default concrete implementation
- src/core.py                 (modify) — depend on interface, not concrete class
- tests/test_interface.py     (new) — contract tests for the interface

## Implementation Steps (ordered)
1. Write the interface/protocol definition with full docstrings
2. Move existing logic into the default implementation class
3. Update src/core.py to import from interfaces, not concrete modules
4. Wire the factory/registry in the application entry point
5. Write interface contract tests that any implementation must pass
6. Run full test suite and fix regressions
EOF
fi

# Refactor Phase 1 — diagnose and propose options
if echo "$PROMPT" | grep -q "refactor_candidates.md"; then
    mkdir -p /workspace/docs
    cat > /workspace/docs/refactor_candidates.md << 'EOF'
## Option A: Minimal Patch
**Strategy:** Single targeted fix at the call site. Lowest blast radius.
**Changes required:** Add one guard clause in the affected function.
**Trade-offs:** Zero risk to unrelated code; does not address root cause; may recur.

## Option B: Structural Fix
**Strategy:** Refactor the affected module to fix the root cause.
**Changes required:** Reorganize error handling; update callers; add validation layer.
**Trade-offs:** Fixes root cause; moderate risk; requires test updates.

## Option C: Module Rewrite
**Strategy:** Rewrite the problematic component from scratch with correct design.
**Changes required:** New implementation; migrate all callers; full test suite rewrite.
**Trade-offs:** Best long-term outcome; highest risk and effort.
EOF
fi

# Refactor Phase 2 — select and write implementation plan
if echo "$PROMPT" | grep -q "approved_fix.md"; then
    mkdir -p /workspace/docs
    cat > /workspace/docs/approved_fix.md << 'EOF'
# Approved Fix: Option B (Structural Fix)

## Selection Rationale
Option A only masks the symptom — the root cause would resurface.
Option C is disproportionate to the scope of the problem.
Option B addresses the root cause within acceptable risk bounds.

## Specific Changes
1. Add input validation layer at the module's public entry point
2. Consolidate error propagation: raise consistent exception types
3. Update callers to handle the new exceptions correctly
4. Clean up any related dead code found during the refactor

## Verification
- Command: pytest tests/ -v
- Expected: all pre-existing tests pass; new regression test passes
- Regression test: confirms the originally-reported failure no longer occurs
EOF
fi

fi  # end: EXIT_CODE -eq 0 guard

exit "$EXIT_CODE"
