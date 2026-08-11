#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
TRACKER="${REPO_ROOT}/skills/issue-tracker/scripts/issue-tracker.sh"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/issue-tracker-test.XXXXXX")"
cleanup() {
  rm -rf "${TEST_ROOT}"
}
trap cleanup EXIT

mkdir -p "${TEST_ROOT}/bin" "${TEST_ROOT}/home" "${TEST_ROOT}/tmp"
export HOME="${TEST_ROOT}/home"
export TMPDIR="${TEST_ROOT}/tmp"
export PATH="${TEST_ROOT}/bin:/usr/local/bin:/usr/bin:/bin"
unset ISSUE_TRACKER_SIGNATURE GH_SESSION_TOKEN GITHUB_TOKEN GH_TOKEN

cat >"${TEST_ROOT}/bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail

printf '%q ' "$@" >>"${GH_FAKE_LOG:?}"
printf '\n' >>"${GH_FAKE_LOG}"

copy_body_file() {
  local previous='' arg
  for arg in "$@"; do
    if [ "${previous}" = '--body-file' ]; then
      cp "${arg}" "${GH_CAPTURE_BODY:?}"
      return 0
    fi
    previous="${arg}"
  done
  return 1
}

case "${1:-} ${2:-}" in
  'auth status') exit 0 ;;
  'auth token') printf '%s\n' 'fake-secret-token'; exit 0 ;;
  'api --hostname') printf '%s\n' 'fake-agent'; exit 0 ;;
  'repo view') printf '%s\n' "${GH_FAKE_REPO:-fallback/repository}"; exit 0 ;;
  'image --help') printf '%s\n' 'fake gh-image help'; exit 0 ;;
  'image check-token') printf '%s\n' 'fake-agent'; exit 0 ;;
  'image --repo')
    image_path="${!#}"
    printf '![%s](https://github.com/user-attachments/assets/fake-upload)\n' "$(basename -- "${image_path}")"
    exit 0
    ;;
  'issue view')
    if [[ " $* " == *' --json labels '* ]]; then
      [ "${GH_FAKE_MODE:-ok}" != 'fail-label-read' ] || exit 41
      printf '%s\n' "${GH_FAKE_LABELS:-triage}"
    elif [ -n "${GH_FAKE_JSON:-}" ]; then
      printf '%s\n' "${GH_FAKE_JSON}"
    else
      printf '%s\n' '{"number":1,"title":"Fake","state":"OPEN","labels":[],"author":{"login":"reporter"},"assignees":[],"milestone":null,"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","url":"https://github.com/owner/project/issues/1","body":"body","comments":[]}'
    fi
    exit 0
    ;;
  'issue create'|'issue comment')
    copy_body_file "$@"
    printf '%s\n' 'https://github.com/owner/project/issues/1'
    exit 0
    ;;
  'issue edit'|'issue list'|'label create'|'label list') exit 0 ;;
esac

printf 'unexpected fake gh invocation: %s\n' "$*" >&2
exit 97
FAKE_GH
chmod +x "${TEST_ROOT}/bin/gh"

cat >"${TEST_ROOT}/bin/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -euo pipefail

printf '%q ' "$@" >>"${CURL_FAKE_LOG:?}"
printf '\n' >>"${CURL_FAKE_LOG}"
output=''
while [ "$#" -gt 0 ]; do
  if [ "$1" = '-o' ]; then
    [ "$#" -ge 2 ] || exit 2
    output=$2
    shift 2
  else
    shift
  fi
done
[ -n "${output}" ] || exit 2
printf '%s' 'fake-image-bytes' >"${output}"
FAKE_CURL
chmod +x "${TEST_ROOT}/bin/curl"

TOTAL=0
FAILED=0
RUN_OUTPUT=''
RUN_STATUS=0

fail() {
  printf '    %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local expected=$1 actual=$2
  [ "${expected}" = "${actual}" ] || fail "expected '${expected}', got '${actual}'"
}

assert_contains() {
  local text=$1 expected=$2
  [[ "${text}" == *"${expected}"* ]] || fail "expected output to contain: ${expected}"
}

assert_not_contains() {
  local text=$1 unexpected=$2
  [[ "${text}" != *"${unexpected}"* ]] || fail "output unexpectedly contained: ${unexpected}"
}

