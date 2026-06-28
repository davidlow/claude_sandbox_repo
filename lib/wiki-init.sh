#!/bin/bash
# lib/wiki-init.sh — create a /gm task wiki directory and write its initial overview.md
#
# Usage: bash lib/wiki-init.sh <TASK_ID> <task-text> <complexity> <base-branch>
#
# Creates docs/${TASK_ID}/{decisions,architecture,qa,gemini}/ and writes overview.md
# with the standard template including <!-- STEPS_END --> and <!-- LOGS_END --> markers
# that lib/wiki-update.sh uses to insert rows.
#
# Called by /gm before invoking the first pipeline skill for each task.

set -eo pipefail

TASK_ID="${1:?Usage: wiki-init.sh <TASK_ID> <task-text> <complexity> <base-branch>}"
TASK_TEXT="${2:?task-text required}"
COMPLEXITY="${3:-standard}"
BASE_BRANCH="${4:-main}"

TASK_DIR="docs/${TASK_ID}"
mkdir -p "${TASK_DIR}/decisions" "${TASK_DIR}/architecture" "${TASK_DIR}/qa" "${TASK_DIR}/gemini"

DATE_HUMAN=$(date '+%Y-%m-%d %H:%M')

cat > "${TASK_DIR}/overview.md" <<EOF
# Task: ${TASK_TEXT}

**Task ID:** ${TASK_ID}
**Date:** ${DATE_HUMAN}
**Branch:** <pending>
**Status:** in-progress
**Complexity:** ${COMPLEXITY}

## Pipeline Steps

| Step | Skill | Phase | Log | Status |
|------|-------|-------|-----|--------|
<!-- STEPS_END -->

## Architecture

| Artifact | Link | Status |
|----------|------|--------|
| Brainstorm candidates | [architecture_candidates.md](architecture/architecture_candidates.md) | ⏳ pending |
| Approved design | [approved_architecture.md](architecture/approved_architecture.md) | ⏳ pending |
| Fix spec | [approved_fix.md](architecture/approved_fix.md) | ⏳ pending |

## Gemini Audit

| Artifact | Link | Status |
|----------|------|--------|
| Architectural critique | [gemini_architectural_audit.md](gemini/gemini_architectural_audit.md) | ⏳ pending |

## QA

| Artifact | Link | Status |
|----------|------|--------|
| Missing coverage report | [gemini_missing_coverage.md](qa/gemini_missing_coverage.md) | ⏳ pending |

## Decision Logs

| Log | Pipeline | Status |
|-----|----------|--------|
<!-- LOGS_END -->

## Outcome

*(pending)*
EOF

echo "✅ Wiki initialized: ${TASK_DIR}/overview.md"
