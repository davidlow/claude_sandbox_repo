---
name: logging
description: Manage docs/decisions/ decision log files. Actions: init (create a new log, prints path), section (append a file's content), note (append inline text), outcome (finalize with success/failed status), read (show recent logs).
argument-hint: "[init|section|note|outcome|read] <pipeline> <task/args...>"
context: fork
allowed-tools: Write, Edit, Read, Bash(date *), Bash(mkdir -p *), Bash(ls *), Bash(sed *), Bash(echo *), Bash(rm -f *), Bash(cat *)
---

# Logging

Manage decision logs in `docs/decisions/`. These logs create an audit trail of what each pipeline run attempted and whether it succeeded.

## Parse Action

The first word of `$ARGUMENTS` is the action. Parse the remaining words for action-specific arguments.

---

## Action: `init`

**Usage:** `init [--task-dir <path>] <pipeline> <task description> <model>`

Creates a new timestamped decision log file.

### Determine log directory (TASK_DIR):

1. Check if `--task-dir <path>` is present in the arguments. If found, capture `<path>` as `TASK_DIR` and strip `--task-dir <path>` from the remaining arguments before parsing pipeline/description/model.
2. If `--task-dir` was not found but the environment variable `LOGGING_TASK_DIR` is set and non-empty, use its value as `TASK_DIR`.
3. If neither is set, `TASK_DIR` defaults to `docs`.

### Create directories:

Run: `mkdir -p "${TASK_DIR}/decisions" docs/decisions docs/progress`

(Always create `docs/decisions` and `docs/progress` regardless of `TASK_DIR` so fallback routing and progress logging always work. When TASK_DIR=docs, the first two arguments refer to the same directory.)

### Construct the log file path:

1. Generate timestamp: run `date '+%Y%m%d_%H%M'`
2. Generate slug from task description:
   - Lowercase the task text
   - Replace any non-alphanumeric characters with `-`
   - Remove consecutive dashes
   - Truncate to 40 characters
   - Strip leading/trailing dashes
3. Construct path: `${TASK_DIR}/decisions/<timestamp>_<slug>_<pipeline>.md`

### Write log header:

Write this header to the file:

```markdown
# <pipeline>: <task description>

**Date:** <YYYY-MM-DD HH:MM>
**Pipeline:** <pipeline>
**Model:** <model>
**Status:** in-progress

## Task

<task description>
```

### Write sentinel:

Compute the absolute path of the log file and write it as a single line to `docs/.logging-current`. Use `echo` or `printf` — do not require additional tools.

### Output:

**Print the full file path** to stdout (the orchestrator captures this).

---

## Action: `section`

**Usage:** `section [log-file] <section-title> [content-file]`

Appends a titled section to an existing log file.

### Resolve active log file:

- If the first argument after `section` is a path to an existing file, use it as the log file (backward-compatible).
- Otherwise, read `docs/.logging-current` (one-line file) to get the active log path.
- If `docs/.logging-current` does not exist either, fall back to the most recently modified file in `docs/decisions/` (run `ls -t docs/decisions/*.md 2>/dev/null | head -1`).

Parse the remaining arguments as `<section-title>` and optional `<content-file>`.

### Append section:

- If `content-file` is provided and exists: append `## <section-title>` followed by the file's contents
- If `content-file` is not provided or does not exist: append `## <section-title>` followed by `*(not available)*`

---

## Action: `note`

**Usage:** `note [log-file] <section-title> <note-text>`

Appends a titled section with inline text (no file reading).

### Resolve active log file:

- If the first argument after `note` is a path to an existing file, use it as the log file (backward-compatible).
- Otherwise, read `docs/.logging-current` to get the active log path.
- If `docs/.logging-current` does not exist, fall back to the most recently modified file in `docs/decisions/`.

Parse the remaining arguments as `<section-title>` and `<note-text>`.

### Append:

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

**Usage:** `outcome [log-file] <status> [notes]`

Finalizes the log with a status.

### Resolve active log file:

- If the first argument after `outcome` is a path to an existing file, use it as the log file (backward-compatible).
- Otherwise, read `docs/.logging-current` to get the active log path.
- If `docs/.logging-current` does not exist, fall back to the most recently modified file in `docs/decisions/`.

Parse the remaining arguments as `<status>` and optional `<notes>`.

### Finalize:

1. Edit the log file: replace the line `**Status:** in-progress` with `**Status:** <status>`
   - Use Bash: `sed -i "s/\*\*Status:\*\* in-progress/**Status:** <status>/g" "<log-file>"`
2. Append to the log file:
```markdown

## Outcome

**Result:** <status>

<notes (if provided)>
```

### Write last-completed sentinel:

Before deleting, persist the log path so orchestrators (like `/gm`) can find this log after the skill exits:
```bash
echo "<absolute-path-of-log-file>" > docs/.logging-last-completed
```

### Delete sentinel:

After finalizing: `rm -f docs/.logging-current`

---

## Action: `read`

**Usage:** `read [--task-id <id>] [pipeline]`

Shows recent decision logs.

### Resolve log directory:

- If `--task-id <id>` flag is present, list files in `docs/<id>/decisions/` instead of `docs/decisions/`.
- Otherwise, if `docs/.logging-current` exists and points to an existing file, display that file first (it is the currently-active log).
- Use `docs/decisions/` as the default directory when no flag is given.

### Display:

1. Run `ls -lt <log-dir>/ 2>/dev/null | head -20` to list recent logs
2. If `pipeline` argument provided, filter to logs ending in `_<pipeline>.md`
3. Show the list of log files with timestamps
4. For the 3 most recent, print the first 20 lines of each
