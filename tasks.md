# Repository Optimization and Feature Enhancement Tasks

## Phase 1: Code Refactoring and Consolidation
> **Objective:** Identify redundancies across the core bash engine, simplify the execution flow, ensure full behavioral regression testing, and commit the clean baseline.

- [ ] **Audit Core Scripts for Shared Redundancies**
  - Analyze `launch-scripted.sh`, `launch-architect.sh`, `launch-qa.sh`, `launch-refactor.sh`, and `launch-dispatch.sh`.
  - Extract duplicate blocks of code (e.g., Docker run arguments, path sanitization, ANSI stripping, credential checking) and move them into reusable functions within `lib/launch-lib.sh`.
- [ ] **Verify Functional Integrity via Test Suite**
  - Run `./tests/run_tests.sh --unit` to verify no existing baseline logic was broken during consolidation.
- [ ] **Commit Consolidated Refactor Baseline**
  - Stage the modifications and create a clean, atomic commit outlining the refactoring changes before beginning feature development.

---

## Phase 2: Feature Implementation
> **Objective:** Implement architectural enhancements to increase mechanical durability, security, and financial observability across the pipelines.

- [ ] **Implement Automated Blast-Radius Protection (Auto-Stash)**
  - Inject a Git state-check directly into `lib/launch-lib.sh`.
  - Before spinning up autonomous pipelines like `claude-yolo` or `claude-refactor`, check `git status`.
  - If the working tree is dirty, automatically run `git stash save "Pre-Claude autonomous run"` or create a temporary branch. This ensures that destructive autonomous hallucinations can be instantly rolled back.

- [ ] **Implement Network Isolation Mode for Testing**
  - Add a `--secure-run` flag to the script arguments.
  - When passed, append `--network none` to the `docker run` execution array.
  - This guarantees the container is physically cut off from the internet during the Execution or QA testing phases, preventing it from making live outbound API calls or polluting the environment with unverified packages.

- [ ] **Implement Gemini-Powered Handoff Validation**
  - In the Strategy B+C recovery phase, intercept the generated `.task_handoff.md` file before the script wipes the container context.
  - Send the file to the **Gemini 2.5 Flash-Lite** API (optimized for high-speed, low-cost basic validation).
  - Prompt Gemini to respond with a strict `PASS` or `FAIL` based on whether the handoff document is coherent, logical, and actually contains usable steps.
  - If `FAIL`, discard the handoff file completely to prevent context poisoning, and start the next Claude retry with a clean slate.

- [ ] **Build Local Telemetry and Cost Ledger**
  - Establish a host-mounted ledger file (e.g., `~/.claude_telemetry.csv`).
  - Update the wrapper scripts to parse both `claude.log` (for Claude token usage) and the Gemini API JSON responses (for Gemini token usage) at the end of every run.
  - Calculate the estimated financial cost for both models based on their respective pricing tiers. *(Note: While Claude runs via OAuth subscription, calculate the equivalent API cost so the architectural expense is documented).*
  - Append a record for each run: `Timestamp, Pipeline, Model, Claude_Tokens, Claude_Equivalent_Cost, Gemini_Tokens, Gemini_Cost, Exit_Code`.
