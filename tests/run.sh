#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$repo_root"

required_commands=(
  bash curl file find git jq lsof python3 rg setsid shellcheck ss
)
for command_name in "${required_commands[@]}"; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'tests: required command is unavailable: %s\n' "$command_name" >&2
    exit 1
  }
done
python3 -c 'import importlib.metadata as m; import skills_ref, strictyaml; assert m.version("skills-ref") == "0.1.1"' 2>/dev/null || {
  printf 'tests: install skills-ref==0.1.1 for skill validation\n' >&2
  exit 1
}

mapfile -d '' shell_scripts < <(
  find setup.sh skills tests -type f -name '*.sh' -print0 | sort -z
)

printf '==> skill metadata\n'
python3 tests/validate_skills.py

printf '==> shell syntax\n'
bash -n "${shell_scripts[@]}"

printf '==> shellcheck\n'
shellcheck "${shell_scripts[@]}"

printf '==> repository invariants\n'
[[ -f CLAUDE.md && ! -L CLAUDE.md ]]
[[ "$(< CLAUDE.md)" == $'# Claude Code instructions\n\n@AGENTS.md' ]]
for executable in setup.sh skills/*/scripts/*.sh tests/run.sh tests/*_test.sh; do
  [[ -x "$executable" ]] || {
    printf 'tests: expected an executable file: %s\n' "$executable" >&2
    exit 1
  }
done
first_symlink=$(find . -path './.git' -prune -o -type l -print -quit)
if [[ -n "$first_symlink" ]]; then
  printf 'tests: repository tree contains a symlink: %s\n' "$first_symlink" >&2
  exit 1
fi
if git ls-files -s | awk '$1 == "120000" { found=1 } END { exit !found }'; then
  printf 'tests: git index contains a symlink entry\n' >&2
  exit 1
fi

mapfile -d '' test_scripts < <(find tests -maxdepth 1 -type f -name '*_test.sh' -print0 | sort -z)
if ((${#test_scripts[@]} == 0)); then
  printf 'tests: no behavioral test scripts found\n' >&2
  exit 1
fi
for test_script in "${test_scripts[@]}"; do
  printf '==> %s\n' "$test_script"
  "$test_script"
done

printf 'all tests passed\n'
