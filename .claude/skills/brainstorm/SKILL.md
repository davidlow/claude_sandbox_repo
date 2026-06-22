---
name: brainstorm
description: Generate 3 distinct architectural or solution approaches for a task. Writes candidates to docs/architecture_candidates.md (architect mode) or docs/refactor_candidates.md (refactor mode). Fast divergent thinking — no code, analysis only.
argument-hint: "[architect|refactor] <task description>"
context: fork
model: haiku
allowed-tools: Read, Write, Bash(mkdir -p *), Bash(date *), Bash(ls *), Bash(find . *)
---

# Brainstorm

Your job is to generate exactly 3 genuinely distinct approaches for the task in `$ARGUMENTS`. You are in fast divergent-thinking mode: move quickly, think broadly, do not write executable code.

## Step 1: Parse Mode and Task

The first word of `$ARGUMENTS` determines the output file:
- `architect` → write to `docs/architecture_candidates.md`
- `refactor` → write to `docs/refactor_candidates.md`
- (anything else) → default to `docs/architecture_candidates.md`

Strip the mode word and treat the rest as the task description.

## Step 2: Gather Context

1. Read `CLAUDE.md` if it exists — understand the project structure and conventions.
2. Read relevant source files that relate to the task (use `find . -name "*.sh" -o -name "*.py"` etc. to locate them quickly; read only what's relevant).
3. Run `ls docs/decisions/ 2>/dev/null` and read the 3 most recent decision logs if any exist — check what approaches have already been tried and failed.

## Step 3: Generate 3 Distinct Approaches

Approaches must represent **genuinely different design philosophies**, not theme variations. For example:
- Option A: Minimal patch — smallest targeted change, lowest blast radius
- Option B: Structural improvement — address root cause with a moderate refactor
- Option C: Systematic rewrite — clean-slate approach to the affected component

For `refactor` mode: the three options should be minimal/surgical, structural, and rewrite.
For `architect` mode: three different architectural patterns, data-flow models, or abstraction layers.

Write to the output file using exactly this structure:

```markdown
# Brainstorm: <task summary>

**Generated:** <date>

## Option A: <Name>

**Summary:** One-line description of the approach.

**Key design decisions:**
- Decision 1
- Decision 2

**Trade-offs:**
- Extensibility: ...
- Complexity: ...
- Blast radius / risk: ...

**Risks or prerequisites:** Any dependencies, concerns, or unknowns.

---

## Option B: <Name>

(same structure)

---

## Option C: <Name>

(same structure)
```

Do NOT write executable code. Architectural descriptions, trade-off analysis, and design decisions only.

## Step 4: Create the Output File

Run `mkdir -p docs` first. Write the candidates file.

Finish by printing a one-line summary of each option so the orchestrator can see what was generated.
