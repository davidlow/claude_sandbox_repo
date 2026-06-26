# Approved Plan: Fix Gemini API Key Not Injected into Docker Containers

**Date:** 2026-06-26
**Selected:** Option A — Direct Inline Injection

## Rationale

Option A is the correct choice for three reasons:

1. **Option C is structurally broken.** The brainstorm assumed `.env.local` lives in `$(pwd)` (the user's project directory, mounted at `/workspace`). It does not. Both launch scripts source `.env.local` from `$(dirname "${BASH_SOURCE[0]}")` — the claude-box repo directory, which is never mounted into the container. Sourcing `/workspace/.env.local` inside `entrypoint.sh` would read a different file (or nothing), not the one that contains the key.

2. **Option B is over-engineered.** A helper function to build docker env flags adds complexity (bash array-from-function expansion is error-prone), introduces parsing/quoting edge cases, and solves a problem that doesn't yet exist. There is exactly one env var to inject. When a second one is needed, a helper can be introduced then.

3. **Option A follows the existing pattern exactly.** The launch scripts already inject `CLAUDE_CODE_OAUTH_TOKEN` and `CLAUDE_CODE_OAUTH_REFRESH_TOKEN` via `-e` flags in the docker run arrays. Adding `GEMINI_API_KEY` the same way is idiomatic, predictable, and testable. The variable is already in scope because `.env.local` is sourced at the top of each script.

## Changes Required

### Files to modify

- `launch-scripted.sh` — Add `-e GEMINI_API_KEY="${GEMINI_API_KEY:-}"` to both `DOCKER_RUN_BASE` and `DOCKER_RECOVERY_BASE` arrays, after the existing OAuth token lines.
- `launch-interactive.sh` — Add `-e GEMINI_API_KEY="${GEMINI_API_KEY:-}"` to the single `docker run` call, after the existing OAuth token lines.

### Files to create (if any)

None.

### Files to delete (if any)

None.

## Key Interfaces / Data Structures

No new interfaces. The existing pattern is:
```
-e ENVVAR_NAME="$ENVVAR_NAME"
```
Use `"${GEMINI_API_KEY:-}"` (not `"$GEMINI_API_KEY"`) to remain safe when `set -u` is active and the variable is unset. The skills already guard against an empty value by checking `${GEMINI_API_KEY:+set}` before making API calls, so passing an empty string is safe.

## Implementation Steps

1. **Edit `launch-scripted.sh` — DOCKER_RUN_BASE array** — Locate the `DOCKER_RUN_BASE=(...)` block (lines ~130–142). After the line `-e CLAUDE_CODE_OAUTH_REFRESH_TOKEN="$OAUTH_REFRESH"`, add a new line: `-e GEMINI_API_KEY="${GEMINI_API_KEY:-}"`. Place it before the `claude-sandbox` image name line.

2. **Edit `launch-scripted.sh` — DOCKER_RECOVERY_BASE array** — Locate the `DOCKER_RECOVERY_BASE=(...)` block (lines ~147–159). After the line `-e CLAUDE_CODE_OAUTH_REFRESH_TOKEN="$OAUTH_REFRESH"`, add the same line: `-e GEMINI_API_KEY="${GEMINI_API_KEY:-}"`. Place it before the `claude-sandbox` image name line. Keep the two arrays in sync — they should carry identical env vars.

3. **Edit `launch-interactive.sh` — docker run call** — Locate the `docker run -it --rm ...` block (lines ~70–77). After the line `-e CLAUDE_CODE_OAUTH_REFRESH_TOKEN="$OAUTH_REFRESH"`, add: `-e GEMINI_API_KEY="${GEMINI_API_KEY:-}"`. The docker run call in this file is not stored in an array; it is written directly.

## Verification

1. Run the unit tests to confirm no regressions:
   ```
   ./tests/run_tests.sh --unit
   ```

2. Verify the key appears in the docker run commands by inspecting with `grep`:
   ```
   grep -n "GEMINI_API_KEY" launch-scripted.sh launch-interactive.sh
   ```
   Expected: three matches — one in DOCKER_RUN_BASE, one in DOCKER_RECOVERY_BASE, one in the interactive docker run call.

3. Manual smoke test (requires Docker + valid credentials + GEMINI_API_KEY in `.env.local`): run `claude-box` and execute `/geminiapi dispatch "say hello"` inside the session. The call should succeed rather than printing "GEMINI_API_KEY not set — skipping Gemini call".
