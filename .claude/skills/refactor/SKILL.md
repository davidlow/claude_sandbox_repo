---
name: refactor
description: Three-phase bug fix and refactoring pipeline. Phase 1 (haiku): diagnose and propose 3 solution options. Phase 2 (sonnet): evaluate and write a step-by-step fix plan. Phase 3: implement the plan and run tests. Mirrors launch-refactor.sh.
argument-hint: "<bug or refactor description> [--no-gemini]"
allowed-tools: Read, Write, Bash(date *), Bash(git diff*), Bash(python3 *), Bash(source /workspace/lib/launch-lib.sh*), Bash(mktemp), Bash(rm -f *), Bash(mkdir -p *), Bash(ls *), Bash(echo *), Bash(bash lib/*)
---

# Refactor Pipeline

You are orchestrating a three-phase bug fix and refactoring pipeline. Phases run in isolated contexts via the Skill tool and communicate through files on disk.

## Step 1: Parse Arguments

Parse `$ARGUMENTS`:
- Strip `--no-gemini` flag if present → set `gemini_enabled=false`
- Also disable Gemini if `GEMINI_API_KEY` is not set
- Remaining text is the target description (the bug or refactor to address)

Announce: "🚀 Starting /refactor pipeline for: <target>"

## Step 2: Initialize Decision Log

Run the logging script and capture the returned path as `LOG_FILE`:
```bash
LOG_FILE=$(bash lib/logging.sh init refactor "$TARGET" claude-sonnet-4-6)
```

## Step 3: Capture Current State

Run via Bash to give Phase 1 (diagnosis) visibility into uncommitted changes:
```bash
git diff > .current_state.diff 2>/dev/null || true
```

## Step 4: Phase 1 — Diagnose (haiku, isolated context)

Invoke `/brainstorm` in refactor mode:
```
/brainstorm refactor <target>
```

The brainstorm skill in refactor mode reads `.current_state.diff` and proposes three solutions: minimal patch, structural fix, and module rewrite.

After it returns, clean up the diff file:
```bash
rm -f .current_state.diff
```

Check that `docs/refactor_candidates.md` exists.

**If the file is missing:** Retry once:
```
/brainstorm refactor <target>
```

**If still missing after retry:**
```bash
bash lib/logging.sh outcome "$LOG_FILE" failed "Phase 1 diagnosis did not produce candidates file"
```
Report failure and exit.

**On success:**
```bash
bash lib/logging.sh section "$LOG_FILE" "Phase 1: Diagnosis" docs/refactor_candidates.md
```

## Step 5: Phase 2 — Select Approach (sonnet, isolated context)

Invoke `/decide` in refactor mode:
```
/decide refactor <target>
```

After it returns, check that `docs/approved_fix.md` exists.

**If the file is missing:** Retry once:
```
/decide refactor <target>
```

**If still missing after retry:**
```bash
bash lib/logging.sh outcome "$LOG_FILE" failed "Phase 2 evaluation did not produce an approved fix plan"
```
Report failure and exit.

**On success:**
```bash
bash lib/logging.sh section "$LOG_FILE" "Phase 2: Approved Fix" docs/approved_fix.md
```

## Step 6: Phase 3 — Implement Fix (isolated context)

Invoke `/implement` in refactor mode:
```
/implement refactor
```

After it returns:

**On success ("✅ Implementation complete — all tests passing"):**
```bash
bash lib/logging.sh outcome "$LOG_FILE" success
```
Report: "✅ /refactor pipeline complete. Decision log: <LOG_FILE>"

**On failure ("❌ Tests failing"):**
```bash
bash lib/logging.sh outcome "$LOG_FILE" failed "Implementation complete but tests are failing"
```

If `gemini_enabled=true`, offer a diagnostic:
```
/geminiapi refactor-diagnosis <target>
```
Then report: "⚠️ /refactor: implementation done but tests failing. Gemini diagnosis written to GEMINI_ADVICE.md. Decision log: <LOG_FILE>"

**On other failure:**
```bash
bash lib/logging.sh outcome "$LOG_FILE" failed "<error summary>"
```
Report failure with decision log path.

## Notes

- `.current_state.diff` captures uncommitted changes before Phase 1 reads them, then is cleaned up.
- Phase artifacts: `docs/refactor_candidates.md` (diagnosis), `docs/approved_fix.md` (plan).
- Gemini is called on Phase 3 failure (circuit-breaker role) rather than between phases, matching `launch-refactor.sh` behavior.
- Each phase runs in an isolated context — fresh context window, reads only the files it needs.
