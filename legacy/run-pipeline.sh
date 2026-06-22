#!/bin/bash
set -eo pipefail # Fail fast if any pipeline step completely breaks

# ==============================================================================
# Pipeline Runner for tasks.md via claude-dispatch
#
# Automatically executes the sandbox optimization plan in sequential phases.
# ==============================================================================

# Ensure tasks.md exists before running
if [ ! -f "tasks.md" ]; then
    echo "❌ Error: tasks.md not found in the current directory."
    exit 1
fi

echo "=================================================================="
echo "🚀 STARTING SANDBOX OPTIMIZATION AND FEATURE EXTRACTION PIPELINE"
echo "=================================================================="

# ------------------------------------------------------------------------------
# PHASE 1: REFACTORING & CONSOLIDATION
# ------------------------------------------------------------------------------
echo -e "\n🧹 [PHASE 1] Launching Claude to refactor redundancies..."
echo "------------------------------------------------------------------"

# Dispatches only the 'Phase 1' block out of tasks.md to Claude
./launch-dispatch.sh "@tasks.md:Phase 1"

echo -e "\n🧪 [VERIFICATION] Running system tests to ensure no regressions..."
echo "------------------------------------------------------------------"
if ./tests/run_tests.sh --unit; then
    echo "✅ Verification Pass: All core unit tests passed cleanly."
else
    echo "❌ Regression Detected: Unit tests failed after Phase 1 refactoring."
    echo "🛑 Halting pipeline. Fix the broken refactor before running Phase 2."
    exit 1
fi

# ------------------------------------------------------------------------------
# PHASE 2: FEATURE IMPLEMENTATION
# ------------------------------------------------------------------------------
echo -e "\n✨ [PHASE 2] Launching Claude to build new features..."
echo "   (Auto-Stash, Net Isolation, Gemini Validation, Telemetry Ledger)"
echo "------------------------------------------------------------------"

# Dispatches the 'Phase 2' block out of tasks.md to Claude
./launch-dispatch.sh "@tasks.md:Phase 2"

echo -e "\n🏁 [POST-FLIGHT VERIFICATION] Running full system verification check..."
echo "------------------------------------------------------------------"
if ./tests/run_tests.sh --unit; then
    echo "=================================================================="
    echo "🎉 SUCCESS: Complete engineering cycle completed successfully!"
    echo "📦 All features implemented and verified against unit regressions."
    echo "=================================================================="
else
    echo "⚠️  Partial Success: Features implemented, but new unit tests are failing."
    echo "👉 Run ./tests/run_tests.sh manually to diagnose the failures."
    exit 1
fi
