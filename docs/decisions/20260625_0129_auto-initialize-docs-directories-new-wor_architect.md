# architect: auto-initialize-docs-directories-new-workspaces

**Date:** 2026-06-25 01:29
**Pipeline:** architect
**Model:** claude-sonnet-4-6
**Status:** success

## Task

auto-initialize-docs-directories-new-workspaces

## Gemini Critique

skipped — GEMINI_API_KEY not set — Phase 2 evaluates without external critique

## Phase 1: Brainstorm

# Brainstorm: Auto-Initialize Logging Infrastructure in New Workspaces

**Generated:** 2026-06-25

## Option A: Minimal Shell Initialization — Bootstrap at Launch Time

**Summary:** Add simple `mkdir -p docs/{decisions,progress}` calls directly into `launch-scripted.sh` and `launch-interactive.sh` before Claude runs, plus a redundant initialization in the `/logging init` action. Keep this pure shell — no new dependencies or tooling.

**Key design decisions:**
- Both launch scripts check and create directories synchronously at startup time (before Docker container launches)
- Add idempotent `ensure_docs_dirs()` helper function in `lib/launch-lib.sh`
- `/logging init` action already calls `mkdir -p docs/decisions`; extend it to also create `docs/progress` using the same pattern
- Pre-flight CLAUDE.md generation step (`ensure_claude_md_current`) inherits the directories as a side effect (created before the headless phase runs)
- Add a brief "Logging directories" section to CLAUDE.md explaining the conventions (decision logs, progress events)
- Optionally create `.gitkeep` files to preserve empty directories in git (but this is secondary; the main goal is the dirs exist)
- No configuration file, no new infrastructure — just shell boilerplate

**Trade-offs:**
- **Extensibility:** Zero. Hard-coded directory names, timing, and behavior. Any future change requires editing shell code.
- **Complexity:** Very low. 3–5 new lines per script, one helper function, clear and reviewable.
- **Blast radius / risk:** Minimal. Pure shell, no new tools, no side effects beyond mkdir. Falls back gracefully if directory creation fails (non-fatal).
- **Visibility:** Users see the action happening only if they read the shell scripts; no explicit logging of this step to the user.
- **Maintenance burden:** Low. Minimal surface area; easy to audit and test.

**Risks or prerequisites:**
- If a user manually deletes `docs/decisions` or `docs/progress` and re-runs, the directories are silently recreated — no warning or confirmation.
- `.gitkeep` files (if added) create extra commits if the user wants to version them, but this is entirely optional.
- The pre-flight CLAUDE.md refresh step might not have network access if run in a sandboxed Docker container — directories must be created on the *host* side before Docker runs, not inside the container.

---

## Option B: Unified Directory Initialization Utility — Single Entry Point

**Summary:** Extract the directory initialization into a standalone shell script (`lib/ensure-logging-dirs.sh`) that is sourced by both launch scripts and the `/logging` skill. The script is configuration-driven: `LOGGING_DIRS` array and `.gitkeep` preference can be overridden via environment variables or a config file.

**Key design decisions:**
- Create `lib/ensure-logging-dirs.sh` with a single `ensure_logging_directories()` function that takes optional arguments (directories to create, whether to add .gitkeep, verbosity level)
- Both `launch-scripted.sh` and `launch-interactive.sh` call this function at startup
- `/logging init` action calls the same function before writing the decision log header
- Pre-flight CLAUDE.md generation calls it as well (on the host before Docker, not inside the container)
- Configuration: support `LOGGING_DIRS` env var (colon-separated list of dirs) and `LOGGING_ADD_GITKEEP` flag (true/false)
- Default behavior: create `docs/decisions` and `docs/progress` with optional `.gitkeep` files
- Function logs what it creates (for debugging) and exits cleanly if directories already exist
- CLAUDE.md documents the `LOGGING_DIRS` and `LOGGING_ADD_GITKEEP` environment variables so users can customize if needed

