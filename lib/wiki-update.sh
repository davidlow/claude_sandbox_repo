#!/bin/bash
# lib/wiki-update.sh — populate a /gm task wiki after a pipeline phase completes
#
# Usage: bash lib/wiki-update.sh <TASK_ID> <skill_type> <step_num> <success|failed> [phase_label]
#
# Arguments:
#   TASK_ID      — e.g. 20260628-1535_investigate-frequent-claude-box-re-login
#   skill_type   — e.g. architect, refactor, qa, implement
#   step_num     — 1 for primary phase, 2 for QA adversarial layer
#   success|failed
#   phase_label  — (optional) "primary" or "adversarial"; defaults to "primary"
#
# Reads the phase log via docs/.logging-<skill_type>-last (written by /logging init;
# never deleted), falling back to the newest matching docs/decisions/*_<skill>.md.
# Copies all generated artifacts into the correct task wiki subdirectory and updates
# overview.md tables atomically via sed.

set -eo pipefail

TASK_ID="${1:?Usage: wiki-update.sh <TASK_ID> <skill_type> <step_num> <success|failed> [phase_label]}"
SKILL_TYPE="${2:?skill_type required}"
STEP_NUM="${3:-1}"
RAW_STATUS="${4:-success}"
PHASE_LABEL="${5:-primary}"
TASK_DIR="docs/${TASK_ID}"

if [[ ! -d "$TASK_DIR" ]]; then
  echo "❌ wiki-update: task directory not found: $TASK_DIR" >&2
  exit 1
fi

# ---------- Locate phase log ----------
# Primary:  docs/.logging-<skill>-last — written by /logging init, never deleted
# Fallback: newest matching file in docs/decisions/
PHASE_LOG=$(cat "docs/.logging-${SKILL_TYPE}-last" 2>/dev/null || \
            ls -t "docs/decisions/"*"_${SKILL_TYPE}.md" 2>/dev/null | head -1 || \
            echo "")
LOG_FILENAME=$(basename "$PHASE_LOG")

# ---------- Format status and link ----------
if [[ "$RAW_STATUS" == "success" ]]; then
  PHASE_STATUS="✅ done"
else
  PHASE_STATUS="❌ failed"
fi

if [[ -n "$LOG_FILENAME" ]]; then
  LOG_LINK="[${LOG_FILENAME}](decisions/${LOG_FILENAME})"
else
  LOG_LINK="(log unavailable)"
fi

# ---------- Copy phase log ----------
if [[ -n "$PHASE_LOG" && -f "$PHASE_LOG" ]]; then
  cp "$PHASE_LOG" "${TASK_DIR}/decisions/"
fi

# ---------- Copy artifacts to task wiki subdirs ----------
[[ -f "docs/architecture_candidates.md"    ]] && cp "docs/architecture_candidates.md"    "${TASK_DIR}/architecture/" || true
[[ -f "docs/approved_architecture.md"      ]] && cp "docs/approved_architecture.md"      "${TASK_DIR}/architecture/" || true
[[ -f "docs/approved_fix.md"               ]] && cp "docs/approved_fix.md"               "${TASK_DIR}/architecture/" || true
[[ -f "docs/gemini_architectural_audit.md" ]] && cp "docs/gemini_architectural_audit.md" "${TASK_DIR}/gemini/"       || true
[[ -f "tests/gemini_missing_coverage.md"   ]] && cp "tests/gemini_missing_coverage.md"   "${TASK_DIR}/qa/"           || true

# ---------- Update overview.md ----------
OVW="${TASK_DIR}/overview.md"

# 1. Append a row to the Pipeline Steps table by replacing the marker.
#    Uses @ as sed delimiter so | in the table row is not misinterpreted.
STEPS_ROW="| ${STEP_NUM} | ${SKILL_TYPE} | ${PHASE_LABEL} | ${LOG_LINK} | ${PHASE_STATUS} |"
sed -i "s@<!-- STEPS_END -->@${STEPS_ROW}\n<!-- STEPS_END -->@" "$OVW"

# 2. Append a row to the Decision Logs table.
if [[ -n "$LOG_FILENAME" ]]; then
  LOGS_ROW="| ${LOG_LINK} | ${SKILL_TYPE} | ${PHASE_STATUS} |"
  sed -i "s@<!-- LOGS_END -->@${LOGS_ROW}\n<!-- LOGS_END -->@" "$OVW"
fi

# 3. Mark each artifact row ✅ available using a line-address sed so only the
#    matching filename row is updated (avoids false matches on other ⏳ pending rows).
[[ -f "${TASK_DIR}/architecture/architecture_candidates.md"    ]] && \
  sed -i '/architecture_candidates\.md/ s/ pending / available /' "$OVW" || true
[[ -f "${TASK_DIR}/architecture/approved_architecture.md"      ]] && \
  sed -i '/approved_architecture\.md/ s/ pending / available /' "$OVW" || true
[[ -f "${TASK_DIR}/architecture/approved_fix.md"               ]] && \
  sed -i '/approved_fix\.md/ s/ pending / available /' "$OVW" || true
[[ -f "${TASK_DIR}/gemini/gemini_architectural_audit.md"       ]] && \
  sed -i '/gemini_architectural_audit\.md/ s/ pending / available /' "$OVW" || true
[[ -f "${TASK_DIR}/qa/gemini_missing_coverage.md"              ]] && \
  sed -i '/gemini_missing_coverage\.md/ s/ pending / available /' "$OVW" || true

echo "✅ Wiki updated: ${OVW}"
