---
name: architect
description: Multi-phase architectural design and implementation pipeline. Phase 1 (haiku): brainstorm 3 approaches → optional Gemini adversarial critique → Phase 2 (sonnet): evaluate and write spec → Phase 3: implement and test. Mirrors launch-architect.sh. Use for new features or significant architectural changes.
argument-hint: "<task description> [--no-gemini]"
allowed-tools: Read, Write, Bash(date *), Bash(python3 *), Bash(source /workspace/lib/launch-lib.sh*), Bash(mktemp), Bash(rm -f *), Bash(find . *), Bash(head -c *), Bash(wc -c *), Bash(mkdir -p *), Bash(ls *), Bash(echo *), Bash(bash lib/*)
---

# Architect Pipeline

You are orchestrating a multi-phase architectural design and implementation pipeline. Each phase runs in an isolated context via the Skill tool. Phases communicate through files on disk — not through conversation context.

## Step 1: Parse Arguments

Parse `$ARGUMENTS`:
- Strip `--no-gemini` flag if present → set `gemini_enabled=false`, else `gemini_enabled=true`
- Also disable Gemini if `GEMINI_API_KEY` is not set (check with `bash -c 'echo "${GEMINI_API_KEY:+set}"'`)
- Remaining text is the task description

Announce the pipeline: "🚀 Starting /architect pipeline for: <task>"

## Step 2: Initialize Decision Log

Initialize the decision log and capture the path:
```bash
LOG_FILE=$(bash lib/logging.sh init architect "$TASK" claude-sonnet-4-6)
```

## Step 3: Phase 1 — Brainstorm (haiku, isolated context)

Invoke the `/brainstorm` skill:
```
/brainstorm architect <task>
```

After it returns, check that `docs/architecture_candidates.md` exists.

**If the file is missing:** Retry once:
```
/brainstorm architect <task>
```

**If still missing after retry:** Log failure and stop:
```bash
bash lib/logging.sh outcome "$LOG_FILE" failed "Phase 1 brainstorm did not produce candidates file"
```
Then report the failure to the user and exit.

**On success:** Append to the decision log:
```bash
bash lib/logging.sh section "$LOG_FILE" "Phase 1: Brainstorm" docs/architecture_candidates.md
```

## Step 4: Gemini Architectural Critique (optional, isolated context)

Only if `gemini_enabled=true`:

```
/geminiapi architect-critique <task>
```

This is **non-fatal**. Whether it succeeds or fails, continue to Phase 2.

If `docs/gemini_architectural_audit.md` was created:
```bash
bash lib/logging.sh note "$LOG_FILE" "Gemini Critique" "completed — docs/gemini_architectural_audit.md"
```
Otherwise:
```bash
bash lib/logging.sh note "$LOG_FILE" "Gemini Critique" "skipped or failed — Phase 2 evaluates without external critique"
```

## Step 5: Phase 2 — Evaluate and Select (sonnet, isolated context)

Invoke the `/decide` skill:
```
/decide architect <task>
```

After it returns, check that `docs/approved_architecture.md` exists.

**If the file is missing:** Retry once:
```
/decide architect <task>
```

**If still missing after retry:** Log failure and stop:
```bash
bash lib/logging.sh outcome "$LOG_FILE" failed "Phase 2 evaluation did not produce an approved spec"
```
Report to user and exit.

**On success:**
```bash
bash lib/logging.sh section "$LOG_FILE" "Phase 2: Approved Design" docs/approved_architecture.md
```

## Step 6: Phase 3 — Implement (isolated context)

Invoke the `/implement` skill:
```
/implement architect
```

After it returns:

**If the skill reported "✅ Implementation complete":**
```bash
bash lib/logging.sh outcome "$LOG_FILE" success
```
Report success: "✅ /architect pipeline complete. Decision log: <LOG_FILE>"

**If the skill reported "❌ Tests failing":**
```bash
bash lib/logging.sh outcome "$LOG_FILE" failed "Implementation complete but tests are failing"
```
Report: "⚠️ /architect pipeline: code implemented but tests are failing. Decision log: <LOG_FILE>"

**If the skill reported another error:**
```bash
bash lib/logging.sh outcome "$LOG_FILE" failed "<summary of error>"
```
Report the failure to the user with the decision log path.

## Notes

- Each `/brainstorm`, `/geminiapi`, `/decide`, and `/implement` call runs in an **isolated context** — it cannot see prior phase conversations, only the files on disk.
- The orchestrator (this skill) maintains state by checking file existence after each phase.
- Phase artifacts are in `docs/`: `architecture_candidates.md`, `gemini_architectural_audit.md`, `approved_architecture.md`.
- The decision log in `docs/decisions/` is the permanent record of this run.
