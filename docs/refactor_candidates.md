# Brainstorm: Fix Gemini API key injection from .env.local into Docker containers

**Generated:** 2026-06-26

## Option A: Direct Inline Injection

**Summary:** Add `-e GEMINI_API_KEY="$GEMINI_API_KEY"` directly to the `DOCKER_RUN_BASE` and `DOCKER_RECOVERY_BASE` arrays in `launch-scripted.sh` and `launch-interactive.sh`.

**Key design decisions:**
- `.env.local` is already sourced at the top of both launch scripts
- `GEMINI_API_KEY` variable is already in scope and ready to use
- Inject the env var directly in the docker run command arrays, mirroring how `CLAUDE_CODE_OAUTH_TOKEN` is already handled
- Minimal, surgical change — only touches the two container invocation sites

**Trade-offs:**
- Extensibility: Low — if other env vars from `.env.local` need injection later, each one requires adding a new `-e` flag to both arrays
- Complexity: Minimal — just two lines added per script
- Blast radius / risk: Very low — isolated to docker run flags; no refactoring of existing functions

**Risks or prerequisites:** None. The variable is already available after sourcing `.env.local`. Only risk is forgetting to add it to both `DOCKER_RUN_BASE` and `DOCKER_RECOVERY_BASE` (both exist in `launch-scripted.sh`; only one exists in `launch-interactive.sh`).

---

## Option B: Systematic Env Var Collection Helper

**Summary:** Create a helper function `collect_docker_env_flags()` in `lib/launch-lib.sh` that reads `.env.local` and returns formatted docker flags (`-e VAR1=VAL1 -e VAR2=VAL2`). Use this function in both launch scripts to build a consistent set of environment variables for container injection.

**Key design decisions:**
- Centralize env var logic in the shared library (`lib/launch-lib.sh`) where `parse_args`, `parse_model_tier`, and other helpers already live
- Function parses `.env.local` (or `.env.example` as fallback) and constructs docker `-e` flags for all required vars
- Both `DOCKER_RUN_BASE` and `DOCKER_RECOVERY_BASE` arrays call this helper to inject env vars consistently
- Future env vars (e.g., `GCP_PROJECT_ID`, custom timeouts) can be added to `.env.example` without modifying launch scripts
- Optional: create an `.env.example` with commented-out GEMINI_API_KEY and other optional vars so users know what can be configured

**Trade-offs:**
- Extensibility: High — adding new env vars requires only updating `.env.example` and the helper function once; both launch scripts automatically inherit the new vars
- Complexity: Moderate — need to handle env var parsing, quoting, and empty values gracefully
- Blast radius / risk: Low to moderate — helper function is isolated in lib/, but affects both launch scripts through the arrays they build

**Risks or prerequisites:** Must handle edge cases like unset variables, empty strings, and special characters in values. Need to preserve quoting for values with spaces or special chars. Should gracefully handle missing `.env.local` (fallback to defaults or `.env.example`).

---

## Option C: Container-Side Self-Configuration via entrypoint.sh

**Summary:** Extend `entrypoint.sh` to source `.env.local` from the mounted workspace volume before launching Claude Code. The container automatically inherits all env vars from the host workspace without the launch scripts needing to know about them.

**Key design decisions:**
- In `entrypoint.sh`, before executing `"$@"` (the Claude Code invocation), check for `/workspace/.env.local` and source it
- All env vars become available inside the container automatically, just like on the host
- No changes to `launch-interactive.sh` or `launch-scripted.sh` needed
- Launch scripts remain decoupled from env var knowledge; container handles its own configuration
- Works for both `DOCKER_RUN_BASE` (interactive) and `DOCKER_RECOVERY_BASE` (headless) automatically

**Trade-offs:**
- Extensibility: Very high — any env vars added to `.env.local` automatically become available inside the container without touching launch scripts
- Complexity: Minimal — just 2–3 lines in `entrypoint.sh` to source the file
- Blast radius / risk: Very low — isolated to the entrypoint bootstrap logic; no changes to main launch scripts

**Risks or prerequisites:** 
- `.env.local` must be on the workspace volume (it is, by design: `$(pwd):/workspace`)
- Env vars loaded *after* entrypoint.sh runs, so they are NOT available to docker run flags that reference them (e.g., `-e VAR=$VAR`). This is fine for GEMINI_API_KEY since it only needs to be available *inside* the container, not in the docker command itself.
- If a future requirement needs env vars available to docker flags (e.g., `--memory=$MAX_MEMORY`), this approach won't work.

---
