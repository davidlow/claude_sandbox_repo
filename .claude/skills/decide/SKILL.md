---
name: decide
description: Evaluate architectural candidates and write a definitive implementation spec. Reads docs/architecture_candidates.md or docs/refactor_candidates.md. Writes docs/approved_architecture.md or docs/approved_fix.md. Uses historical decision logs to avoid repeating failed approaches.
argument-hint: "[architect|refactor] <task description>"
context: fork
allowed-tools: Read, Write, Bash(mkdir -p *), Bash(ls *), Bash(date *)
---

# Decide

Your job is to evaluate the candidate approaches produced by `/brainstorm` and write a definitive, detailed implementation spec. You are a senior architect making a final call — be decisive and specific.

## Step 1: Parse Mode and Task

The first word of `$ARGUMENTS` determines which files to read and write:
- `architect` → read `docs/architecture_candidates.md`, write `docs/approved_architecture.md`
- `refactor` → read `docs/refactor_candidates.md`, write `docs/approved_fix.md`
- (anything else) → default to architect mode

## Step 2: Read the Candidates

Read the candidates file. Understand all three options deeply.

Also check:
- `docs/gemini_architectural_audit.md` — if it exists, read it. This is an adversarial external critique from a cross-model audit. Use it to inform (not dictate) your selection.
- `docs/decisions/` — list and read the 3 most recent decision logs for this pipeline type. They show what has already been tried and why it failed. Use as historical context; do not let them anchor your current analysis if the situation has changed.

## Step 3: Select One Approach

Select the single most robust and maintainable option. Consider:
- Correctness and completeness for the stated task
- Maintainability and simplicity over cleverness
- Risk and blast radius of changes
- What the Gemini critique flagged (if present)
- What past attempts revealed about this codebase's constraints

You must choose **one option**. Do not hedge or propose a hybrid unless a hybrid is genuinely the best approach and you describe it as a fourth, distinct option.

## Step 4: Write the Spec

Run `mkdir -p docs` first.

Write to the output file (`docs/approved_architecture.md` or `docs/approved_fix.md`):

```markdown
# Approved Plan: <task summary>

**Date:** <date>
**Selected:** Option <A/B/C> — <Name>

## Rationale

Why this option was selected over the alternatives. What made the others less suitable.

## Changes Required

### Files to modify
- `path/to/file.sh` — what changes and why

### Files to create (if any)
- `path/to/new-file.sh` — purpose

### Files to delete (if any)
- `path/to/old-file.sh` — reason

## Key Interfaces / Data Structures

Any new function signatures, data formats, or contracts that need to be established.

## Implementation Steps

Ordered sequence of steps. Each step must be specific enough that an engineer can execute it without asking clarifying questions.

1. **Step title** — Exact description of what to do. Name specific functions, file paths, line-level changes where relevant.
2. ...

## Verification

How to verify the implementation is correct. Include the test command to run.
```

Do NOT write executable code in the spec itself. This is a design document, not an implementation.

After writing, print a one-line summary: which option was chosen and the path of the output file.
