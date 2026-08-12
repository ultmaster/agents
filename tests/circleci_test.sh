#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
circle="${repo_root}/skills/circleci/scripts/circleci.sh"
test_root="$(mktemp -d)"

cleanup() {
  rm -rf -- "${test_root}"
}
trap cleanup EXIT

fail() {
  printf 'circleci_test: %s\n' "$*" >&2
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
mkdir -p "${git_repo}/.circleci"
git -C "${git_repo}" init -q -b feature/test
git -C "${git_repo}" remote add origin https://github.com/personal/project.git
git -C "${git_repo}" remote add upstream git@github.com:canonical/project.git
cat > "${git_repo}/.circleci/config.yml" <<'YAML'
version: 2.1
parameters:
  run_tests:
    type: boolean
    default: false
  run_api:
    type: boolean
    default: false
jobs: {}
YAML

output="$(cd "${git_repo}" && "${circle}" list --branch feature/test --dry-run)"
assert_contains "${output}" 'https://circleci.com/api/v2/project/gh/canonical/project/pipeline'
output="$(cd "${git_repo}" && "${circle}" list --remote origin --branch main --dry-run)"
assert_contains "${output}" 'https://circleci.com/api/v2/project/gh/personal/project/pipeline'
output="$(cd "${git_repo}" && CIRCLECI_PROJECT_SLUG=github/environment/project "${circle}" list --branch main --dry-run)"
assert_contains "${output}" '/project/gh/environment/project/pipeline'

for project in \
  'gh//repo' \
  'gh/owner/' \
  'gh/owner/repo/' \
  'gh/owner/repo/extra' \
  'github//repo' \
  'github/owner/repo/' \
  'https://github.com//repo' \
  'https://github.com/owner/repo/extra'; do
  if output="$(cd "${git_repo}" && "${circle}" list --project "${project}" --branch main --dry-run 2>&1)"; then
    fail "malformed CircleCI project unexpectedly succeeded: ${project}"
  fi
  assert_contains "${output}" 'cannot parse CircleCI project'
done

typed_output="$(
  cd "${git_repo}"
  "${circle}" trigger --project gh/owner/repo --branch feature/test \
    --parameter flag=true --parameter count=2 --parameter nil=null \
    --parameter ratio=1.5 --parameter word=hello --dry-run
)"
assert_contains "${typed_output}" 'parameters={"flag":true,"count":2,"nil":null,"ratio":1.5,"word":"hello"}'
assert_not_contains "${typed_output}" 'Circle-Token: actual'

output="$(cd "${git_repo}" && "${circle}" tests --project gh/owner/repo --module api --branch main --dry-run)"
assert_contains "${output}" 'parameters={"run_api":true}'
output="$(cd "${git_repo}" && "${circle}" await pipeline-1 --timeout 0 --dry-run)"
assert_contains "${output}" '/pipeline/pipeline-1/workflow'
output="$(cd "${git_repo}" && "${circle}" view pipeline-1 --dry-run)"
assert_contains "${output}" '/pipeline/pipeline-1/workflow'
output="$(cd "${git_repo}" && "${circle}" jobs workflow-1 --dry-run)"
assert_contains "${output}" '/workflow/workflow-1/job'
output="$(cd "${git_repo}" && "${circle}" job 12 --project gh/owner/repo --dry-run)"
assert_contains "${output}" '/project/github/owner/repo/12'
output="$(cd "${git_repo}" && "${circle}" cancel workflow-1 --dry-run)"
assert_contains "${output}" '/workflow/workflow-1/cancel'
output="$(cd "${git_repo}" && "${circle}" definitions --project gh/owner/repo --dry-run)"
assert_contains "${output}" '/project/gh/owner/repo'
assert_contains "${output}" '/projects/\<project-id\>/pipeline-definitions'
output="$(cd "${git_repo}" && "${circle}" delete-definition nightly --dry-run)"
assert_contains "${output}" '/pipeline-definitions/\<definition-id-for:nightly\>'

