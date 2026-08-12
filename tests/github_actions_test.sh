#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
gha="${repo_root}/skills/github-actions/scripts/gha.sh"
test_root="$(mktemp -d)"

cleanup() {
  rm -rf -- "${test_root}"
}
trap cleanup EXIT

fail() {
  printf 'github_actions_test: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local actual="$1" expected="$2"
  [[ "${actual}" == *"${expected}"* ]] ||
    fail "expected output to contain: ${expected}\nactual output:\n${actual}"
}

expect_failure() {
  local expected="$1"
  shift
  local actual status
  set +e
  actual="$("$@" 2>&1)"
  status=$?
  set -e
  ((status != 0)) || fail "command unexpectedly succeeded: $*"
  assert_contains "${actual}" "${expected}"
}

git_repo="${test_root}/repo"
mkdir -p "${git_repo}"
git -C "${git_repo}" init -q -b feature/test
git -C "${git_repo}" remote add origin https://github.com/personal/project.git
git -C "${git_repo}" remote add upstream git@github.com:canonical/project.git

output="$(cd "${git_repo}" && "${gha}" list --dry-run)"
assert_contains "${output}" 'gh run list --repo canonical/project'
assert_contains "${output}" '--branch feature/test'

output="$(cd "${git_repo}" && CI_BRANCH=environment "${gha}" list --remote origin --dry-run)"
assert_contains "${output}" '--repo personal/project'
assert_contains "${output}" '--branch environment'

output="$(cd "${git_repo}" && CI_BRANCH=environment "${gha}" list --repo ghe.example/acme/widget --branch explicit --workflow ci.yml --limit 4 --dry-run)"
assert_contains "${output}" '--repo ghe.example/acme/widget'
assert_contains "${output}" '--limit 4'
assert_contains "${output}" '--workflow ci.yml'
assert_contains "${output}" '--branch explicit'

output="$(cd "${git_repo}" && "${gha}" await --repo owner/repo --workflow ci.yml --sha deadbeef --timeout 0 --dry-run)"
assert_contains "${output}" 'gh run list --repo owner/repo'
assert_contains "${output}" '--commit deadbeef'
assert_contains "${output}" 'gh run watch --repo owner/repo \<run-id\> --exit-status'

output="$(cd "${git_repo}" && "${gha}" watch 41 --repo owner/repo --dry-run)"
assert_contains "${output}" 'gh run watch --repo owner/repo 41 --exit-status'
output="$(cd "${git_repo}" && "${gha}" view 41 --failed --repo owner/repo --dry-run)"
assert_contains "${output}" 'gh run view --repo owner/repo 41 --log-failed'
output="$(cd "${git_repo}" && "${gha}" dispatch ci.yml --ref feature/test --field reason=manual --repo owner/repo --dry-run)"
assert_contains "${output}" 'gh workflow run ci.yml --repo owner/repo --ref feature/test --field reason=manual'
output="$(cd "${git_repo}" && "${gha}" rerun 41 --failed --repo owner/repo --dry-run)"
assert_contains "${output}" 'gh run rerun --repo owner/repo 41 --failed'
output="$(cd "${git_repo}" && "${gha}" cancel 41 --repo owner/repo --dry-run)"
assert_contains "${output}" 'gh run cancel --repo owner/repo 41'

expect_failure 're-run with --yes' "${gha}" dispatch ci.yml --ref main --repo owner/repo
expect_failure 're-run with --yes' "${gha}" rerun 41 --repo owner/repo
expect_failure 'non-negative/positive integer' "${gha}" await --repo owner/repo --branch main --timeout invalid --dry-run

fake_bin="${test_root}/fake-bin"
mkdir -p "${fake_bin}"
cat > "${fake_bin}/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${GH_FAKE_LOG}"
if [[ "$1 $2" == 'auth status' ]]; then
  exit "${GH_FAKE_AUTH_STATUS:-0}"
fi
if [[ "$1 $2" == 'run list' ]]; then
  case "${GH_FAKE_MODE:-empty}" in
    error)
      printf 'simulated run-list failure\n' >&2
      exit 42
      ;;
    id) printf '9001\n' ;;
    empty) ;;
  esac
  exit 0
fi
if [[ "$1 $2" == 'run watch' ]]; then
  printf 'watched\n'
  exit 0
fi
printf 'unexpected fake gh invocation: %s\n' "$*" >&2
exit 97
FAKE_GH
chmod +x "${fake_bin}/gh"

gh_log="${test_root}/gh.log"
: > "${gh_log}"
set +e
output="$(
  cd "${git_repo}"
  PATH="${fake_bin}:${PATH}" GH_FAKE_LOG="${gh_log}" GH_FAKE_MODE=error \
    "${gha}" await --repo owner/repo --branch main --timeout 0 2>&1
)"
status=$?
set -e
((status != 0)) || fail 'GHA await swallowed a run-list failure'
assert_contains "${output}" 'simulated run-list failure'
assert_contains "${output}" 'failed to list workflow runs'

# A sandbox that blocks the credential store fails the auth preflight exactly as
# a signed-out account does. The message has to raise that first, or the agent
# relays a login problem the user does not have.
: > "${gh_log}"
set +e
output="$(
  cd "${git_repo}"
  PATH="${fake_bin}:${PATH}" GH_FAKE_LOG="${gh_log}" GH_FAKE_AUTH_STATUS=1 \
    "${gha}" list --repo owner/repo 2>&1
)"
status=$?
set -e
((status != 0)) || fail 'GHA list ran without authentication'
assert_contains "${output}" 'gh is not authenticated for github.com'
assert_contains "${output}" 'sandboxed'
assert_contains "${output}" 'escalated'

: > "${gh_log}"
set +e
output="$(
  cd "${git_repo}"
  PATH="${fake_bin}:${PATH}" GH_FAKE_LOG="${gh_log}" GH_FAKE_MODE=empty \
    "${gha}" await --repo owner/repo --branch main --timeout 0 --interval 1 2>&1
)"
status=$?
set -e
((status != 0)) || fail 'GHA await unexpectedly found a run'
assert_contains "${output}" 'within 0s'
[[ "$(grep -c '^run list ' "${gh_log}")" -eq 1 ]] ||
  fail 'GHA timeout=0 performed more than one run-list poll'

printf 'github_actions_test: passed\n'
