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

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
skill_root="$(cd -- "${script_dir}/.." && pwd -P)"
readonly skill_root

targets=("$@")
if ((${#targets[@]} == 0)); then
  if root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    targets=("${root}")
  else
    targets=(".")
  fi
fi

file_list="$(mktemp)"
cleanup() {
  rm -f -- "${file_list}"
}
trap cleanup EXIT

# Prune only this skill's physical directory. A target repository may have an
# unrelated directory named ai-comment, and markers there are real work items.
find -- "${targets[@]}" \
  \( -type d \( \
    -samefile "${skill_root}" -o \
    -name .git -o \
    -name node_modules -o \
    -name dist -o \
    -name build -o \
    -name coverage -o \
    -name vendor -o \
    -name .venv \
  \) -prune \) -o -type f -print0 > "${file_list}"

found=1
while IFS= read -r -d '' file; do
  file_dir="$(cd -- "$(dirname -- "${file}")" && pwd -P)"
  case "${file_dir}" in
    "${skill_root}" | "${skill_root}"/*) continue ;;
  esac

  status=0
  if command -v rg >/dev/null 2>&1; then
    rg --line-number --with-filename --no-heading --color never \
      '\bAI-[A-Z]+:' -- "${file}" || status=$?
  else
    grep -nHEI '\bAI-[A-Z]+:' -- "${file}" || status=$?
  fi
  case "${status}" in
    0) found=0 ;;
    1) ;;
    *) exit "${status}" ;;
  esac
done < "${file_list}"

if ((found == 1)); then
  echo "No AI marker comments found."
fi
