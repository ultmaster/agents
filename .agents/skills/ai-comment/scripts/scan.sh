#!/usr/bin/env bash
# Scan the tree for AI marker comments and print them as file:line:text.
# Markers: AI-FIX:  AI-REFACTOR:  AI-VERIFY:  AI-QUESTION:  (and any AI-<UPPER>:)
#
# Usage:
#   scan.sh                          # scan the whole tree from the current directory
#   scan.sh packages/bubble          # scope to one path (repeatable)
#   scan.sh $(git diff --name-only)  # scope to the current working diff
#
# The skill's own directory is excluded so the marker strings documented in
# SKILL.md don't show up as work items (the self-reference trap). Colon-
# terminated tags only, which keeps prose like "AI-powered" out of the results;
# widen the pattern if a codebase writes markers without the colon.
set -euo pipefail

paths=("$@")
[ ${#paths[@]} -eq 0 ] && paths=(".")

if grep -rnsE '\bAI-[A-Z]+:' \
   --exclude-dir=node_modules \
   --exclude-dir=dist \
   --exclude-dir=.git \
   --exclude-dir=ai-comment \
   --exclude=pnpm-lock.yaml \
   -- "${paths[@]}"; then
  :
else
  echo "No AI marker comments found."
fi