expect_failure 're-run with --yes' "${circle}" trigger --project gh/owner/repo --branch main
expect_failure 're-run with --yes' "${circle}" cancel workflow-1

fake_bin="${test_root}/fake-bin"
mkdir -p "${fake_bin}"
cat > "${fake_bin}/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -euo pipefail
header=''
IFS= read -r header || true
printf 'args=%s\nstdin-header=%s\n' "$*" "$([[ -n "${header}" ]] && printf received || printf absent)" >> "${CURL_FAKE_LOG}"
# Only the resolution tests record the credential itself, to prove which file won.
[[ -z "${CURL_FAKE_HEADER_LOG:-}" ]] || printf '%s\n' "${header}" >> "${CURL_FAKE_HEADER_LOG}"
if [[ "${CURL_FAKE_MODE:-}" == 'error' ]]; then
  printf 'simulated curl failure\n' >&2
  exit 22
fi
if [[ "$*" == *'/pipeline/'*'/workflow'* ]]; then
  case "${CURL_FAKE_MODE:-running}" in
    success) printf '%s\n' '{"items":[{"status":"success"}]}' ;;
    *) printf '%s\n' '{"items":[{"status":"running"}]}' ;;
  esac
elif [[ "$*" == *'/pipeline' ]]; then
  printf '%s\n' '{"id":"pipeline-1"}'
else
  printf '%s\n' '{}'
fi
FAKE_CURL
chmod +x "${fake_bin}/curl"

curl_log="${test_root}/curl.log"
: > "${curl_log}"
set +e
output="$(
  cd "${git_repo}"
  PATH="${fake_bin}:${PATH}" CURL_FAKE_LOG="${curl_log}" CIRCLECI_TOKEN=actual \
    "${circle}" trigger --project gh/owner/repo --branch main --watch \
      --timeout invalid --interval 1 --yes 2>&1
)"
status=$?
set -e
((status != 0)) || fail 'CircleCI accepted an invalid watch timeout'
assert_contains "${output}" 'non-negative/positive integer'
[[ ! -s "${curl_log}" ]] || fail 'CircleCI mutated before validating watch timing'

: > "${curl_log}"
set +e
output="$(
  cd "${git_repo}"
  PATH="${fake_bin}:${PATH}" CURL_FAKE_LOG="${curl_log}" CIRCLECI_TOKEN=actual \
    "${circle}" await pipeline-1 --timeout 0 --interval 1 2>&1
)"
status=$?
set -e
((status != 0)) || fail 'CircleCI await unexpectedly completed a running pipeline'
assert_contains "${output}" 'timed out after 0s'
[[ "$(grep -c '/pipeline/pipeline-1/workflow' "${curl_log}")" -eq 1 ]] ||
  fail 'CircleCI timeout=0 performed more than one workflow poll'

: > "${curl_log}"
output="$(
  cd "${git_repo}"
  PATH="${fake_bin}:${PATH}" CURL_FAKE_LOG="${curl_log}" CURL_FAKE_MODE=success \
    CIRCLECI_TOKEN=actual "${circle}" trigger --project gh/owner/repo \
      --branch main --parameter enabled=true --parameter count=3 --watch \
      --timeout 1 --interval 1 --yes
)"
assert_contains "${output}" 'pipeline=pipeline-1'
assert_contains "$(< "${curl_log}")" '--data {"branch":"main","parameters":{"enabled":true,"count":3}}'
assert_not_contains "$(< "${curl_log}")" 'actual'

: > "${curl_log}"
set +e
output="$(
  cd "${git_repo}"
  PATH="${fake_bin}:${PATH}" CURL_FAKE_LOG="${curl_log}" CURL_FAKE_MODE=error \
    CIRCLECI_TOKEN=actual "${circle}" await pipeline-1 --timeout 0 2>&1
)"
status=$?
set -e
((status != 0)) || fail 'CircleCI await swallowed a curl failure'
assert_contains "${output}" 'simulated curl failure'