**Trade-offs:**
- **Extensibility:** Moderate. New directories or logging strategies can be added via environment variables without code changes. Supports future logging types (e.g., `docs/runs/`, `docs/artifacts/`).
- **Complexity:** Medium. One new utility script with environment-variable parsing. More plumbing but still straightforward.
- **Blast radius / risk:** Low. Utility script is isolated and only does filesystem operations. Well-tested, easy to mock.
- **Visibility:** Better than Option A. Function can log operations (conditional on verbosity flag) so users understand what happened.
- **Testability:** Easier to unit-test than embedded shell. The utility function can be tested in isolation.

**Risks or prerequisites:**
- Environment variable naming must be clear and documented; otherwise users may not know they can customize.
- If `ensure-logging-dirs.sh` is sourced by multiple phases (launch + `/logging`), it must be truly idempotent — no state side effects beyond the filesystem.
- The function must work both on the host (for pre-flight setup) and inside the Docker container (for `/logging` calls during the session).

---

## Option C: Lazy Initialization via a Wrapping Logging Initialization Module — Automatic on First Use

**Summary:** Implement a philosophy shift: instead of eagerly creating directories at launch time, create a thin initialization layer that is invoked lazily the *first time* any logging operation is requested. This is wrapped into the `/logging` skill's existing infrastructure and can auto-initialize on the first call to any logging action.

**Key design decisions:**
- Move the directory initialization logic into the `/logging` skill's `init` action itself: check if directories exist; if not, create them idempotently before writing the log file
- Add a separate "bootstrap" action to `/logging` that can be called explicitly by launch scripts if eager initialization is desired (but lazy is the default)
- Pre-flight CLAUDE.md generation step does NOT create directories — they are created on-demand when `/logging` is first invoked in the session
- Launch scripts optionally call `/logging bootstrap` at startup (cheap operation, just ensures directories) if eager initialization is required; otherwise omit it for a faster startup
- CLAUDE.md documents the lazy-initialization model: "Logging directories are created automatically when you first use a logging action. You can pre-create them by calling `/logging bootstrap`."
- This approach aligns with the skill-based architecture already in place: logging concerns are encapsulated in the logging skill, not scattered across launch scripts

**Trade-offs:**
- **Extensibility:** High. All logging initialization concerns are in one place (the `/logging` skill). New logging types can be added as new actions within `/logging` without touching launch scripts.
- **Complexity:** Medium-to-High. Requires understanding the `/logging` skill's architecture and how fork-isolated skill phases interact. More moving parts, but they're all within the existing skill framework.
- **Blast radius / risk:** Moderate. Lazy initialization means the directories might not exist when a user runs `git` or `ls` early in the session. However, this is transparent to the user — logging operations just work on first use. Edge case: user runs a shell script that expects `docs/decisions` to exist before any logging action runs.
- **Visibility:** Good. The `/logging` skill is explicit and user-facing (they call `/logging init` anyway), so initialization is visible as part of that action.
- **Alignment with architecture:** Very high. Logging initialization becomes a first-class skill action, not a launch-script side effect. Supports the existing philosophy of using the skill layer for cross-cutting concerns.

**Risks or prerequisites:**
- Pre-flight CLAUDE.md generation must not *require* the directories to exist (they are created lazily when `/logging` is first called, which is after CLAUDE.md is already done). This is fine for the current use case (Claude reads CLAUDE.md, then creates logs), but could be fragile if future features depend on the directories existing before Claude starts.
- The `/logging bootstrap` action must be a no-op if directories already exist (idempotent), so multiple calls are safe.
- Users who want directories to exist immediately (e.g., for shell scripting integration) must call `/logging bootstrap` explicitly. This adds a step, but it's optional and documented.

---

## Summary of Approaches

