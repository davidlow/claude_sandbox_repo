# Skills and Commands Overview

## Overview

The `.claude/` directory contains 8 pipeline skills, each with a corresponding thin command alias. Skills implement multi-phase AI workflows; commands are the user-facing entry points.

---

## Settings (`/.claude/settings.json`)

Grants Bash permissions to the skill harness:

| Category | Permitted Commands |
|----------|--------------------|
| Infrastructure | `source /workspace/lib/launch-lib.sh*` |
| Language | `python3 *` |
| Directories | `mkdir -p docs*`, `mkdir -p tests*`, `ls docs*`, `ls tests*` |
| Git | `git diff*`, `git status*` |
| Search | `find . *`, `grep *`, `sed *` |
| Utilities | `date *`, `head -c *`, `wc -c *`, `mktemp`, `rm -f /tmp/*` |

---

## Skills

### `gm`

Hands-off coding engine — the top-level orchestrator for multi-task projects.

**Usage:** `/gm [--tasks <file>] [--qa] [--no-gemini] [<prompt>]`

**Inputs:** `tasks.md` (default), a specified file, or a free-text prompt (auto-decomposed)

**Flow for each task:**
1. Creates isolated branch `gm/YYYYMMDD-HHMM-<slug>` from current base
2. Detects task type → invokes `/architect`, `/refactor`, or `/qa`
3. With `--qa`: runs `/qa` as a second adversarial test layer after the primary skill succeeds
4. On full success: merges to base with `git merge --no-ff`, marks `- [x]` in tasks.md
5. On failure: leaves branch alive for review, continues to next task

**Type detection keywords:**

| Keywords | Skill invoked |
|----------|--------------|
| `Fix:`, `Bug:`, `Hotfix:`, starts with "fix/patch/repair/debug" | `/refactor` |
| `QA:`, `Test:`, `Coverage:`, starts with "test/write tests" | `/qa` |
| Everything else | `/architect` |

**Flags:**
- `--qa` — second test layer: adversarial `/qa` pass after each architect/refactor success
- `--no-gemini` — passed through to all sub-skills

**Outputs:** Merged commits on base branch; failed branches preserved as `gm/*`; updated `tasks.md` checkboxes; summary table

**Design:** Tasks run sequentially — each successful merge updates the base so later tasks build on earlier work. Failed tasks don't block the rest of the list.

---

### `architect`

Multi-phase design-and-build pipeline for new features or significant architectural changes.

**Usage:** `/architect <task> [--no-gemini]`

**Phases:**
1. **Brainstorm (Haiku):** Generates 3 distinct architectural approaches → `docs/architecture_candidates.md`
2. **Gemini critique (optional):** Adversarial cross-model review → `docs/gemini_architectural_audit.md`
3. **Decide (Sonnet):** Evaluates candidates, selects one → `docs/approved_architecture.md`
4. **Implement:** Writes code per spec, runs test suite

**Outputs:** `docs/architecture_candidates.md`, `docs/approved_architecture.md`, `docs/decisions/<ts>_<slug>_architect.md`, optionally `docs/gemini_architectural_audit.md`

---

### `brainstorm`

Fast divergent thinking — produces exactly 3 distinct approaches with no executable code.

**Usage:** `/brainstorm [architect|refactor] <task>`

**Inputs:** `CLAUDE.md`, relevant source files, recent `docs/decisions/` logs (to avoid repeating failed approaches)

**Outputs:**
- `docs/architecture_candidates.md` (architect mode)
- `docs/refactor_candidates.md` (refactor mode)

Each option includes: summary, design decisions, trade-offs, risks. Reads decision history to avoid repeating failures.

---

### `decide`

Evaluates brainstormed candidates and writes a definitive implementation spec.

**Usage:** `/decide [architect|refactor] <task>`

**Inputs:**
- `docs/architecture_candidates.md` or `docs/refactor_candidates.md`
- `docs/gemini_architectural_audit.md` (if present)
- 3 most recent decision logs

**Outputs:**
- `docs/approved_architecture.md` (architect mode)
- `docs/approved_fix.md` (refactor mode)

Spec includes: rationale, files to change, key interfaces, ordered implementation steps, verification command. Makes one decisive choice — no hedging.

---

### `implement`

Executes an implementation spec (or a direct task) and verifies with the test suite.

**Usage:** `/implement [architect|refactor|<direct task>] [--plan-file <path>]`

**Behavior:**
- `architect` → reads `docs/approved_architecture.md`
- `refactor` → reads `docs/approved_fix.md`
- `--plan-file <path>` → reads custom spec
- Bare task description → standalone direct implementation

**Test runner detection order:** `./tests/run_tests.sh --unit` → `npm test` → `pytest` → `go test ./...` → `cargo test`

**Result:** Reports `✅ Implementation complete — all tests passing` or `❌ Tests failing after implementation`