capture() {
  set +e
  RUN_OUTPUT="$({ "$@"; } 2>&1)"
  RUN_STATUS=$?
  set -e
}

new_case() {
  CASE_DIR="$(mktemp -d "${TEST_ROOT}/tmp/case.XXXXXX")"
  GH_FAKE_LOG="${CASE_DIR}/gh.log"
  CURL_FAKE_LOG="${CASE_DIR}/curl.log"
  GH_CAPTURE_BODY="${CASE_DIR}/body.md"
  : >"${GH_FAKE_LOG}"
  : >"${CURL_FAKE_LOG}"
  export CASE_DIR GH_FAKE_LOG CURL_FAKE_LOG GH_CAPTURE_BODY
  unset GH_FAKE_MODE GH_FAKE_LABELS GH_FAKE_JSON GH_FAKE_REPO
}

run_test() {
  local name=$1
  shift
  TOTAL=$((TOTAL + 1))
  printf '  %-58s' "${name}"
  set +e
  (set -e; "$@")
  local status=$?
  set -e
  if [ "${status}" -eq 0 ]; then
    printf 'ok\n'
  else
    FAILED=$((FAILED + 1))
    printf 'FAIL\n'
  fi
}

test_validation_dry_run_and_gate() {
  new_case

  capture "${TRACKER}" status 0 --set triage --repo owner/project --dry-run
  [ "${RUN_STATUS}" -ne 0 ] || fail 'zero issue number was accepted'
  assert_contains "${RUN_OUTPUT}" 'issue must be a positive numeric issue number'

  capture "${TRACKER}" create --title Test --body Body --repo owner/project --dry-run
  [ "${RUN_STATUS}" -ne 0 ] || fail 'unsigned dry-run create was accepted'
  assert_contains "${RUN_OUTPUT}" 'create requires a signature'

  capture "${TRACKER}" create --title Test --body Body --sign 'Test Agent' --status triage \
    --area api --label bug --repo owner/project --dry-run
  assert_eq 0 "${RUN_STATUS}"
  assert_contains "${RUN_OUTPUT}" '+ gh issue create'
  assert_contains "${RUN_OUTPUT}" 'signature footer'
  assert_contains "${RUN_OUTPUT}" 'area:api'
  [ ! -s "${GH_FAKE_LOG}" ] || fail 'dry-run invoked gh'

  capture "${TRACKER}" create --title Test --body Body --sign 'Test Agent' --repo owner/project
  [ "${RUN_STATUS}" -ne 0 ] || fail 'outward create was accepted without --yes'
  assert_contains "${RUN_OUTPUT}" 're-run with --yes to confirm'
  [ ! -s "${GH_FAKE_LOG}" ] || fail 'confirmation failure invoked gh'
}

test_repository_discovery_prefers_upstream() {
  new_case
  local checkout="${CASE_DIR}/checkout"
  git init -q "${checkout}"
  git -C "${checkout}" remote add origin git@github.com:personal/fork.git
  git -C "${checkout}" remote add upstream https://github.com/canonical/project.git

  capture env -C "${checkout}" "${TRACKER}" repo
  assert_eq 0 "${RUN_STATUS}"
  assert_eq canonical/project "${RUN_OUTPUT}"
  [ ! -s "${GH_FAKE_LOG}" ] || fail 'repository discovery invoked gh despite a usable upstream'
}

test_signed_body_and_inline_image_composition() {
  new_case

  capture "${TRACKER}" create --title 'A title' --body 'A body' --sign 'Test Agent' \
    --repo owner/project --yes
  assert_eq 0 "${RUN_STATUS}"
  local body
  body="$(cat "${GH_CAPTURE_BODY}")"
  assert_contains "${body}" 'A body'
  assert_contains "${body}" '_— posted by Test Agent (via the issue-tracker skill)_'

  local image_path="${CASE_DIR}/shot with spaces.png"
  printf '%s' 'not-a-real-png' >"${image_path}"
  capture "${TRACKER}" comment 7 --body "before ![shot](${image_path}) after" \
    --image "${image_path}" --sign 'Test Agent' --repo owner/project --yes
  assert_eq 0 "${RUN_STATUS}"
  body="$(cat "${GH_CAPTURE_BODY}")"
  assert_contains "${body}" 'before ![shot](https://github.com/user-attachments/assets/fake-upload) after'
  assert_not_contains "${body}" "${image_path}"
  assert_contains "${body}" '_— posted by Test Agent (via the issue-tracker skill)_'
}