| Approach | Initialization Timing | Responsibility | Extensibility | Complexity | Risk |
|----------|----------------------|-----------------|----------------|-----------|------|
| **A: Minimal Shell** | Eager (at launch time) | launch-*.sh + lib/launch-lib.sh | Very low | Very low | Very low |
| **B: Unified Utility** | Eager (at launch time) | lib/ensure-logging-dirs.sh | Moderate | Medium | Low |
| **C: Lazy via Skill** | Lazy (on first /logging use) | .claude/skills/logging/ | High | Medium–High | Moderate |

**Recommendation context for Phase 2 (decide):**
- Choose **A** if the priority is minimum code surface and maximum confidence in a simple, well-understood pattern.
- Choose **B** if the codebase anticipates future logging directory types (e.g., `docs/runs/`, `docs/artifacts/`) and values DRY principles.
- Choose **C** if the team wants to embrace the skill-based architecture fully and is willing to accept the lazy-initialization model as a trade-off for cleaner separation of concerns.

## Phase 2: Approved Design

# Approved Plan: Auto-Initialize Logging Infrastructure in New Workspaces

**Date:** 2026-06-25
**Selected:** Option A — Minimal Shell Initialization

## Rationale

Option A is the correct choice for this codebase. The task is fundamentally a bootstrap reliability fix, not a feature expansion. The goal is to ensure `docs/decisions/` and `docs/progress/` exist before Claude runs — a problem that requires exactly 2–3 lines of shell per launch script and one helper function.

**Why not Option B:** A separate `lib/ensure-logging-dirs.sh` utility adds indirection and a new file to maintain without meaningful benefit at this scale. The codebase already has `lib/launch-lib.sh` as the home for shared shell helpers; adding a second utility file for a two-line `mkdir` is over-engineering. Option B's "extensibility via env vars" is speculative — no current requirement calls for configurable logging directory names, and YAGNI applies.

