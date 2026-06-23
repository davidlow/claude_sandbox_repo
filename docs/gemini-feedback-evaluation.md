# Gemini Feedback Evaluation

**Date:** 2026-06-22  
**Source:** Gemini architectural review of `.claude/skills/` and `.claude/settings.json`

---

## Concern 1: `context: fork` Frontmatter Ignored

**Gemini's claim:** `context: fork` in skill frontmatter is silently ignored by the Claude Code runtime; skills spill into the main conversation context instead of forking a subagent.

**Assessment: INCORRECT — no change needed.**

Looking at the actual skill files, `context: fork` IS present and IS a supported Claude Code feature:

- `brainstorm/SKILL.md`: `context: fork`, `model: haiku`
- `decide/SKILL.md`: `context: fork`
- `implement/SKILL.md`: `context: fork`
- `geminiapi/SKILL.md`: `context: fork`

The orchestrators (`architect`, `refactor`, `qa`) intentionally do NOT have `context: fork` — they run inline to coordinate phases. The worker skills all fork correctly. Gemini may have been describing an older runtime version or a different tool invocation path. The system as designed is correct.

---

## Concern 2: Missing Context-Capping Safeguards in `qa`/`geminiapi`

**Gemini's claim:** The payload aggregation step may pull in binary artifacts, `.next/`, `target/`, or `venv/` directories before hitting the 500KB guard.

**Assessment: PARTIALLY VALID — small fix implemented.**

The `geminiapi` qa-audit already excludes `node_modules`, `.git`, `dist`, `build`, `vendor`, `.venv`, and `__pycache__`. However, several common dependency directories are missing:

| Directory | Language/Tool | Missing? |
|-----------|--------------|----------|
| `venv/` | Python (without dot prefix) | ✅ was missing |
| `target/` | Rust `cargo build` | ✅ was missing |
| `.next/` | Next.js build cache | ✅ was missing |
| `coverage/` | Test coverage reports | ✅ was missing |
| `.pytest_cache/` | pytest runtime cache | ✅ was missing |

**Fix applied:** Added these five exclusions to the `find` command in `geminiapi/SKILL.md` qa-audit mode.

---

## Concern 3: Bash Permissions `source` Builtin Lockout

**Gemini's claim:** `source` is a shell builtin, not an executable binary path, so `Bash(source /workspace/lib/launch-lib.sh*)` in `settings.json` will be rejected by the permission engine.

**Assessment: INCORRECT — no change needed.**

Claude Code's permission engine pattern-matches against the **full bash command string**, not against a resolved binary path. The entry `Bash(source /workspace/lib/launch-lib.sh*)` correctly matches any bash invocation starting with that string. The system is already deployed and working — if this were broken, all Gemini-related functionality would fail. No change needed.

---

## Concern 4: Git Atomic Staging Collision

**Gemini's claim:** Partial file changes in Phase 1 or Phase 2 pollute the `git diff` gathered by later phases.

**Assessment: MITIGATED BY DESIGN — no change needed.**

Tracing the refactor pipeline:

1. `git diff > .current_state.diff` — captured **before** any skill is invoked
2. `/brainstorm` — writes only to `docs/refactor_candidates.md` (no source file changes, by spec)
3. `/decide` — writes only to `docs/approved_fix.md` (no source file changes, by spec)
4. `/implement` — modifies source files, runs tests
5. `/geminiapi refactor-diagnosis` — intentionally shows the post-implement `git diff HEAD` so Gemini can diagnose why tests fail

The baseline is safely captured before brainstorm. The Gemini diagnosis intentionally captures all changes including what implement did. Adding `git stash` would risk discarding legitimate uncommitted user work and adds fragility. No change needed.

---

## Concern 5: Logging Read Before Brainstorm

**Gemini's claim:** `brainstorm` should query `/logging read` before proposing approaches to avoid repeating failed designs.

**Assessment: ALREADY IMPLEMENTED — no change needed.**

From `brainstorm/SKILL.md`, Step 2:
> "Run `ls docs/decisions/ 2>/dev/null` and read the 3 most recent decision logs if any exist — check what approaches have already been tried and failed."

This is already in place. Gemini did not see this part of the implementation.

---

## Summary

| Concern | Valid? | Action |
|---------|--------|--------|
| `context: fork` ignored | No | Skip |
| Payload exclusion gaps | Partially | **Fixed** — added 5 exclusions |
| `source` builtin lockout | No | Skip |
| Git staging collision | No (mitigated) | Skip |
| Logging before brainstorm | Already done | Skip |
