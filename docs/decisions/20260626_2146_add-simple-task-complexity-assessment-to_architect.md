# architect: Add simple-task complexity assessment to /gm skill

**Date:** 2026-06-26 21:46
**Pipeline:** architect
**Model:** claude-sonnet-4-6
**Status:** success

## Task

Add simple-task complexity assessment to /gm skill

## Phase 1: Brainstorm

# Brainstorm: Simple-Task Complexity Assessment for /gm

**Generated:** 2026-06-26

## Option A: Heuristic Rules Pre-Check

**Summary:** Add a lightweight inline function in /gm that applies deterministic heuristics to task text to identify obviously simple tasks; if simple, set an environment flag that tells /implement to skip brainstorm/decide phases.

**Key design decisions:**
- Heuristics include: task description length (<80 words), no ambiguous language ("might", "could", "explore"), references only to existing files/modules, matches predefined patterns (e.g., "add logging to X function", "rename Y variable")
- Complexity check runs synchronously in /gm Step 4a, before branch creation
- On "simple" detection, export `GM_SKIP_BRAINSTORM=true` and `GM_TASK_COMPLEXITY=simple` to sub-skill environment
- /implement skill checks these flags and skips `/brainstorm` and `/decide` when both are set, jumping straight to inline reasoning + code writing
- Pipeline Steps table shows all phases but marks brainstorm/decide rows with "(skipped — simple task)" notation
- overview.md notes complexity assessment result in a dedicated section

**Trade-offs:**
- Extensibility: Good (heuristics can be tuned over time; new patterns added easily). Can grow complex if rules proliferate.
- Complexity: Low (minimal code change to /gm; /implement already knows about task complexity implicitly)
- Blast radius / risk: Very low (purely advisory; if heuristics fail, worst case is brainstorm runs when not needed; no correctness impact)

**Risks or prerequisites:**
- False positives (mark a complex task as simple) could produce shallow implementations. Needs validation.
- Heuristics are brittle across different task domains (code refactoring vs. feature design vs. doc writing).
- No explicit audit trail: users don't see the reasoning behind the complexity assessment.

---

## Option B: Structured Assessment Skill with Explanation

**Summary:** Create a dedicated `/assess` skill that invokes Claude to evaluate task complexity with structured reasoning and returns a decision. /gm calls `/assess` as a pre-step, and if the result is "simple", passes that decision to sub-skills via environment and task-context flags.

**Key design decisions:**
- New skill `/assess <task-text> [--criteria <domain>]` returns a JSON structure: `{ complexity: "simple|moderate|complex", reasoning: "...", estimated_phases: ["implement"], confidence: 0.X }`
- /gm parses the response and, on "simple" verdict, exports `GM_COMPLEXITY_ASSESSMENT=simple` + the reasoning to STDOUT and to the overview.md
- Sub-skills (/architect, /refactor, /qa) accept an optional `--complexity` parameter that reads the assessment from the environment or a passed file
- If `--complexity simple`, skip the brainstorm/decide phases and document the skip with the assessment reasoning in the Pipeline Steps table
- QA layer always runs if `--qa` was given (not affected by complexity assessment)
- overview.md shows a "Complexity Assessment" section before Pipeline Steps, with the full reasoning from /assess

**Trade-offs:**
- Extensibility: Excellent (assessment skill can be enhanced with domain-specific criteria; reusable across other tools)
- Complexity: Moderate (new skill, new parameter flow to multiple sub-skills, parsing and passing structured data)
- Blast radius / risk: Medium (if /assess fails or times out, /gm may stall; requires error handling and fallback logic)

**Risks or prerequisites:**
- /assess requires an LLM call, adding latency and potential rate-limiting.
- Needs clear error handling if /assess fails: should /gm proceed or abort?
- Assessment reasoning must be clear and auditable; unclear explanations defeat the purpose.
- Coordination between /gm and all sub-skills to handle the complexity flag.

---

## Option C: Unified Phase Control System

**Summary:** Refactor /architect, /refactor, /qa to each accept a `--skip-phases <phase1,phase2>` parameter. /gm analyzes task complexity with inline heuristics (simpler than Option A) and invokes skills with an explicit phase-skip list. All skills produce the same wiki output but with skipped phases marked as "N/A" in the Pipeline Steps table.

**Key design decisions:**
- Heuristic assessment in /gm is minimal: check word count, term presence, and existing-module references; return a set of phases to skip (e.g., `["brainstorm", "decide"]`)
- /gm passes `--skip-phases brainstorm,decide` to `/architect <task>` when complexity is simple
- Each skill (architect, refactor, qa) accepts and honors the `--skip-phases` parameter: if a phase is in the list, skip it, document as "N/A — skipped", and proceed to the next executable phase
- Pipeline Steps table shows all defined phases for the skill type, with skipped phases marked `N/A (skipped: simple task)` and a link to the assessment details
- overview.md includes a "Complexity Assessment" section with the heuristic criteria applied and the phase-skip decision
- Phase skip list is passed through to QA layer (if invoked), so QA respects the same skip decisions

