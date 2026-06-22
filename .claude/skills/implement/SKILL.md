---
name: implement
description: Execute an implementation spec from docs/approved_architecture.md or docs/approved_fix.md. Also works standalone for direct tasks. Runs the test suite after implementation and reports results.
argument-hint: "[architect|refactor|<direct task>] [--plan-file <path>]"
context: fork
allowed-tools: Read, Write, Edit, Bash
---

# Implement

Your job is to implement code changes — either from a pre-written spec or from a direct task description.

## Step 1: Determine the Task

Parse `$ARGUMENTS`:

- If it starts with `architect` → read `docs/approved_architecture.md` for the spec
- If it starts with `refactor` → read `docs/approved_fix.md` for the spec
- If it contains `--plan-file <path>` → read the file at that path for the spec
- Otherwise → treat the full `$ARGUMENTS` as a direct task description (standalone use)

## Step 2: Read Context

Before writing any code:
1. Read `CLAUDE.md` for project conventions, test commands, style notes
2. Read all source files mentioned in the spec (or relevant to the task)
3. If there is a spec file: read it completely. Follow it exactly. Do not deviate from the approved design.

## Step 3: Implement

Execute the implementation:
- Follow the spec's ordered steps (if a spec was provided)
- Match the coding style of the surrounding codebase
- Make changes using Edit for existing files, Write for new files
- Do not add features or refactor beyond what the spec or task requires
- Do not add error handling for scenarios that cannot happen

## Step 4: Run Tests

After implementation, find and run the test suite:

1. Check `CLAUDE.md` for the test command
2. Try in order until one works: `./tests/run_tests.sh --unit`, `npm test`, `pytest`, `go test ./...`, `cargo test`
3. Run the tests and capture output

If tests fail:
- Fix failures that are caused by your changes
- Fix only in ways consistent with the spec (if one was provided)
- Do not silence or skip failing tests

## Step 5: Report

Print a clear summary:
- What was implemented (files changed, key changes made)
- Test results (pass/fail, count)
- Any issues encountered

If tests pass: end with "✅ Implementation complete — all tests passing."
If tests fail: end with "❌ Tests failing after implementation — see details above."