---

### `qa`

Two-phase adversarial test generation to achieve comprehensive coverage.

**Usage:** `/qa <scope> [--no-gemini]`

**Phases:**
1. **Generate:** Writes comprehensive test suite, runs and fixes until all pass
2. **Gemini audit (optional):** Red-team review identifies coverage gaps → `tests/gemini_missing_coverage.md`
3. **Fill gaps:** Implements Gemini-identified test cases, passes full suite

**Outputs:** New/updated test files, `docs/decisions/<ts>_<slug>_qa.md`, optionally `tests/gemini_missing_coverage.md`

Gemini audit caps source payload at 500KB. Phase 3 proceeds even if audit fails.

---

### `refactor`

Three-phase bug fix and refactoring pipeline.

**Usage:** `/refactor <description> [--no-gemini]`

**Phases:**
1. **Diagnose (Haiku):** Captures `git diff > .current_state.diff`, proposes 3 solutions → `docs/refactor_candidates.md`
2. **Plan (Sonnet):** Selects approach → `docs/approved_fix.md`
3. **Implement:** Applies fix, runs tests; on failure (if Gemini enabled) → `GEMINI_ADVICE.md` as circuit-breaker

**Key difference from architect:** Gemini runs *after* Phase 3 failure (circuit-breaker), not between phases (critique).

**Outputs:** `docs/refactor_candidates.md`, `docs/approved_fix.md`, `docs/decisions/<ts>_<slug>_refactor.md`, optionally `GEMINI_ADVICE.md`

---

### `logging`

Audit trail management — timestamped decision logs in `docs/decisions/`.

**Usage:** `/logging [init|section|note|outcome|read] <pipeline> <args>`

| Action | Effect |
|--------|--------|
| `init <pipeline> <task> <model>` | Creates `docs/decisions/YYYYMMDD_HHMM_<slug>_<pipeline>.md`; prints path |
| `section <log-file> <title> [content-file]` | Appends titled section with optional file content |
| `note <log-file> <title> <text>` | Appends titled section with inline text |
| `outcome <log-file> <status> [notes]` | Finalizes log with `success` or `failed` |
| `read [pipeline]` | Shows recent logs, optionally filtered by pipeline type |

Slug: lowercase, non-alphanumeric → `-`, max 40 chars. Status transitions: `in-progress` → `success`/`failed`.

---

### `geminiapi`

Cross-model auditing via Gemini API, using `lib/launch-lib.sh` helper functions.

**Usage:** `/geminiapi [architect-critique|qa-audit|refactor-diagnosis|dispatch] <task>`

| Mode | Input | Output |
|------|-------|--------|
| `architect-critique` | `docs/architecture_candidates.md` | `docs/gemini_architectural_audit.md` |
| `qa-audit` | Source + test files (≤500KB) | `tests/gemini_missing_coverage.md` |
| `refactor-diagnosis` | `git diff` output | `GEMINI_ADVICE.md` |
| `dispatch` | Task description | stdout |

**Prerequisites:** `GEMINI_API_KEY` env var, `lib/launch-lib.sh` present. All failures are non-fatal (exit 0).

---

## Commands

Each skill has a thin entry-point command in `.claude/commands/`:

```
/gm          →  .claude/commands/gm.md
/architect   →  .claude/commands/architect.md
/brainstorm  →  .claude/commands/brainstorm.md
/decide      →  .claude/commands/decide.md
/implement   →  .claude/commands/implement.md
/qa          →  .claude/commands/qa.md
/refactor    →  .claude/commands/refactor.md
/logging     →  .claude/commands/logging.md
/geminiapi   →  .claude/commands/geminiapi.md
```

All follow the same pattern:

```yaml
---
description: <one-line description>
argument-hint: <expected args>
---
Use the /<skill> skill to complete this request: $ARGUMENTS
```

---

## Pipeline Flows

```
gm:         decompose → for each task: branch → [architect|refactor|qa] → [--qa layer] → merge|preserve
architect:  brainstorm → [gemini critique] → decide → implement → tests
qa:         implement (tests) → [gemini audit] → implement (gaps) → tests
refactor:   brainstorm (diagnose) → decide → implement → tests → [gemini on failure]
```

---

## Key Design Principles

- **Isolated phases:** Each phase runs in a fresh context (`context: fork`); coordination is via files in `docs/` and `tests/`.
- **Haiku vs Sonnet:** Brainstorm/diagnose uses Haiku (fast, divergent); decide/plan uses Sonnet (evaluative).
- **Non-fatal Gemini:** All Gemini calls fail gracefully — pipelines continue if the API is unavailable or returns an error.
- **Decision history:** `brainstorm` and `decide` read recent logs to avoid repeating approaches that failed before.
- **Spec-driven implement:** `implement` follows `approved_*.md` exactly; without a spec it accepts a direct task description.
