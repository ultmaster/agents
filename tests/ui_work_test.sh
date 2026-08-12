#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
UI_SCRIPTS="${REPO_ROOT}/skills/ui-work/scripts"
LAUNCH="${UI_SCRIPTS}/launch.sh"
TEARDOWN="${UI_SCRIPTS}/teardown.sh"
CHROME_RECOVER="${UI_SCRIPTS}/chrome-recover.sh"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ui-verifier-test.XXXXXX")"
cleanup() {
  rm -rf "${TEST_ROOT}"
}
trap cleanup EXIT

mkdir -p "${TEST_ROOT}/bin" "${TEST_ROOT}/home" "${TEST_ROOT}/tmp"
export HOME="${TEST_ROOT}/home"
export TMPDIR="${TEST_ROOT}/tmp"
export PATH="${TEST_ROOT}/bin:/usr/local/bin:/usr/bin:/bin"
export NO_PROXY='127.0.0.1,localhost'
unset UI_VERIFIER_RUN_ID HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy

TOTAL=0
FAILED=0
RUN_OUTPUT=''
RUN_STATUS=0
CASE_DIR=''
OWNED_GROUPS=()

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

free_port() {
  /usr/bin/python3 - <<'PY'
import socket

with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
}

wait_for_http() {
  local url=$1 owner_pid=$2
  for _ in $(seq 1 100); do
    /usr/bin/curl -fsS --max-time 1 "${url}" >/dev/null 2>&1 && return 0
    kill -0 "${owner_pid}" 2>/dev/null || return 1
    sleep 0.05
  done
  return 1
}

