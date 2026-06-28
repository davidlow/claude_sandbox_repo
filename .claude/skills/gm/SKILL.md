---
name: gm
description: General manager — reads a task list (tasks.md or prompt), creates an isolated git branch per task, invokes the appropriate pipeline skill (architect/refactor/qa), optionally runs a second adversarial QA layer, and merges to base only on full success. Failed branches are preserved for manual review.
argument-hint: "[--tasks <file>] [--qa] [--no-gemini] [<prompt>]"
allowed-tools: Read, Write, Bash(date *), Bash(git checkout*), Bash(git merge*), Bash(git branch*), Bash(git log*), Bash(git rev-parse*), Bash(git status*), Bash(git diff*), Bash(git stash*), Bash(mkdir -p *), Bash(ls *), Bash(echo *), Bash(sed *), Bash(grep *), Bash(cat *), Bash(tr *), Bash(cut *), Bash(cp *), Bash(rm -f *), Bash(unset *), Bash(bash lib/*)
---

# General Manager

You are orchestrating a hands-off coding engine. You decompose a task list into discrete units of work, implement each in an isolated git branch using the appropriate pipeline skill, verify with layered testing, and merge to the base branch only when all tests pass.

## Progress visibility

You write two files continuously throughout the run so the user can check status from a second terminal at any time:

- **`gm-status.md`** — live table updated after each task; the quickest way to see current state
- **`docs/decisions/<timestamp>_gm_<slug>.md`** — decision log capturing all per-task events

To check progress while running in `claude-yolo`:
```bash
cat gm-status.md          # live status table
/logging read gm          # decision log summary (inside claude-box)
```

---

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

## Step 2: Capture Base Branch and Initialize Logging

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

Initialize the decision log:
```bash
LOG_FILE=$(bash lib/logging.sh init gm "<description>" claude-sonnet-4-6)
```

Log the base branch and flags:
```bash
bash lib/logging.sh note "$LOG_FILE" "Configuration" "Base: <BASE_BRANCH> | QA layer: <qa_layer> | Gemini: <enabled/disabled>"
```

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

Log the full task plan:
```bash
bash lib/logging.sh note "$LOG_FILE" "Task Plan" "N tasks identified: 1. [architect] <task1> | 2. [refactor] <task2> | ..."
```

Create `gm-status.md` and populate it with all tasks:
```bash
bash lib/gm-status.sh init "$BASE_BRANCH" N "$(date '+%Y-%m-%d %H:%M')"
bash lib/gm-status.sh set-task 1 architect "Add user authentication"
bash lib/gm-status.sh set-task 2 refactor "Fix login session timeout"
bash lib/gm-status.sh set-task 3 qa "Write tests for payment module"
# (repeat set-task for each task in the list)
```

## Step 3b: Complexity Assessment

For each task in the list, evaluate whether it is **simple** or **standard**:

**Simple** — ALL of the following must be true:
- Narrowly scoped: modifies one specific function, adds a log line, renames a variable, updates a config value, or makes a localized mechanical change
- No ambiguity about the correct approach — no design decision is required
- Does not introduce new abstractions, new APIs, new modules, or cross-cutting concerns
- Can be fully described in one sentence without qualifications

**Standard** — ANY of the following makes a task standard:
- Requires choosing between multiple viable design approaches
- Introduces a new system component, module, or interface contract
- Has non-obvious interactions with other parts of the codebase
- Task description contains hedging language ("might", "explore", "consider", "redesign")
- The implementer would need to make a significant judgment call before writing code

**QA-type tasks are always standard** — the full adversarial pipeline always benefits them.

Print the annotated plan:
```
📋 Task plan:
  1. [architect / simple]   Add a log line to the auth handler
  2. [architect / standard] Add plugin system for payment providers
  3. [qa]                   Write tests for auth module
```

Log the complexity decisions:
```bash
bash lib/logging.sh note "$LOG_FILE" "Complexity Assessment" "Task 1: simple (direct-implement) | Task 2: standard (architect) | ..."
```


## Step 4: Execute Tasks

Initialize a results tracking table (in memory):
- `results`: array of `{task, branch, skill, status}` objects

For each task in order:

### 4a. Create Task Wiki Directory

Before creating the feature branch, set up the per-task wiki directory:

```bash
SLUG=$(echo "<task-text>" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/-\{2,\}/-/g' | sed 's/^-//;s/-$//' | cut -c1-40)
DATE=$(date +%Y%m%d-%H%M)
TASK_ID="${DATE}_${SLUG}"
bash lib/wiki-init.sh "$TASK_ID" "<task-text>" "<simple|standard>" "$BASE_BRANCH"
```

Announce: "📁 Task wiki: docs/${TASK_ID}/"

### 4b. Create Isolated Branch

Generate a URL-safe slug from the task description:
```bash
SLUG=$(echo "<task-text>" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/-\{2,\}/-/g' | sed 's/^-//;s/-$//' | cut -c1-40)
DATE=$(date +%Y%m%d-%H%M)
BRANCH="gm/${DATE}-${SLUG}"
git checkout -b "$BRANCH"
```

If `git checkout -b` fails, log:
```bash
bash lib/logging.sh note "$LOG_FILE" "Task N: Branch" "❌ Could not create branch — skipped: <task>"
bash lib/gm-status.sh update N "" "❌ branch failed"
```
Add to results as failed and continue to next task (staying on base branch).

On success, log and update status:
```bash
bash lib/logging.sh note "$LOG_FILE" "Task N: Branch" "✅ Created <branch>"
bash lib/gm-status.sh update N "$BRANCH" "⚙️ running <skill-type>"
```

Update the `**Branch:**` line in `docs/${TASK_ID}/overview.md` with the actual branch name:
```bash
sed -i "s/\*\*Branch:\*\* <pending>/**Branch:** ${BRANCH}/" "docs/${TASK_ID}/overview.md"
```

Announce: "🌿 Branch created: $BRANCH"
Announce: "⚙️  Running /[skill-type]: <task>"

### 4c. Invoke Pipeline Skill

Route based on task type AND complexity:

- If task type is **qa**: invoke `/qa <task-text> $gemini_flag`
- If task type is **architect** or **refactor** AND complexity is **simple**: invoke `/implement <task-text>` (standalone direct-task mode — no spec file, skips brainstorm/decide phases)
- If task type is **architect** AND complexity is **standard**: invoke `/architect <task-text> $gemini_flag`
- If task type is **refactor** AND complexity is **standard**: invoke `/refactor <task-text> $gemini_flag`

For the overview.md row label, use `direct (simple task)` for simple-complexity tasks and the skill type name for standard tasks.

Wait for the skill to complete. Note whether the final output contains:
- `✅` and "complete" or "passing" → **primary_success = true**
- `❌` or "failing" or "failed" → **primary_success = false**

Log the outcome:
```bash
bash lib/logging.sh note "$LOG_FILE" "Task N: <skill-type> result" "✅ success — <task>"  # or ❌ failed
```

**Populate the task wiki** — copy all artifacts and update `overview.md` in one command:
```bash
bash lib/wiki-update.sh "$TASK_ID" "$SKILL_TYPE" 1 \
  "$( [[ "$primary_success" == "true" ]] && echo success || echo failed )"
```
This script locates the phase log, copies it and all generated artifacts into the wiki subdirectories, and updates the Pipeline Steps, Decision Logs, and artifact sections of `overview.md` atomically.

### 4d. QA Layer (optional second pass)

Only if `qa_layer=true` AND `primary_success=true` AND the skill type was `architect` or `refactor`:

```
/qa <task-text> --no-gemini
```

Note the outcome:
- `✅` → **qa_success = true**
- `❌` → **qa_success = false**

Log:
```bash
bash lib/logging.sh note "$LOG_FILE" "Task N: QA layer" "✅ passed"  # or ❌ failed
```

**Populate the task wiki with QA results:**
```bash
bash lib/wiki-update.sh "$TASK_ID" "qa" 2 \
  "$( [[ "$qa_success" == "true" ]] && echo success || echo failed )" adversarial
```

Overall task success = `primary_success AND (qa_layer is false OR skill was qa OR qa_success)`.

### 4e. Merge or Preserve

**On full success:**
```bash
git checkout "$BASE_BRANCH"
git merge --no-ff "$BRANCH" -m "gm: <task-text>"
```

If `git merge` fails (conflict):
```bash
bash lib/logging.sh note "$LOG_FILE" "Task N: Merge" "⚠️ Conflict — branch preserved: <branch>"
bash lib/gm-status.sh update N "$BRANCH" "⚠️ merge conflict"
```
Treat as failed.

On clean merge:
```bash
bash lib/logging.sh note "$LOG_FILE" "Task N: Merge" "✅ Merged to <BASE_BRANCH>"
bash lib/gm-status.sh update N "$BRANCH" "✅ merged"
```
Record `{task, branch, skill, status: "✅ merged"}`.

If `tasks_file` exists, update its checkbox: change `- [ ] <task-text>` to `- [x] <task-text>` using sed.

**Finalize overview.md on success:**
```bash
sed -i "s/\*\*Status:\*\* in-progress/**Status:** success/" "docs/${TASK_ID}/overview.md"
sed -i "s/\*(pending)\*/All phases completed and merged to ${BASE_BRANCH}/" "docs/${TASK_ID}/overview.md"
```

**On failure:**
```bash
git checkout "$BASE_BRANCH"
```

Leave the failed branch alive.
```bash
bash lib/logging.sh note "$LOG_FILE" "Task N: Merge" "❌ Not merged — branch preserved: <branch>"
bash lib/gm-status.sh update N "$BRANCH" "❌ failed"
```
Record `{task, branch, skill, status: "❌ failed — branch preserved"}`.

Log immediately: "❌ Task failed — branch preserved for review: $BRANCH"

**Finalize overview.md on failure:**
```bash
sed -i "s/\*\*Status:\*\* in-progress/**Status:** failed/" "docs/${TASK_ID}/overview.md"
sed -i "s/\*(pending)\*/Failed — branch preserved: ${BRANCH}/" "docs/${TASK_ID}/overview.md"
```

Continue to the next task.


## Step 5: Summary Report and Finalize Log

Count successes and failures from the results table.

Finalize the decision log and gm-status:
```bash
bash lib/logging.sh outcome "$LOG_FILE" "<success|failed>" "<N> merged, <M> failed"
bash lib/gm-status.sh done <N-merged> <M-failed>
```
Use `success` if all tasks merged, `failed` if any failed.

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
- Print: "Decision log: `<LOG_FILE>`"

If all tasks succeeded:
- Print: "✅ All tasks complete and merged to <BASE_BRANCH>"
- Print: "Decision log: `<LOG_FILE>`"

## Notes

- Tasks execute **sequentially**. Each merge updates the base branch so later tasks build on earlier successful work.
- Failed tasks do NOT block subsequent tasks — the GM continues through the full list.
- The QA layer (`--qa`) invokes `/qa` as an adversarial red-team pass AFTER the primary pipeline succeeds. This is the second test layer. Merge only happens if both layers pass.
- Git branches provide the isolation "sandbox" — each feature is contained, rollback is `git checkout <base>`, and failures never touch working code on the base branch.
- Sub-skills run with `context: fork` — they have no memory of each other. All coordination happens through files (`docs/`, `tests/`) and the git working tree.
- `gm-status.md` is intentionally left on disk after completion as a record. Delete it manually if not needed.
- **Complexity routing**: simple tasks invoke `/implement` directly, skipping brainstorm/decide. The QA layer (`--qa`) still runs after direct-implement — adversarial testing is never skipped.
- **Log discovery**: `/logging init` writes the log path to `docs/.logging-<pipeline>-last` (e.g. `docs/.logging-architect-last`) at startup — this file is never deleted. `lib/wiki-update.sh` reads it as the primary mechanism to find the sub-skill's log. If missing, the script falls back to the newest matching `docs/decisions/*_<skill>.md` file. `LOGGING_TASK_DIR` is not used (it doesn't propagate to fork contexts).
- **Wiki population**: After each sub-skill returns, call `bash lib/wiki-update.sh "$TASK_ID" "$SKILL_TYPE" <step> <success|failed>`. The script handles all artifact copying and `overview.md` updates atomically — do not attempt to do these manually.
- **Wiki directories** (`docs/YYYYMMDD-HHMM_*/`) are runtime artifacts excluded from version control. They persist for the session and are browsable immediately after a /gm run.
