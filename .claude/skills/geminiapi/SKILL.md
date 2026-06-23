---
name: geminiapi
description: Call the Gemini API using the project's lib/launch-lib.sh infrastructure. Modes: architect-critique → docs/gemini_architectural_audit.md, qa-audit → tests/gemini_missing_coverage.md, refactor-diagnosis → GEMINI_ADVICE.md, dispatch → stdout. Requires GEMINI_API_KEY env var. Non-fatal if unavailable.
argument-hint: "[architect-critique|qa-audit|refactor-diagnosis|dispatch] <task>"
context: fork
allowed-tools: Bash(source /workspace/lib/launch-lib.sh*), Bash(python3 *), Bash(mktemp), Bash(rm -f *), Bash(mkdir -p *), Bash(find . *), Bash(head -c *), Bash(wc -c *), Bash(cat *), Bash(ls *), Write, Read
---

# Gemini API

Your job is to call the Gemini API using the project's existing infrastructure in `lib/launch-lib.sh`. This provides cross-model auditing — a different AI reviewing the work from an outside perspective.

## Step 1: Check Prerequisites

1. Verify `GEMINI_API_KEY` is set: run `bash -c 'echo "${GEMINI_API_KEY:+set}"'`. If not set, print "⚠️ GEMINI_API_KEY not set — skipping Gemini call" and exit cleanly (exit 0, not an error).
2. Verify `lib/launch-lib.sh` exists: `ls /workspace/lib/launch-lib.sh`. If missing, print an error and exit.

## Step 2: Parse Mode and Task

The first word of `$ARGUMENTS` is the mode. The rest is the task context.

## Step 3: Build Prompt and Call API

Use this Bash pattern for all modes — source the lib and call the prompt builder + `call_gemini`:

```bash
source /workspace/lib/launch-lib.sh
PROMPT_FILE=$(mktemp /tmp/gemini_prompt_XXXXXX.txt)
# ... build the prompt (see per-mode instructions below) ...
call_gemini "$PROMPT_FILE" "<output_file>"
EXIT=$?
rm -f "$PROMPT_FILE"
exit $EXIT
```

### Mode: `architect-critique`

Output file: `docs/gemini_architectural_audit.md`

Build prompt:
```bash
TASK=$(echo "$ARGUMENTS" | cut -d' ' -f2-)
build_gemini_architectural_prompt "$TASK" "docs/architecture_candidates.md" > "$PROMPT_FILE"
```

Run `mkdir -p docs` first. Then call `call_gemini "$PROMPT_FILE" "docs/gemini_architectural_audit.md"`.

On success: print "✅ Gemini architectural critique written to docs/gemini_architectural_audit.md"
On failure: print "⚠️ Gemini critique failed — continuing without it" and exit 0.

### Mode: `qa-audit`

Output file: `tests/gemini_missing_coverage.md`

Bundle source and test files into a payload (max 500KB):
```bash
PAYLOAD_FILE=$(mktemp /tmp/gemini_qa_payload_XXXXXX.txt)
find . -type f \( -name "*.py" -o -name "*.js" -o -name "*.ts" -o -name "*.tsx" \
  -o -name "*.go" -o -name "*.rs" -o -name "*.rb" -o -name "*.sh" -o -name "*.bash" \
  -o -name "*.c" -o -name "*.cpp" -o -name "*.java" \) \
  -not -path "*/node_modules/*" -not -path "*/.git/*" \
  -not -path "*/dist/*" -not -path "*/build/*" -not -path "*/vendor/*" \
  -not -path "*/.venv/*" -not -path "*/venv/*" -not -path "*/__pycache__/*" \
  -not -path "*/target/*" -not -path "*/.next/*" \
  -not -path "*/coverage/*" -not -path "*/.pytest_cache/*" | while read f; do
    echo "=== $f ===" >> "$PAYLOAD_FILE"
    cat "$f" >> "$PAYLOAD_FILE"
    echo "" >> "$PAYLOAD_FILE"
    if [ $(wc -c < "$PAYLOAD_FILE") -gt 512000 ]; then break; fi
done
TASK=$(echo "$ARGUMENTS" | cut -d' ' -f2-)
build_gemini_qa_prompt "$TASK" "$PAYLOAD_FILE" > "$PROMPT_FILE"
rm -f "$PAYLOAD_FILE"
```

Run `mkdir -p tests` first. Then call `call_gemini "$PROMPT_FILE" "tests/gemini_missing_coverage.md"`.

On success: print "✅ Gemini QA audit written to tests/gemini_missing_coverage.md"
On failure: exit 0 with a warning.

### Mode: `refactor-diagnosis`

Output file: `GEMINI_ADVICE.md`

Build context from git diff and any provided context file:
```bash
CONTEXT_FILE=$(mktemp /tmp/gemini_refactor_ctx_XXXXXX.txt)
TASK=$(echo "$ARGUMENTS" | cut -d' ' -f2-)
git -C /workspace diff --stat HEAD 2>/dev/null | head -50 >> "$CONTEXT_FILE" || true
git -C /workspace diff HEAD 2>/dev/null | head -500 >> "$CONTEXT_FILE" || true
build_gemini_refactor_prompt "$TASK" "$CONTEXT_FILE" > "$PROMPT_FILE"
rm -f "$CONTEXT_FILE"
```

Call `call_gemini "$PROMPT_FILE" "GEMINI_ADVICE.md"`.

### Mode: `dispatch`

No output file — print parsed pipeline steps to stdout for the caller.

```bash
TASK=$(echo "$ARGUMENTS" | cut -d' ' -f2-)
build_gemini_dispatch_prompt "$TASK" > "$PROMPT_FILE"
RESPONSE_FILE=$(mktemp /tmp/gemini_dispatch_resp_XXXXXX.txt)
call_gemini "$PROMPT_FILE" "$RESPONSE_FILE"
cat "$RESPONSE_FILE"
rm -f "$RESPONSE_FILE"
```

## Step 4: Report

Always exit 0 (failures are non-fatal — the caller decides whether to continue without the Gemini result).