**Trade-offs:**
- Extensibility: Very good (phase skip system is generic and reusable; can be extended to other pipeline skills in the future)
- Complexity: Moderate (requires updating 3 skill definitions to accept and honor `--skip-phases`; heuristic logic in /gm is simpler than Option A)
- Blast radius / risk: Low (skipped phases are explicit and clearly marked; users can see exactly what was skipped and why)

**Risks or prerequisites:**
- Requires coordination across multiple skill files (/architect, /refactor, /qa SKILL.md definitions).
- Phase ordering becomes important: if brainstorm is skipped but decide runs, is that valid? Need clear rules about phase dependencies.
- QA layer must understand that it's operating on code already skipped some phases; may need conditional test generation.
- Initial setup requires updating all skill signatures; ongoing maintenance to keep phase definitions consistent.


## Gemini Critique

completed — docs/gemini_architectural_audit.md

## Phase 2: Approved Design

# Approved Plan: Simple-Task Complexity Assessment for /gm

**Date:** 2026-06-26
**Selected:** Option A — Heuristic Rules Pre-Check (refined)

## Rationale

Option A is selected, with one critical refinement: the "heuristics" are not regex patterns or word-count thresholds but instead Claude's natural-language reasoning guided by explicit criteria. This eliminates Gemini's primary complaint about brittle string matching — Claude's judgment on task complexity is far more context-aware than any regex approach.

The implementation is simpler than Gemini's critique assumed because `/gm` does not need to plumb env vars into `/architect`. For a "simple" task, `/gm` bypasses `/architect` entirely and calls `/implement <task>` directly. The `/implement` skill already supports standalone mode with a direct task description — no spec file required. This avoids the "missing artifacts" state desynchronization concern: `/implement` in standalone mode never expects `docs/approved_architecture.md` to exist.

**Why not Option B:** An LLM-assessment skill (`/assess`) adds another serial LLM call before every `/gm` task begins. This doubles rate-limit exposure and adds latency for what is ultimately a judgment call Claude can make inline. JSON parsing in a bash/skill environment is fragile as Gemini correctly noted.

**Why not Option C:** Distributing `--skip-phases` across `/architect`, `/refactor`, and `/qa` skill files multiplies maintenance surface and creates fragile phase-dependency questions (can `decide` run without `brainstorm`?). Gemini correctly identifies wiki artifact gaps when phases that normally produce files are silently omitted mid-skill.

**Option A's genuine strengths in this context:**
- Only one file changes: `/gm/SKILL.md`
- The routing decision (simple → `/implement` directly; complex → `/architect`) is cleaner than modifying sub-skills
- Wiki and logging infrastructure is fully preserved — overview.md still records all phases, just with a "direct-implement" step label
- QA layer still runs unchanged after a direct-implement succeeds
- The blast radius of a wrong complexity assessment is low: the worst case is a shallow implementation that fails tests, which the test suite catches

## Changes Required

### Files to modify
- `.claude/skills/gm/SKILL.md` — add a new Step 3b (Complexity Assessment) between task decomposition and task execution; modify Step 4c routing to call `/implement` directly for simple tasks

### Files to create
None.

### Files to delete
None.

## Key Interfaces / Data Structures

