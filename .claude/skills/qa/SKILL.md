---
name: qa
description: Two-phase adversarial test generation pipeline. Phase 1: write comprehensive tests and pass them. Gemini red-team audit identifies coverage gaps. Phase 2: implement missing test cases and pass the full suite. Mirrors launch-qa.sh.
argument-hint: "<scope description> [--no-gemini]"
allowed-tools: Read, Write, Bash(date *), Bash(python3 *), Bash(source /workspace/lib/launch-lib.sh*), Bash(find . *), Bash(head -c *), Bash(wc -c *), Bash(mktemp), Bash(rm -f *), Bash(mkdir -p *), Bash(ls *), Bash(echo *), Bash(bash lib/*)
---

# QA Pipeline

You are orchestrating a two-phase adversarial test generation pipeline. Phases run in isolated contexts via the Skill tool and communicate through files on disk.

## Step 1: Parse Arguments

Parse `$ARGUMENTS`:
- Strip `--no-gemini` flag if present → set `gemini_enabled=false`
- Also disable Gemini if `GEMINI_API_KEY` is not set
- Remaining text is the scope description

Announce: "🚀 Starting /qa pipeline for: <scope>"

## Step 2: Initialize Decision Log

Run the logging script and capture the returned path as `LOG_FILE`:
```bash
LOG_FILE=$(bash lib/logging.sh init qa "$SCOPE" claude-sonnet-4-6)
```

## Step 3: Phase 1 — Test Generation (isolated context)

Invoke `/implement` with a test-writing task:
```
/implement Write a comprehensive test suite for: <scope>. Cover happy paths, common error cases, boundary conditions, and edge cases you can identify from reading the code. Run the tests immediately after writing them using Bash. Fix any failures until all tests pass. The full suite must pass cleanly before you stop. Check CLAUDE.md for the test command.
```

After it returns, check the return message:

**On success (reported "✅ Implementation complete — all tests passing"):**

List any new test files created:
```bash
git diff --name-only HEAD | grep -E '(test|spec)' || true
```

```bash
bash lib/logging.sh note "$LOG_FILE" "Phase 1: Test Generation" "Tests written and passing — new/modified test files: <list>"
```
Proceed to Gemini audit.

**On failure:**
```bash
bash lib/logging.sh note "$LOG_FILE" "Phase 1: Test Generation" "FAILED — tests could not all pass"
```

If `gemini_enabled=false`: finalize log with failure, report to user, and exit.
If `gemini_enabled=true`: still proceed to Gemini audit (it may identify what's wrong).

## Step 4: Gemini Adversarial QA Audit (optional, isolated context)

Only if `gemini_enabled=true`:

```
/geminiapi qa-audit <scope>
```

This is **non-fatal**.

If `tests/gemini_missing_coverage.md` was created:

Count the missing test cases identified (grep for numbered list items):
```bash
grep -c '^\s*[0-9]\+\.' tests/gemini_missing_coverage.md 2>/dev/null || echo "unknown"
```

```bash
bash lib/logging.sh note "$LOG_FILE" "Gemini QA Audit" "completed — <N> missing cases identified → tests/gemini_missing_coverage.md"
```
Proceed to Phase 2.

If the file was not created:
```bash
bash lib/logging.sh note "$LOG_FILE" "Gemini QA Audit" "skipped or failed — no missing coverage file produced"
```
Finalize log based on Phase 1 outcome:
```bash
bash lib/logging.sh outcome "$LOG_FILE" "<Phase 1 status>"
```
Report Phase 1 result to user and exit.

## Step 5: Phase 2 — Implement Missing Coverage (isolated context)

Invoke `/implement` with the remediation task:
```
/implement Read tests/gemini_missing_coverage.md carefully. It contains a numbered list of missing test cases identified by an adversarial Red Team audit. Implement EVERY test case listed — do not skip any. After implementing all new tests, run the complete test suite and ensure everything passes. Fix any failures.
```

After it returns:

**On success:**
```bash
bash lib/logging.sh outcome "$LOG_FILE" success "Both phases complete — all tests passing including Gemini-identified gaps"
```
Report: "✅ /qa pipeline complete. All tests passing. Decision log: <LOG_FILE>"

**On failure:**
```bash
bash lib/logging.sh outcome "$LOG_FILE" failed "Phase 2 remediation did not achieve fully passing suite"
```
Report failure with decision log path.

## Notes

- Phase 1 writes new test files to the project's test directory.
- The Gemini audit reads ALL source and test files (up to 500KB), looking for edge cases, boundary conditions, race conditions, error paths that are untested.
- Phase 2 implements the Gemini-identified cases and verifies the complete suite.
- Each phase runs in an isolated context — no shared conversation history between phases.