process_id() {
  local pid=$1 line rest
  IFS= read -r line <"/proc/${pid}/stat" || return 1
  rest=${line##*) }
  awk '{print $20}' <<<"${rest}"
}

cleanup_case() {
  local state group
  if [ -n "${CASE_DIR:-}" ] && [ -d "${CASE_DIR}" ]; then
    for state in "${CASE_DIR}"/*.state; do
      [ -e "${state}" ] || continue
      "${TEARDOWN}" --state "${state}" >/dev/null 2>&1 || true
    done
  fi
  for group in "${OWNED_GROUPS[@]:-}"; do
    [[ "${group}" =~ ^[1-9][0-9]*$ ]] || continue
    kill -TERM -- "-${group}" 2>/dev/null || true
  done
  sleep 0.05
  for group in "${OWNED_GROUPS[@]:-}"; do
    [[ "${group}" =~ ^[1-9][0-9]*$ ]] || continue
    kill -KILL -- "-${group}" 2>/dev/null || true
  done
}

new_case() {
  CASE_DIR="$(mktemp -d "${TEST_ROOT}/tmp/case.XXXXXX")"
  OWNED_GROUPS=()
  trap cleanup_case EXIT
}

track_group() {
  OWNED_GROUPS+=("$1")
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

test_validation_and_dry_run() {
  new_case
  local state="${CASE_DIR}/app.state" log="${CASE_DIR}/app.log" port
  port="$(free_port)"

  capture "${LAUNCH}" --command true --port 70000 --health-url http://127.0.0.1:70000 --dry-run
  [ "${RUN_STATUS}" -ne 0 ] || fail 'out-of-range port was accepted'
  assert_contains "${RUN_OUTPUT}" 'port out of range'

  capture "${LAUNCH}" --command true --port "${port}" --health-url "file:///tmp/health" --dry-run
  [ "${RUN_STATUS}" -ne 0 ] || fail 'non-HTTP health URL was accepted'
  assert_contains "${RUN_OUTPUT}" 'health URL must use http:// or https://'

  capture "${LAUNCH}" --command true --port "${port}" --health-url "http://127.0.0.1:${port}/" \
    --state "${state}" --log "${log}" --timeout 2 --dry-run
  assert_eq 0 "${RUN_STATUS}"
  assert_contains "${RUN_OUTPUT}" 'dry run; no process will be launched'
  [ ! -e "${state}" ] || fail 'dry-run created a state file'
  [ ! -e "${log}" ] || fail 'dry-run created a log file'

  capture "${TEARDOWN}" --state "${CASE_DIR}/absent.state"
  assert_eq 0 "${RUN_STATUS}"
  assert_contains "${RUN_OUTPUT}" 'nothing to tear down'
}

test_launch_and_teardown_real_loopback_app() {
  new_case
  local port state log docroot command launch_pid
  port="$(free_port)"
  state="${CASE_DIR}/app.state"
  log="${CASE_DIR}/app.log"
  docroot="${CASE_DIR}/www"
  mkdir -p "${docroot}"
  printf '%s\n' 'ui-verifier-ready' >"${docroot}/index.html"
  printf -v command 'exec /usr/bin/python3 -m http.server %q --bind 127.0.0.1 --directory %q' "${port}" "${docroot}"

  capture "${LAUNCH}" --command "${command}" --cwd "${CASE_DIR}" --port "${port}" \
    --health-url "http://127.0.0.1:${port}/" --state "${state}" --log "${log}" --timeout 10
  [ "${RUN_STATUS}" -eq 0 ] || fail "launch failed: ${RUN_OUTPUT}"
  assert_contains "${RUN_OUTPUT}" 'application ready'
  [ -s "${state}" ] || fail 'launch did not write state'
  [ -e "${log}" ] || fail 'launch did not reserve its log'
  launch_pid="$(awk -F= '$1 == "LAUNCH_PID" { print $2 }' "${state}")"
  [[ "${launch_pid}" =~ ^[1-9][0-9]*$ ]] || fail 'state lacks a valid launcher PID'
  track_group "${launch_pid}"
  assert_eq ui-verifier-ready "$(/usr/bin/curl -fsS "http://127.0.0.1:${port}/" | tr -d '\r\n')"

  capture "${TEARDOWN}" --state "${state}"
  [ "${RUN_STATUS}" -eq 0 ] || fail "teardown failed: ${RUN_OUTPUT}"
  assert_contains "${RUN_OUTPUT}" 'owned processes stopped'
  [ ! -e "${state}" ] || fail 'teardown retained successful state'
  ! kill -0 "${launch_pid}" 2>/dev/null || fail 'launcher survived teardown'
  ! /usr/bin/curl -fsS --max-time 1 "http://127.0.0.1:${port}/" >/dev/null 2>&1 || fail 'port still served after teardown'
}

test_failed_startup_cleans_owned_process_and_state() {
  new_case
  local port state log pid_file command launched_pid
  port="$(free_port)"
  state="${CASE_DIR}/failed.state"
  log="${CASE_DIR}/failed.log"
  pid_file="${CASE_DIR}/launched.pid"
  command='printf "%s\n" "$$" > '"$(printf '%q' "${pid_file}")"'; exec /usr/bin/sleep 30'

  capture "${LAUNCH}" --command "${command}" --port "${port}" \
    --health-url "http://127.0.0.1:${port}/" --state "${state}" --log "${log}" --timeout 1
  [ "${RUN_STATUS}" -ne 0 ] || fail 'unhealthy command unexpectedly became ready'
  assert_contains "${RUN_OUTPUT}" 'health checks did not pass within 1 seconds'
  [ ! -e "${state}" ] || fail 'failed launch retained its state file'
  [ -s "${pid_file}" ] || fail 'test command did not record its PID'
  launched_pid="$(cat "${pid_file}")"
  [[ "${launched_pid}" =~ ^[1-9][0-9]*$ ]] || fail 'test command recorded an invalid PID'
  ! kill -0 "${launched_pid}" 2>/dev/null || fail 'failed launch left its process running'
}

test_occupied_port_is_refused_without_harming_owner() {
  new_case
  local port owner_pid state log docroot
  port="$(free_port)"
  state="${CASE_DIR}/occupied.state"
  log="${CASE_DIR}/occupied.log"
  docroot="${CASE_DIR}/owner"
  mkdir -p "${docroot}"
  printf '%s\n' owner >"${docroot}/index.html"

  setsid /usr/bin/python3 -m http.server "${port}" --bind 127.0.0.1 --directory "${docroot}" \
    >"${CASE_DIR}/owner.log" 2>&1 &
  owner_pid=$!
  track_group "${owner_pid}"
  wait_for_http "http://127.0.0.1:${port}/" "${owner_pid}" || fail 'test owner did not start'

  capture "${LAUNCH}" --command true --port "${port}" --health-url "http://127.0.0.1:${port}/" \
    --state "${state}" --log "${log}" --dry-run
  [ "${RUN_STATUS}" -ne 0 ] || fail 'occupied port was accepted'
  assert_contains "${RUN_OUTPUT}" "port ${port} is already occupied"
  kill -0 "${owner_pid}" 2>/dev/null || fail 'occupied-port check stopped the existing owner'
  assert_eq owner "$(/usr/bin/curl -fsS "http://127.0.0.1:${port}/" | tr -d '\r\n')"
  [ ! -e "${state}" ] || fail 'occupied-port failure created state'
}

test_forged_state_never_signals_unowned_process() {
  new_case
  local sleeper_pid state start_id port
  setsid /usr/bin/sleep 30 &
  sleeper_pid=$!
  track_group "${sleeper_pid}"
  sleep 0.05
  start_id="$(process_id "${sleeper_pid}")"
  port="$(free_port)"
  state="${CASE_DIR}/forged.state"
  {
    printf 'VERSION=1\nRUN_ID=forged-run\n'
    printf 'LAUNCH_PID=%s\nLAUNCH_ID=%s\nPGID=%s\n' "${sleeper_pid}" "${start_id}" "${sleeper_pid}"
    printf 'CWD=%s\nLOG=%s\nPORT=%s\nHEALTH_URL=http://127.0.0.1:%s/\n' \
      "${CASE_DIR}" "${CASE_DIR}/forged.log" "${port}" "${port}"
  } >"${state}"

  capture "${TEARDOWN}" --state "${state}"
  [ "${RUN_STATUS}" -ne 0 ] || fail 'forged state was accepted'
  assert_contains "${RUN_OUTPUT}" 'lacks the recorded run token; refusing to signal'
  kill -0 "${sleeper_pid}" 2>/dev/null || fail 'forged state caused an unowned process to be stopped'
  [ -e "${state}" ] || fail 'unsafe state was removed despite refusal'
}

test_chrome_recovery_canonical_root_and_exact_profiles() {
  new_case
  capture "${CHROME_RECOVER}" --profile /tmp/.. --dry-run
  [ "${RUN_STATUS}" -ne 0 ] || fail 'canonical alias of root was accepted as a profile'
  assert_contains "${RUN_OUTPUT}" 'refusing the filesystem root as a profile'

  local chrome profile nearby exact_a exact_b near_pid dry_output
  chrome="${CASE_DIR}/chrome"
  profile="${CASE_DIR}/profile"
  nearby="${CASE_DIR}/profile-nearby"
  mkdir -p "${profile}" "${nearby}"
  # `yes` accepts arbitrary operands, has no children, and takes the symlink's
  # basename as its Linux comm value. It is therefore an exact, test-owned
  # Chrome-shaped process without compiling a fixture binary.
  ln -s /usr/bin/yes "${chrome}"

  setsid "${chrome}" -- --user-data-dir "${profile}" >/dev/null 2>&1 &
  exact_a=$!
  track_group "${exact_a}"
  setsid "${chrome}" -- "--user-data-dir=${profile}" >/dev/null 2>&1 &
  exact_b=$!
  track_group "${exact_b}"
  setsid "${chrome}" -- "--user-data-dir=${nearby}" >/dev/null 2>&1 &
  near_pid=$!
  track_group "${near_pid}"
  sleep 0.1

  capture "${CHROME_RECOVER}" --profile "${profile}" --dry-run
  assert_eq 0 "${RUN_STATUS}"
  dry_output=${RUN_OUTPUT}
  assert_contains "${dry_output}" "${exact_a}"
  assert_contains "${dry_output}" "${exact_b}"
  assert_not_contains "${dry_output}" "${near_pid}"

  capture "${CHROME_RECOVER}" --profile "${profile}"
  [ "${RUN_STATUS}" -eq 0 ] || fail "exact-profile recovery failed: ${RUN_OUTPUT}"
  ! kill -0 "${exact_a}" 2>/dev/null || fail 'separate-argument profile process survived recovery'
  ! kill -0 "${exact_b}" 2>/dev/null || fail 'equals-form profile process survived recovery'
  kill -0 "${near_pid}" 2>/dev/null || fail 'nearby-profile process was incorrectly stopped'
}

printf 'ui-verifier tests\n'
run_test 'validates launch input and keeps dry runs side-effect free' test_validation_and_dry_run
run_test 'launches and tears down a real loopback application' test_launch_and_teardown_real_loopback_app
run_test 'cleans process and state after failed startup' test_failed_startup_cleans_owned_process_and_state
run_test 'refuses occupied ports without harming their owner' test_occupied_port_is_refused_without_harming_owner
run_test 'refuses forged state without signaling its process' test_forged_state_never_signals_unowned_process
run_test 'matches exact Chrome profiles and rejects canonical root' test_chrome_recovery_canonical_root_and_exact_profiles

if [ "${FAILED}" -ne 0 ]; then
  printf '%d/%d ui-verifier tests failed\n' "${FAILED}" "${TOTAL}" >&2
  exit 1
fi
printf '%d ui-verifier tests passed\n' "${TOTAL}"
