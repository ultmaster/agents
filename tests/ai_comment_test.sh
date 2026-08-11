#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source_scanner="${repo_root}/skills/ai-comment/scripts/scan.sh"
test_root="$(mktemp -d)"

cleanup() {
  rm -rf -- "${test_root}"
}
trap cleanup EXIT

fail() {
  printf 'ai_comment_test: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local actual="$1" expected="$2"
  [[ "${actual}" == *"${expected}"* ]] ||
    fail "expected output to contain: ${expected}\nactual output:\n${actual}"
}

assert_not_contains() {
  local actual="$1" unexpected="$2"
  [[ "${actual}" != *"${unexpected}"* ]] ||
    fail "expected output not to contain: ${unexpected}\nactual output:\n${actual}"
}

fixture="${test_root}/fixture"
scanner_root="${fixture}/ai-comment"
fix_tag='AI-FIX'
verify_tag='AI-VERIFY'
mkdir -p \
  "${scanner_root}/scripts" \
  "${fixture}/project/ai-comment" \
  "${fixture}/project/src/space dir" \
  "${fixture}/project/node_modules/dependency"
cp "${source_scanner}" "${scanner_root}/scripts/scan.sh"
printf '%s: %s\n' "${fix_tag}" 'scanner documentation, not a work item' > "${scanner_root}/SKILL.md"
printf '# %s: %s\n' "${fix_tag}" 'keep this unrelated directory visible' > "${fixture}/project/ai-comment/work.txt"
printf '// %s: %s\n' "${verify_tag}" 'preserve paths containing spaces' > "${fixture}/project/src/space dir/check file.js"
printf '# %s: %s\n' "${fix_tag}" 'excluded dependency' > "${fixture}/project/node_modules/dependency/work.txt"
printf '%s\n' '# AI-powered prose has no marker colon' > "${fixture}/project/src/prose.txt"

rg_output="$(cd "${fixture}" && bash "${scanner_root}/scripts/scan.sh" "${fixture}")"
assert_contains "${rg_output}" "project/ai-comment/work.txt:1:# ${fix_tag}: keep this unrelated directory visible"
assert_contains "${rg_output}" "project/src/space dir/check file.js:1:// ${verify_tag}: preserve paths containing spaces"
assert_not_contains "${rg_output}" 'scanner documentation'
assert_not_contains "${rg_output}" 'excluded dependency'
assert_not_contains "${rg_output}" 'AI-powered prose'

# Exercise the grep fallback without relying on whether the host installs rg in
# /usr/bin. The scanner receives only the commands that fallback mode needs.
fallback_bin="${test_root}/fallback-bin"
mkdir -p "${fallback_bin}"
for command_name in dirname find grep mktemp rm; do
  command_path="$(command -v "${command_name}")"
  ln -s "${command_path}" "${fallback_bin}/${command_name}"
done
grep_output="$(
  cd "${fixture}"
  PATH="${fallback_bin}" /bin/bash "${scanner_root}/scripts/scan.sh" "${fixture}"
)"
[[ "${grep_output}" == "${rg_output}" ]] ||
  fail "rg and grep output differ\nrg:\n${rg_output}\ngrep:\n${grep_output}"

scoped_output="$(bash "${scanner_root}/scripts/scan.sh" "${fixture}/project/src")"
assert_contains "${scoped_output}" "${verify_tag}: preserve paths containing spaces"
assert_not_contains "${scoped_output}" 'unrelated directory visible'

empty_dir="${test_root}/empty"
mkdir -p "${empty_dir}"
empty_output="$(bash "${scanner_root}/scripts/scan.sh" "${empty_dir}")"
[[ "${empty_output}" == 'No AI marker comments found.' ]] ||
  fail "unexpected no-marker output: ${empty_output}"

if missing_output="$(bash "${scanner_root}/scripts/scan.sh" "${test_root}/missing" 2>&1)"; then
  fail 'a missing scan target unexpectedly succeeded'
fi
assert_contains "${missing_output}" 'No such file or directory'

printf 'ai_comment_test: passed\n'