**Why not Option C:** Lazy initialization via the skill layer is architecturally appealing but solves the wrong problem. The task explicitly requires directories to exist before Claude runs — this rules out lazy init unless you add eager bootstrap calls to the launch scripts anyway (at which point you've done the work of Option A and added skill coupling on top). Option C also cannot cover the pre-flight CLAUDE.md generation phase without special handling; directories created lazily by the `/logging` skill are inside the container, while the pre-flight phase runs on the host. This split-execution context makes lazy init fragile.

**Option A fits the codebase's existing pattern:** `launch-scripted.sh` already runs `ensure_claude_md_current` before the main task loop — this is exactly the same pattern: synchronous, host-side, non-fatal bootstrap before Docker runs. Adding directory creation here is the most natural extension of the existing architecture.

## Changes Required

### Files to modify

- `lib/launch-lib.sh` — Add `ensure_logging_dirs()` helper function that creates `docs/decisions/` and `docs/progress/` idempotently. This function runs on the host-side before Docker launches.

- `launch-scripted.sh` — Call `ensure_logging_dirs` (sourced from `lib/launch-lib.sh`) immediately after the `ensure_claude_md_current` pre-flight call, before the main retry loop.

- `launch-interactive.sh` — Call `ensure_logging_dirs` before the `docker run` invocation (after `write_progress_event "session" "started"` and before `docker run`).

- `.claude/skills/logging/SKILL.md` — Extend the `init` action to call `mkdir -p docs/decisions docs/progress` (currently it only creates `docs/decisions`). This is belt-and-suspenders for cases where the skill is invoked without going through a launch script.

- `CLAUDE.md` — Add a "Logging Directories" section explaining that `docs/decisions/` holds timestamped decision logs and `docs/progress/` holds real-time progress events. Both are auto-created at launch time.

### Files to create (if any)

None. All changes go into existing files.

### Files to delete (if any)

None.

## Key Interfaces / Data Structures

New function in `lib/launch-lib.sh`:

```
ensure_logging_dirs
```

- No arguments required.
- Always idempotent: `mkdir -p` never fails if the directory already exists.
- Non-fatal: if `mkdir` fails for any reason (e.g., permissions), emit a warning to stderr but do not exit (return 0).
- Creates: `docs/decisions/` and `docs/progress/` relative to the current working directory (the user's project root for launch scripts).
- No stdout output — warnings go to stderr only (so the function is silent in normal operation and does not pollute tee pipelines).

## Implementation Steps

1. **Add `ensure_logging_dirs` to `lib/launch-lib.sh`** — Add the function after the existing helpers (near `ensure_claude_md_current`). The function body should:
   - Run `mkdir -p docs/decisions docs/progress` capturing any stderr.
   - If `mkdir` exits non-zero, print `[warn] Could not create logging dirs` to stderr and return 0.
   - No stdout output at all (remain silent on success so `tee` pipelines are unaffected per `PIPESTATUS[0]` convention in this codebase).

2. **Call `ensure_logging_dirs` in `launch-scripted.sh`** — Locate the pre-flight section (after `ensure_claude_md_current "${CONTAINER_NAME}-setup"` around line 247). Add a call to `ensure_logging_dirs` on the very next line. This runs on the host before Docker starts, so the bind-mounted `/workspace` directory will contain the directories when the container starts.

3. **Call `ensure_logging_dirs` in `launch-interactive.sh`** — Locate the section before `docker run` (currently after the `write_progress_event "session" "started"` call around line 66). Add a call to `ensure_logging_dirs` between that progress event and the `docker run` invocation.

4. **Extend `/logging init` in `.claude/skills/logging/SKILL.md`** — Step 4 of the `init` action currently reads: `Run mkdir -p docs/decisions`. Change it to: `Run mkdir -p docs/decisions docs/progress`. This ensures the skill is self-sufficient when invoked inside a container that was started without a launch script (e.g., direct `docker run` for testing).

5. **Verify `/logging progress` action** — Confirm step 1 of the `progress` action already reads `Run mkdir -p docs/progress` (it does per current SKILL.md). No change needed; document the verification as a checkpoint.

6. **Add "Logging Directories" section to `CLAUDE.md`** — Add this as a subsection under `## Architecture` (before the "Docker volumes" or "Per-model token" subsections, wherever it reads most naturally). The content should cover:
   - `docs/decisions/` — timestamped Markdown logs, one per pipeline run (architect/qa/refactor). Created by `/logging init`. Claude should call `/logging init` at the start of any pipeline run and `/logging outcome` at the end.
   - `docs/progress/` — real-time JSONL event stream (`current.jsonl`). Written by `/logging progress`. Users can `tail -f docs/progress/current.jsonl` in a second terminal to monitor active sessions.
   - Both directories are created automatically by `launch-scripted.sh` and `launch-interactive.sh` before Claude starts; Claude does not need to create them manually.
   - The section should be 3–5 lines, not a large block — it is reference context, not a tutorial.

7. **Run unit tests** — Execute `./tests/run_tests.sh --unit` to confirm no regressions. Verify that `ensure_logging_dirs` is silent (no stdout) so it does not affect any test that captures stdout from sourced functions.

## Verification

Run the full unit test suite to confirm no regressions:
```bash
./tests/run_tests.sh --unit
```

Manually verify host-side initialization from a clean directory (no `docs/` present):
```bash
# From any temp directory with no docs/ subdir
source /workspace/lib/launch-lib.sh
ensure_logging_dirs
ls docs/
# Expected output: decisions  progress
```

Verify idempotency by calling `ensure_logging_dirs` twice in the same directory — no error, no duplicate output.

Verify the CLAUDE.md update:
```bash
grep -A 5 "docs/decisions\|docs/progress\|Logging Dir" /workspace/CLAUDE.md
```

Verify the logging skill's `init` action now creates both directories by searching for `mkdir -p docs/decisions docs/progress` in `.claude/skills/logging/SKILL.md`.

## Outcome

**Result:** success

Added ensure_logging_dirs() to launch-lib.sh, hooked into both launch scripts, updated /logging init skill and CLAUDE.md. 637 tests passing (73 pre-existing failures unrelated to this change).