test_status_and_area_read_failure_precedes_writes() {
  new_case
  export GH_FAKE_MODE=fail-label-read

  capture "${TRACKER}" status 12 --set resolved --repo owner/project --yes
  [ "${RUN_STATUS}" -ne 0 ] || fail 'status succeeded after its label read failed'
  assert_contains "${RUN_OUTPUT}" 'status was not changed'
  local log
  log="$(cat "${GH_FAKE_LOG}")"
  assert_contains "${log}" 'issue view'
  assert_not_contains "${log}" 'label create'
  assert_not_contains "${log}" 'issue edit'

  : >"${GH_FAKE_LOG}"
  capture "${TRACKER}" area 12 --set api --repo owner/project --yes
  [ "${RUN_STATUS}" -ne 0 ] || fail 'area --set succeeded after its label read failed'
  assert_contains "${RUN_OUTPUT}" 'areas were not changed'
  log="$(cat "${GH_FAKE_LOG}")"
  assert_contains "${log}" 'issue view'
  assert_not_contains "${log}" 'label create'
  assert_not_contains "${log}" 'issue edit'
}

test_managed_label_replacement() {
  new_case
  export GH_FAKE_LABELS=$'triage\nunrelated'
  capture "${TRACKER}" status 14 --set resolved --repo owner/project --yes
  assert_eq 0 "${RUN_STATUS}"
  local log
  log="$(cat "${GH_FAKE_LOG}")"
  assert_contains "${log}" 'label create resolved'
  assert_contains "${log}" 'issue edit 14'
  assert_contains "${log}" '--remove-label triage'

  : >"${GH_FAKE_LOG}"
  export GH_FAKE_LABELS=$'area:old\nunrelated'
  capture "${TRACKER}" area 14 --set api --repo owner/project --yes
  assert_eq 0 "${RUN_STATUS}"
  log="$(cat "${GH_FAKE_LOG}")"
  assert_contains "${log}" 'label create area:api'
  assert_contains "${log}" '--remove-label area:old'
  assert_not_contains "${log}" '--remove-label unrelated'
}

test_view_caches_attachments_without_token_in_arguments() {
  new_case
  export GH_FAKE_JSON='{"number":5,"title":"Attachments","state":"OPEN","labels":[],"author":{"login":"reporter"},"assignees":[],"milestone":null,"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","url":"https://github.com/owner/project/issues/5","body":"![trusted](https://github.com/user-attachments/assets/abc)\\n![external](https://example.test/screenshot.png)","comments":[]}'
  local cache_dir="${CASE_DIR}/cache"

  capture "${TRACKER}" view 5 --repo owner/project --dir "${cache_dir}"
  assert_eq 0 "${RUN_STATUS}"
  [ -s "${cache_dir}/issue.json" ] || fail 'issue.json was not cached'
  [ -s "${cache_dir}/issue.md" ] || fail 'issue.md was not cached'
  local attachment_count
  attachment_count="$(find "${cache_dir}" -maxdepth 1 -name 'issue-5-*.bin' -type f | wc -l | tr -d ' ')"
  assert_eq 2 "${attachment_count}"

  local curl_log
  curl_log="$(cat "${CURL_FAKE_LOG}")"
  assert_contains "${curl_log}" '--header @-'
  assert_contains "${curl_log}" 'https://example.test/screenshot.png'
  assert_not_contains "${curl_log}" 'fake-secret-token'
}

printf 'issue-tracker tests\n'
run_test 'validates dry runs, signatures, and write confirmation' test_validation_dry_run_and_gate
run_test 'discovers the canonical upstream repository first' test_repository_discovery_prefers_upstream
run_test 'composes signed plain and inline-image bodies' test_signed_body_and_inline_image_composition
run_test 'aborts status/area replacement when label reads fail' test_status_and_area_read_failure_precedes_writes
run_test 'replaces only managed status and area labels' test_managed_label_replacement
run_test 'caches attachments without tokens in curl arguments' test_view_caches_attachments_without_token_in_arguments

if [ "${FAILED}" -ne 0 ]; then
  printf '%d/%d issue-tracker tests failed\n' "${FAILED}" "${TOTAL}" >&2
  exit 1
fi
printf '%d issue-tracker tests passed\n' "${TOTAL}"
