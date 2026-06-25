---
name: logging
description: Manage docs/decisions/ decision log files. Actions: init (create a new log, prints path), section (append a file's content), note (append inline text), outcome (finalize with success/failed status), read (show recent logs).
argument-hint: "[init|section|note|outcome|read] <pipeline> <task/args...>"
context: fork
allowed-tools: Write, Edit, Read, Bash(date *), Bash(mkdir -p *), Bash(ls *), Bash(sed *), Bash(echo *)
---

# Logging

Manage decision logs in `docs/decisions/`. These logs create an audit trail of what each pipeline run attempted and whether it succeeded.

## Parse Action

The first word of `$ARGUMENTS` is the action. Parse the remaining words for action-specific arguments.

---

## Action: `init`

**Usage:** `init <pipeline> <task description> <model>`

Creates a new timestamped decision log file.

1. Generate timestamp: run `date '+%Y%m%d_%H%M'`
2. Generate slug from task description:
   - Lowercase the task text
   - Replace any non-alphanumeric characters with `-`
   - Remove consecutive dashes
   - Truncate to 40 characters
   - Strip leading/trailing dashes
3. Construct path: `docs/decisions/<timestamp>_<slug>_<pipeline>.md`
4. Run `mkdir -p docs/decisions`
5. Write this header to the file:

```markdown
# <pipeline>: <task description>

**Date:** <YYYY-MM-DD HH:MM>
**Pipeline:** <pipeline>
**Model:** <model>
**Status:** in-progress

## Task

<task description>
```

6. **Print the full file path** to stdout (the orchestrator captures this).

---

## Action: `section`

**Usage:** `section <log-file> <section-title> [content-file]`

Appends a titled section to an existing log file.

- If `content-file` is provided and exists: append `## <section-title>` followed by the file's contents
- If `content-file` is not provided or does not exist: append `## <section-title>` followed by `*(not available)*`

---

## Action: `note`

**Usage:** `note <log-file> <section-title> <note-text>`

Appends a titled section with inline text (no file reading).

Append to the log file:
```
## <section-title>

<note-text>
```

---

## Action: `progress`

**Usage:** `progress <phase> <status> <detail>`

Appends a real-time progress event to `docs/progress/current.jsonl` so a user monitoring a second terminal can see what Claude is actively doing.

1. Run `mkdir -p docs/progress`
2. Construct the JSON event:
   - `timestamp`: run `date -u "+%Y-%m-%dT%H:%M:%SZ"`
   - `source`: `"skill"`
   - `phase`: first argument
   - `status`: second argument
   - `detail`: third argument (truncate to 200 chars if longer)
   - `task`: value of `$ORIGINAL_TASK_PROMPT` env var, truncated to 80 chars; or `""` if unset
3. Append a single JSON line to `docs/progress/current.jsonl` using the format:
   `{"timestamp":"<val>","source":"skill","phase":"<val>","status":"<val>","detail":"<val>","task":"<val>"}`
4. Use Bash `echo` or `printf` — do NOT require `jq`.

---

## Action: `outcome`

**Usage:** `outcome <log-file> <status> [notes]`

Finalizes the log with a status.

1. Edit the log file: replace the line `**Status:** in-progress` with `**Status:** <status>`
   - Use Bash: `sed -i "s/\*\*Status:\*\* in-progress/**Status:** <status>/g" "<log-file>"`
2. Append to the log file:
```markdown

## Outcome

**Result:** <status>

<notes (if provided)>
```

---

## Action: `read`

**Usage:** `read [pipeline]`

Shows recent decision logs.

1. Run `ls -lt docs/decisions/ 2>/dev/null | head -20` to list recent logs
2. If `pipeline` argument provided, filter to logs ending in `_<pipeline>.md`
3. Show the list of log files with timestamps
4. For the 3 most recent, print the first 20 lines of each