# Local settings must come from the repository being worked on, so one project's
# token cannot silently become every project's default. Exercise a disposable
# copy of the skill so a skill-root .env can be planted without touching the
# installed tree.
disposable_skill="${test_root}/disposable-skill/ci"
mkdir -p "${disposable_skill}"
cp -R "${repo_root}/skills/circleci/scripts" "${disposable_skill}/"
printf 'CIRCLECI_TOKEN=from-skill-root\n' > "${disposable_skill}/.env"
disposable_circle="${disposable_skill}/scripts/circleci.sh"

profile_repo="${test_root}/profile-repo"
mkdir -p "${profile_repo}"
git -C "${profile_repo}" init -q -b main
git -C "${profile_repo}" remote add origin https://github.com/owner/profile.git

header_log="${test_root}/header.log"
resolved_token() {
  : > "${header_log}"
  (
    cd "${profile_repo}"
    PATH="${fake_bin}:${PATH}" CURL_FAKE_LOG="${curl_log}" \
      CURL_FAKE_HEADER_LOG="${header_log}" \
      "$@" list --project gh/owner/repo >/dev/null 2>&1
  ) || fail "circleci.sh list failed while resolving credentials"
  < "${header_log}" tr -d '\r'
}

# No profile directory: the skill's own .env still applies.
assert_contains "$(resolved_token "${disposable_circle}")" 'Circle-Token: from-skill-root'

# A repository profile directory owns settings outright. An empty one must not
# fall back to the skill's token; that fallback is the leak being prevented.
mkdir -p "${profile_repo}/.agents/skills/circleci"
expect_failure "CIRCLECI_TOKEN is unset" \
  env -C "${profile_repo}" "${disposable_circle}" list --project gh/owner/repo
output="$(cd "${profile_repo}" && "${disposable_circle}" list --project gh/owner/repo 2>&1)" || true
assert_contains "${output}" "${profile_repo}/.agents/skills/circleci/.env"
assert_not_contains "${output}" "to ${disposable_skill}/.env"

# A token in the repository profile wins over the skill's own.
printf 'CIRCLECI_TOKEN=from-agents-profile\n' > "${profile_repo}/.agents/skills/circleci/.env"
assert_contains "$(resolved_token "${disposable_circle}")" 'Circle-Token: from-agents-profile'

# The .claude profile applies when .agents is absent.
rm -rf "${profile_repo}/.agents"
mkdir -p "${profile_repo}/.claude/skills/circleci"
printf 'CIRCLECI_TOKEN=from-claude-profile\n' > "${profile_repo}/.claude/skills/circleci/.env"
assert_contains "$(resolved_token "${disposable_circle}")" 'Circle-Token: from-claude-profile'

# .agents wins over .claude when both exist.
mkdir -p "${profile_repo}/.agents/skills/circleci"
printf 'CIRCLECI_TOKEN=from-agents-profile\n' > "${profile_repo}/.agents/skills/circleci/.env"
assert_contains "$(resolved_token "${disposable_circle}")" 'Circle-Token: from-agents-profile'

# Explicit overrides beat discovery.
explicit_profile="${test_root}/explicit-profile"
mkdir -p "${explicit_profile}"
printf 'CIRCLECI_TOKEN=from-explicit-profile\n' > "${explicit_profile}/.env"
assert_contains \
  "$(CIRCLECI_PROFILE_DIR="${explicit_profile}" resolved_token "${disposable_circle}")" \
  'Circle-Token: from-explicit-profile'
printf 'CIRCLECI_TOKEN=from-explicit-file\n' > "${test_root}/explicit.env"
assert_contains \
  "$(CIRCLECI_ENV_FILE="${test_root}/explicit.env" resolved_token "${disposable_circle}")" \
  'Circle-Token: from-explicit-file'

# An exported token still outranks every file.
assert_contains \
  "$(CIRCLECI_TOKEN=from-environment resolved_token "${disposable_circle}")" \
  'Circle-Token: from-environment'

printf 'circleci_test: passed\n'