**Complexity judgment result** (in-memory, Claude's reasoning):
- Classification: `simple` or `standard`
- `simple` criteria (ALL of the following should be true):
  - The task is narrowly scoped: it modifies one specific, already-understood function, adds a log line, renames a variable, updates a config value, or makes a localized mechanical change
  - There is no ambiguity about the correct approach — no design decision is required
  - The task does not introduce new abstractions, new APIs, new modules, or cross-cutting concerns
  - The task can be fully described in one sentence without qualifications
- `standard` criteria (ANY of the following makes a task standard):
  - Requires choosing between multiple viable design approaches
  - Introduces a new system component, module, or interface contract
  - Has non-obvious interactions with other parts of the codebase
  - Task description contains hedging language ("might", "explore", "consider", "redesign")
  - The implementer would need to make a significant judgment call before writing code

**Routing table:**
| Task type (from Step 3) | Complexity | Skill invoked |
|-------------------------|------------|---------------|
| architect | standard | `/architect <task> $gemini_flag` |
| architect | simple | `/implement <task>` |
| refactor | standard | `/refactor <task> $gemini_flag` |
| refactor | simple | `/implement <task>` |
| qa | (any) | `/qa <task> $gemini_flag` (QA tasks are never short-circuited) |

**Overview.md pipeline row for direct-implement:**
```
| 1 | implement | direct (simple task) | [log](decisions/<filename>) | done/failed |
```

## Implementation Steps

1. **Add Step 3b in gm/SKILL.md — Complexity Assessment block** — After the existing Step 3 (Build Task List) and before Step 4 (Execute Tasks), insert a new named section "Step 3b: Complexity Assessment". Instruct Claude to evaluate each task in the task list against the simple/standard criteria above and annotate each task entry with its complexity label. Print the annotated plan so the user sees complexity alongside skill type, e.g.:

   ```
   📋 Task plan:
     1. [architect / simple]   Add a log line to the auth handler
     2. [architect / standard] Add plugin system for payment providers
     3. [qa]                   Write tests for auth module
   ```

   Important: QA-type tasks are never marked simple; leave them unlabeled or label them `standard` always, because QA tasks always benefit from a full adversarial analysis.

2. **Modify Step 4a in gm/SKILL.md — overview.md initial table** — The initial pipeline steps table in overview.md should reflect the expected phases based on complexity. For simple tasks, the table should show one row: "direct-implement". For standard tasks, the table should show the normal phases (brainstorm / critique / decide / implement for architect-type tasks). Write these placeholder rows during Step 4a so the recovery reader knows what to expect.

3. **Modify Step 4c in gm/SKILL.md — Skill invocation routing** — Replace the current flat routing block (architect → `/architect`, refactor → `/refactor`, qa → `/qa`) with a branching structure:

   - If task type is `qa`: always invoke `/qa <task-text> $gemini_flag`
   - If task type is `architect` or `refactor` AND complexity is `simple`: invoke `/implement <task-text>` with no `--plan-file` argument (standalone direct-task mode)
   - If task type is `architect` AND complexity is `standard`: invoke `/architect <task-text> $gemini_flag`
   - If task type is `refactor` AND complexity is `standard`: invoke `/refactor <task-text> $gemini_flag`

   Success/failure detection logic does not change — look for `✅` + "complete" or "passing" vs `❌` or "failed".

4. **Modify Step 4c in gm/SKILL.md — overview.md row append for direct-implement** — When a task is routed to direct `/implement`, the phase label in the overview.md row should read `direct (simple task)` instead of the pipeline skill type. The log file detection logic (`docs/.logging-current`) remains identical since `/implement` does not call `/logging` and won't write a sentinel — in this case, leave the log column as `—` or note "no decision log (direct implement)". Adjust the row-append bash snippet accordingly:

   ```bash
   # For direct-implement path (no logging sentinel written by /implement)
   echo "| 1 | implement | direct (simple task) | — | ${PHASE_STATUS} |" >> "docs/${TASK_ID}/overview.md"
   ```

5. **Modify Step 4d in gm/SKILL.md — QA layer eligibility** — The QA layer eligibility check currently reads: "Only if `qa_layer=true` AND `primary_success=true` AND the skill type was `architect` or `refactor`". Add complexity to this: QA layer runs for both simple and standard tasks as long as the primary succeeded and the skill type was architect or refactor. No change to the QA invocation itself. This preserves the spec's requirement that the QA layer is never skipped regardless of complexity.

6. **Modify Step 4c in gm/SKILL.md — Artifact copy block for simple tasks** — After a direct-implement run, `docs/architecture_candidates.md` and `docs/approved_architecture.md` will not exist (they were never generated). The existing `cp` commands are already guarded with `[[ -f ... ]] && cp ... || true`, so no change to the copy block is needed. Confirm this guard is present; if not, add it.

7. **Update the log note for complexity routing** — After determining complexity in Step 3b, log the decisions to the GM decision log:
   ```
   /logging note <LOG_FILE> "Complexity Assessment" "Task 1: simple (direct-implement) | Task 2: standard (architect) | ..."
   ```
   This creates an audit trail of why each task was routed the way it was.

## Verification

Run the unit test suite to confirm no existing tests are broken:
```bash
./tests/run_tests.sh --unit
```

Manual smoke test — from an interactive `claude-box` session, invoke `/gm` with a known-simple task and verify:
1. The gm-status.md shows the correct skill invocation label
2. The `docs/<task-id>/overview.md` shows `direct (simple task)` in the Pipeline Steps table
3. The complexity assessment log line appears in the GM decision log (`/logging read gm`)
4. For a known-complex task, the full `/architect` pipeline still runs and produces `docs/architecture_candidates.md` and `docs/approved_architecture.md`
5. QA layer still runs after a successful direct-implement when `--qa` is given

## Outcome

**Result:** success
