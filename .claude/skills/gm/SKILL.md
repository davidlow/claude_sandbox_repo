---
name: gm
description: General manager — reads a task list (tasks.md or prompt), creates an isolated git branch per task, invokes the appropriate pipeline skill (architect/refactor/qa), optionally runs a second adversarial QA layer, and merges to base only on full success. Failed branches are preserved for manual review.
argument-hint: "[--tasks <file>] [--qa] [--no-gemini] [<prompt>]"
allowed-tools: Read, Write, Bash(date *), Bash(git checkout*), Bash(git merge*), Bash(git branch*), Bash(git log*), Bash(git rev-parse*), Bash(git status*), Bash(git diff*), Bash(git stash*), Bash(mkdir -p *), Bash(ls *), Bash(echo *), Bash(sed *), Bash(grep *), Bash(cat *), Bash(tr *), Bash(cut *)
---

# General Manager

You are orchestrating a hands-off coding engine. You decompose a task list into discrete units of work, implement each in an isolated git branch using the appropriate pipeline skill, verify with layered testing, and merge to the base branch only when all tests pass.

## Step 1: Parse Arguments

From `$ARGUMENTS`, extract:
- `--tasks <file>` → read task list from that file instead of `tasks.md`
- `--qa` → after `architect`/`refactor` succeeds, also run `/qa` as a second adversarial test layer before merging
- `--no-gemini` → pass through to all sub-skills
- Everything else → treat as a free-text task description

Set:
- `tasks_file`: the `--tasks` argument value, or `tasks.md` if no `--tasks` was given
- `qa_layer`: true if `--qa` was present, false otherwise
- `gemini_flag`: `--no-gemini` if that flag was present, empty string otherwise
- `free_text`: remaining text after stripping all flags

Announce: "🗂️ General Manager starting"

## Step 2: Capture Base Branch

```bash
BASE_BRANCH=$(git rev-parse --abbrev-ref HEAD)
echo "Base branch: $BASE_BRANCH"
```

If `git rev-parse` fails, report "❌ Not a git repository — cannot manage branches" and exit.

Check for uncommitted changes:
```bash
git status --porcelain
```
If output is non-empty, warn: "⚠️ Working tree has uncommitted changes — feature branches will be created from current (potentially dirty) state."

## Step 3: Build Task List

**If `tasks_file` exists on disk:**
Read the file. Parse every line matching `- [ ] <text>` or `- <text>` (excluding `- [x]` which are already done) as a task. If the file is empty or has no parseable tasks, fall through to free-text.

**If `free_text` is non-empty (and no tasks file or it had no tasks):**
Reason inline — decompose the text into a numbered list of discrete, independently-implementable tasks. Each task should be achievable in a single pipeline invocation. Print the decomposed list before proceeding so the user can see what you plan to do.

**For each task, determine skill type:**
- Contains `Fix:`, `Bug:`, `Hotfix:`, `Patch:`, `Bugfix:`, or the phrase starts with "fix", "patch", "repair", "debug", "correct" → **`refactor`**
- Contains `QA:`, `Test:`, `Tests:`, `Coverage:`, or the phrase starts with "test", "write tests", "add tests", "cover" → **`qa`**
- Everything else (new features, additions, refactors, improvements) → **`architect`**

Print the task plan:
```
📋 Task plan:
  1. [architect] Add user authentication
  2. [refactor]  Fix login session timeout
  3. [qa]        Write tests for payment module
```

## Step 4: Execute Tasks

Initialize a results tracking table (in memory):
- `results`: array of `{task, branch, status}` objects

For each task in order:

### 4a. Create Isolated Branch

Generate a URL-safe slug from the task description:
```bash
SLUG=$(echo "<task-text>" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/-\{2,\}/-/g' | sed 's/^-//;s/-$//' | cut -c1-40)
DATE=$(date +%Y%m%d-%H%M)
BRANCH="gm/${DATE}-${SLUG}"
git checkout -b "$BRANCH"
```

If `git checkout -b` fails, log `❌ Could not create branch for task: <task>`, add to results as failed, and continue to next task (staying on base branch).

Announce: "🌿 Branch created: $BRANCH"
Announce: "⚙️  Running /[skill-type]: <task>"

### 4b. Invoke Pipeline Skill

Based on detected type, invoke the skill with the task text and flags:

- **architect**: `/architect <task-text> $gemini_flag`
- **refactor**: `/refactor <task-text> $gemini_flag`
- **qa**: `/qa <task-text> $gemini_flag`

Wait for the skill to complete. Note whether the final output contains:
- `✅` and "complete" or "passing" → **primary_success = true**
- `❌` or "failing" or "failed" → **primary_success = false**

### 4c. QA Layer (optional second pass)

Only if `qa_layer=true` AND `primary_success=true` AND the skill type was `architect` or `refactor`:

```
/qa <task-text> --no-gemini
```

Note the outcome:
- `✅` → **qa_success = true**
- `❌` → **qa_success = false**

Overall task success = `primary_success AND (qa_layer is false OR skill was qa OR qa_success)`.

### 4d. Merge or Preserve

**On full success:**
```bash
git checkout "$BASE_BRANCH"
git merge --no-ff "$BRANCH" -m "gm: <task-text>"
```

If `git merge` fails (conflict), log: "⚠️ Merge conflict on task <N>: <task-text> — branch preserved: $BRANCH" and treat as failed.

On clean merge: record `{task: <task-text>, branch: $BRANCH, status: "✅ merged"}`.

If `tasks_file` exists, update its checkbox: change `- [ ] <task-text>` to `- [x] <task-text>` using sed.

**On failure:**
```bash
git checkout "$BASE_BRANCH"
```

Leave the failed branch alive. Record `{task: <task-text>, branch: $BRANCH, status: "❌ failed — branch preserved"}`.

Log immediately: "❌ Task failed — branch preserved for review: $BRANCH"

Continue to the next task.

## Step 5: Summary Report

After all tasks have been processed, print:

```
## General Manager Summary

Base branch: <BASE_BRANCH>

| # | Task | Branch | Status |
|---|------|--------|--------|
| 1 | Add user auth | gm/20260622-1430-add-user-auth | ✅ merged |
| 2 | Fix login bug | gm/20260622-1445-fix-login-bug | ❌ failed |
```

If any tasks failed:
- List the failed branches explicitly
- Print: "To inspect a failed implementation: `git checkout <branch>`"
- Print: "To discard a failed branch: `git branch -D <branch>`"

If all tasks succeeded:
- Print: "✅ All tasks complete and merged to <BASE_BRANCH>"

## Notes

- Tasks execute **sequentially**. Each merge updates the base branch so later tasks build on earlier successful work.
- Failed tasks do NOT block subsequent tasks — the GM continues through the full list.
- The QA layer (`--qa`) invokes `/qa` as an adversarial red-team pass AFTER the primary pipeline succeeds. This is the second test layer. Merge only happens if both layers pass.
- Git branches provide the isolation "sandbox" — each feature is contained, rollback is `git checkout <base>`, and failures never touch working code on the base branch.
- Sub-skills run with `context: fork` — they have no memory of each other. All coordination happens through files (`docs/`, `tests/`) and the git working tree.
