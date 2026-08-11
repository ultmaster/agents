#!/usr/bin/env bash
# Scan the tree for AI marker comments and print them as file:line:text.
# Markers: AI-FIX:  AI-REFACTOR:  AI-VERIFY:  AI-QUESTION:  (and any AI-<UPPER>:)
#
# Usage:
#   scan.sh                    # scan the whole repository/current directory
#   scan.sh src tests          # scope to one or more paths
#
# The skill's own directory is excluded so the marker strings documented in
# SKILL.md don't show up as work items (the self-reference trap). Colon-
# terminated tags only, which keeps prose like "AI-powered" out of the results;
# widen the pattern if a codebase writes markers without the colon.
set -euo pipefail

targets=("$@")
if [ ${#targets[@]} -eq 0 ]; then
  if root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    targets=("${root}")
  else
    targets=(".")
  fi
fi

found=1
if command -v rg >/dev/null 2>&1; then
  rg --line-number --no-heading --color never \
    --glob '!**/.git/**' \
    --glob '!**/node_modules/**' \
    --glob '!**/dist/**' \
    --glob '!**/build/**' \
    --glob '!**/coverage/**' \
    --glob '!**/vendor/**' \
    --glob '!**/.venv/**' \
    --glob '!**/ai-comment/**' \
    '\bAI-[A-Z]+:' -- "${targets[@]}" && found=0 || found=$?
else
  grep -rnsE '\bAI-[A-Z]+:' \
    --exclude-dir=.git \
    --exclude-dir=node_modules \
    --exclude-dir=dist \
    --exclude-dir=build \
    --exclude-dir=coverage \
    --exclude-dir=vendor \
    --exclude-dir=.venv \
    --exclude-dir=ai-comment \
    -- "${targets[@]}" && found=0 || found=$?
fi

if [ "${found}" -eq 1 ]; then
  echo "No AI marker comments found."
elif [ "${found}" -ne 0 ]; then
  exit "${found}"
fi
