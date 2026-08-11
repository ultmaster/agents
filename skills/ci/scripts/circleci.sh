#!/usr/bin/env bash
set -euo pipefail

# Repository-agnostic CircleCI operator. Project and branch are explicit or
# derived from git. Every trigger or mutation requires --yes.

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
skill_root="$(cd -- "${script_dir}/.." && pwd)"
readonly skill_root
readonly env_file="${skill_root}/.env"

readonly CIRCLE_API_DEFAULT="https://circleci.com/api/v2"
readonly CIRCLE_API_V1_DEFAULT="https://circleci.com/api/v1.1"

dry_run=0
assume_yes=0
project_override=""
remote_override="${CI_REMOTE:-}"
REMAINING=()

usage() {
  cat <<'USAGE'
Usage: circleci.sh <command> [options]

Trigger commands (require --yes unless --dry-run):
  trigger [options]              Trigger the repository's default pipeline.
  tests [selectors]              Trigger tests using discovered run_* parameters.

Read-only triage commands:
  list [options]                 List recent pipelines.
  await <pipeline-id>            Poll a pipeline to a terminal state.
  watch <pipeline-id>            Alias for await.
  view <pipeline-id>             List a pipeline's workflows.
  status <pipeline-id>           Alias for view.
  jobs <workflow-id>             List a workflow's jobs.
  job <job-number>               Show step status and log URLs when supported.
  definitions                    List pipeline definitions.

Write commands (require --yes unless --dry-run):
  cancel <workflow-id>           Cancel a running workflow.
  delete-definition <name|id>    Delete a pipeline definition.

Selection options (accepted by every command):
  --project VCS/OWNER/REPO        CircleCI slug, for example gh/owner/repo.
  --remote NAME                   Git remote used for project discovery.

Trigger options:
  --branch REF                    Branch to trigger.
  --parameter KEY=VALUE           Pipeline parameter; repeatable.
  --parameters-json OBJECT        Exact JSON object of pipeline parameters.
  --watch                         Wait for the triggered pipeline.
  --yes                           Confirm the outward action.
  --dry-run                       Print the API request without credentials/network.

tests selectors:
  --all                           Use run_tests=true when declared by local config.
  --module NAME                   Use run_NAME=true when declared; repeatable.

Environment overrides:
  CIRCLECI_TOKEN, CIRCLECI_PROJECT_SLUG, CIRCLECI_PROJECT_V1,
  CI_REMOTE, CI_BRANCH, CIRCLECI_API, CIRCLECI_API_V1

Examples:
  circleci.sh trigger --branch feature/name --parameter smoke=true --dry-run
  circleci.sh tests --branch feature/name --module api --dry-run
  circleci.sh list --branch feature/name --project gh/owner/repo --dry-run
  circleci.sh cancel <workflow-id> --dry-run
USAGE
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '==> %s\n' "$*"
}

print_command() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
}

require_jq() {
  command -v jq >/dev/null 2>&1 || die "jq is required for CircleCI JSON handling"
}

require_curl() {
  command -v curl >/dev/null 2>&1 || die "curl is required for CircleCI API operations"
}

require_confirmation() {
  ((dry_run)) && return 0
  ((assume_yes)) && return 0
  die "$1 changes remote CI state and may consume CI capacity; re-run with --yes (or --dry-run to preview)"
}

parse_common_options() {
  REMAINING=()
  while (($#)); do
    case "$1" in
      --project)
        shift
        (($#)) || die "--project requires a value"
        project_override="$1"
        ;;
      --project=*) project_override="${1#*=}" ;;
      --remote)
        shift
        (($#)) || die "--remote requires a value"
        remote_override="$1"
        ;;
      --remote=*) remote_override="${1#*=}" ;;
      *) REMAINING+=("$1") ;;
    esac
    shift
  done
}

# Load only known literal KEY=VALUE entries. Never eval a credential file.
load_env_file() {
  [[ -f "${env_file}" ]] || return 0
  local line key value
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -n "${line}" && "${line}" != \#* ]] || continue
    [[ "${line}" == export\ * ]] && line="${line#export }"
    [[ "${line}" == *=* ]] || continue
    key="${line%%=*}"
    value="${line#*=}"
    key="${key%"${key##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if [[ "${value}" == \"*\" && "${value}" == *\" ]]; then
      value="${value#\"}"
      value="${value%\"}"
    elif [[ "${value}" == \'*\' && "${value}" == *\' ]]; then
      value="${value#\'}"
      value="${value%\'}"
    fi
    case "${key}" in
      CIRCLECI_TOKEN) [[ -n "${CIRCLECI_TOKEN:-}" ]] || CIRCLECI_TOKEN="${value}" ;;
      CIRCLECI_PROJECT_SLUG) [[ -n "${CIRCLECI_PROJECT_SLUG:-}" ]] || CIRCLECI_PROJECT_SLUG="${value}" ;;
      CIRCLECI_PROJECT_V1) [[ -n "${CIRCLECI_PROJECT_V1:-}" ]] || CIRCLECI_PROJECT_V1="${value}" ;;
      CI_REMOTE) [[ -n "${CI_REMOTE:-}" ]] || CI_REMOTE="${value}" ;;
      CI_BRANCH) [[ -n "${CI_BRANCH:-}" ]] || CI_BRANCH="${value}" ;;
    esac
  done < "${env_file}"
  [[ -n "${remote_override}" ]] || remote_override="${CI_REMOTE:-}"
}

require_token() {
  [[ -n "${CIRCLECI_TOKEN:-}" ]] ||
    die "CIRCLECI_TOKEN is unset; export it or copy ${skill_root}/.env.example to ${env_file} and fill the local .env"
}

# Feed the credential as a header on stdin so it never appears in curl's argv.
circle_curl() {
  [[ -n "${CIRCLECI_TOKEN:-}" ]] || die "CIRCLECI_TOKEN is unset"
  printf 'Circle-Token: %s\n' "${CIRCLECI_TOKEN}" | curl --header @- "$@"
}

selected_remote() {
  if [[ -n "${remote_override}" ]]; then
    git remote get-url "${remote_override}" >/dev/null 2>&1 ||
      die "git remote '${remote_override}' does not exist"
    printf '%s\n' "${remote_override}"
    return 0
  fi
  if git remote get-url upstream >/dev/null 2>&1; then
    printf 'upstream\n'
  elif git remote get-url origin >/dev/null 2>&1; then
    printf 'origin\n'
  else
    git remote 2>/dev/null | sed -n '1p'
  fi
}

circle_project_from_value() {
  local value="$1" host="" path="" rest="" vcs=""
  value="${value%/}"
  value="${value%.git}"
  case "${value}" in
    gh/*/* | bb/*/* | gl/*/*) printf '%s\n' "${value}"; return 0 ;;
    github/*/*) printf 'gh/%s\n' "${value#github/}"; return 0 ;;
    bitbucket/*/*) printf 'bb/%s\n' "${value#bitbucket/}"; return 0 ;;
    git@*:* )
      host="${value#git@}"
      host="${host%%:*}"
      path="${value#*:}"
      ;;
    ssh://* | https://* | http://* )
      rest="${value#*://}"
      rest="${rest#*@}"
      host="${rest%%/*}"
      path="${rest#*/}"
      ;;
    *) return 1 ;;
  esac
  path="${path#/}"
  path="${path%.git}"
  [[ "${path}" == */* && "${path}" != */*/* ]] || return 1
  case "${host}" in
    github.com) vcs="gh" ;;
    bitbucket.org) vcs="bb" ;;
    gitlab.com) vcs="gl" ;;
    *) return 1 ;;
  esac
  printf '%s/%s\n' "${vcs}" "${path}"
}

resolve_project() {
  local value="${project_override:-${CIRCLECI_PROJECT_SLUG:-}}" remote url
  if [[ -n "${value}" ]]; then
    circle_project_from_value "${value}" ||
      die "cannot parse CircleCI project '${value}'; expected gh/owner/repository or a known VCS URL"
    return 0
  fi
  remote="$(selected_remote)"
  [[ -n "${remote}" ]] || die "cannot discover a git remote; pass --project VCS/OWNER/REPO"
  url="$(git remote get-url "${remote}")"
  circle_project_from_value "${url}" ||
    die "cannot derive a CircleCI slug from remote '${remote}'; pass --project"
}

resolve_project_v1() {
  if [[ -n "${CIRCLECI_PROJECT_V1:-}" ]]; then
    printf '%s\n' "${CIRCLECI_PROJECT_V1}"
    return 0
  fi
  local project="$1"
  case "${project}" in
    gh/*) printf 'github/%s\n' "${project#gh/}" ;;
    bb/*) printf 'bitbucket/%s\n' "${project#bb/}" ;;
    *) die "job detail needs CIRCLECI_PROJECT_V1 for project '${project}'" ;;
  esac
}

default_branch() {
  if [[ -n "${CI_BRANCH:-}" ]]; then
    printf '%s\n' "${CI_BRANCH}"
    return 0
  fi
  local branch remote ref
  branch="$(git branch --show-current 2>/dev/null || true)"
  if [[ -n "${branch}" ]]; then
    printf '%s\n' "${branch}"
    return 0
  fi
  remote="$(selected_remote)"
  [[ -n "${remote}" ]] || return 1
  ref="$(git symbolic-ref --quiet --short "refs/remotes/${remote}/HEAD" 2>/dev/null || true)"
  [[ -n "${ref}" ]] || return 1
  printf '%s\n' "${ref#${remote}/}"
}

circle_config() {
  local root
  root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "${root}" ]] || return 1
  if [[ -f "${root}/.circleci/config.yml" ]]; then
    printf '%s\n' "${root}/.circleci/config.yml"
  elif [[ -f "${root}/.circleci/config.yaml" ]]; then
    printf '%s\n' "${root}/.circleci/config.yaml"
  else
    return 1
  fi
}

config_declares_parameter() {
  local name="$1" config
  [[ "${name}" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || return 1
  config="$(circle_config)" || return 1
  awk -v want="${name}" '
    /^parameters:[[:space:]]*(#.*)?$/ { in_parameters=1; next }
    in_parameters && /^[^[:space:]#]/ { in_parameters=0 }
    in_parameters && $0 ~ "^[[:space:]][[:space:]]" want ":[[:space:]]*" { found=1 }
    END { exit(found ? 0 : 1) }
  ' "${config}"
}

json_value() {
  local value="$1"
  jq -cn --arg value "${value}" '
    if $value == "true" then true
    elif $value == "false" then false
    elif $value == "null" then null
    elif ($value | test("^-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?$")) then ($value | tonumber)
    else $value
    end
  '
}

add_parameter() {
  local object="$1" pair="$2" key value encoded
  [[ "${pair}" == *=* ]] || die "--parameter requires KEY=VALUE"
  key="${pair%%=*}"
  value="${pair#*=}"
  [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || die "invalid pipeline parameter name '${key}'"
  encoded="$(json_value "${value}")"
  jq -cn --argjson object "${object}" --arg key "${key}" --argjson value "${encoded}" \
    '$object + {($key): $value}'
}

api_v2() {
  printf '%s\n' "${CIRCLECI_API:-${CIRCLE_API_DEFAULT}}"
}

api_v1() {
  printf '%s\n' "${CIRCLECI_API_V1:-${CIRCLE_API_V1_DEFAULT}}"
}

pipeline_ui() {
  local project="$1" v1
  if [[ -n "${CIRCLECI_UI_URL:-}" ]]; then
    printf '%s\n' "${CIRCLECI_UI_URL}"
    return 0
  fi
  v1="$(resolve_project_v1 "${project}" 2>/dev/null || true)"
  if [[ -n "${v1}" ]]; then
    printf 'https://app.circleci.com/pipelines/%s\n' "${v1}"
  else
    printf 'https://app.circleci.com/pipelines\n'
  fi
}

prepare_live() {
  require_curl
  require_jq
  load_env_file
  require_token
}

trigger_pipeline() {
  local branch="$1" parameters="$2" watch="$3" timeout="$4" interval="$5"
  require_confirmation "trigger"
  require_jq
  if ((!dry_run)); then
    prepare_live
  fi
  [[ -n "${branch}" ]] || branch="${CI_BRANCH:-}"
  [[ -n "${branch}" ]] ||
    die "trigger requires an explicit --branch (or CI_BRANCH); do not infer a mutation ref across fork/upstream remotes"
  local project payload url pipeline_id body
  project="$(resolve_project)"
  payload="$(jq -cn --arg branch "${branch}" --argjson parameters "${parameters}" \
    '{branch:$branch, parameters:$parameters}')"
  url="$(api_v2)/project/${project}/pipeline"
  log "CircleCI project=${project} branch=${branch} parameters=${parameters}"
  if ((dry_run)); then
    print_command curl -X POST -H 'Circle-Token: <redacted>' -H 'Content-Type: application/json' --data "${payload}" "${url}"
    ((watch)) && log "(dry-run) would watch the returned pipeline id"
    return 0
  fi
  body="$(circle_curl -sS -X POST -H 'Content-Type: application/json' \
    --data "${payload}" "${url}")"
  pipeline_id="$(printf '%s' "${body}" | jq -r '.id // empty')"
  [[ -n "${pipeline_id}" ]] || die "CircleCI did not return a pipeline id: ${body}"
  log "pipeline=${pipeline_id} $(pipeline_ui "${project}")"
  ((watch)) && watch_pipeline "${pipeline_id}" "${timeout}" "${interval}"
}

watch_pipeline() {
  local pipeline_id="$1" timeout="${2:-3600}" interval="${3:-15}"
  [[ "${timeout}" =~ ^[0-9]+$ && "${interval}" =~ ^[1-9][0-9]*$ ]] ||
    die "timeout and interval must be non-negative/positive integer seconds"
  if ((dry_run)); then
    print_command curl -H 'Circle-Token: <redacted>' "$(api_v2)/pipeline/${pipeline_id}/workflow"
    return 0
  fi
  prepare_live
  local elapsed=0 body statuses status pending bad
  while ((elapsed <= timeout)); do
    body="$(circle_curl -sS "$(api_v2)/pipeline/${pipeline_id}/workflow")"
    statuses="$(printf '%s' "${body}" | jq -r '.items[]?.status')"
    if [[ -n "${statuses}" ]]; then
      pending=0
      bad=0
      while IFS= read -r status; do
        printf '    %s\n' "${status}"
        case "${status}" in
          running | failing | on_hold | created | pending | new | queued) pending=1 ;;
          success) ;;
          *) bad=1 ;;
        esac
      done <<< "${statuses}"
      if ((pending == 0)); then
        ((bad == 0)) && return 0
        return 1
      fi
    fi
    ((elapsed == timeout)) && break
    sleep "${interval}"
    elapsed=$((elapsed + interval))
  done
  die "timed out after ${timeout}s watching pipeline ${pipeline_id}"
}

cmd_trigger() {
  dry_run=0
  assume_yes=0
  local branch="" watch=0 timeout=3600 interval=15 parameters='{}' exact_json="" pair
  local -a pairs=()
  while (($#)); do
    case "$1" in
      --branch | --ref | -b)
        shift
        (($#)) || die "--branch requires a value"
        branch="$1"
        ;;
      --parameter | -p)
        shift
        (($#)) || die "--parameter requires KEY=VALUE"
        pairs+=("$1")
        ;;
      --parameters-json)
        shift
        (($#)) || die "--parameters-json requires an object"
        exact_json="$1"
        ;;
      --watch) watch=1 ;;
      --timeout)
        shift
        (($#)) || die "--timeout requires seconds"
        timeout="$1"
        ;;
      --interval)
        shift
        (($#)) || die "--interval requires seconds"
        interval="$1"
        ;;
      --yes) assume_yes=1 ;;
      --dry-run) dry_run=1 ;;
      -h | --help)
        printf '%s\n' 'Usage: circleci.sh trigger [--branch REF] [--parameter KEY=VALUE ... | --parameters-json OBJECT] [--watch] --yes'
        return 0
        ;;
      *) die "unknown trigger option: $1" ;;
    esac
    shift
  done
  require_jq
  if [[ -n "${exact_json}" ]]; then
    ((${#pairs[@]} == 0)) || die "combine neither --parameters-json nor --parameter"
    parameters="$(printf '%s' "${exact_json}" | jq -ce 'select(type == "object")')" ||
      die "--parameters-json must be a valid JSON object"
  else
    for pair in "${pairs[@]}"; do
      parameters="$(add_parameter "${parameters}" "${pair}")"
    done
  fi
  trigger_pipeline "${branch}" "${parameters}" "${watch}" "${timeout}" "${interval}"
}

cmd_tests() {
  dry_run=0
  assume_yes=0
  local branch="" watch=0 timeout=3600 interval=15 all=0 parameters='{}' module pair param
  local -a modules=() pairs=()
  while (($#)); do
    case "$1" in
      --all) all=1 ;;
      --module | -m)
        shift
        (($#)) || die "--module requires a value"
        modules+=("$1")
        ;;
      --parameter | -p)
        shift
        (($#)) || die "--parameter requires KEY=VALUE"
        pairs+=("$1")
        ;;
      --branch | --ref | -b)
        shift
        (($#)) || die "--branch requires a value"
        branch="$1"
        ;;
      --watch) watch=1 ;;
      --timeout)
        shift
        (($#)) || die "--timeout requires seconds"
        timeout="$1"
        ;;
      --interval)
        shift
        (($#)) || die "--interval requires seconds"
        interval="$1"
        ;;
      --yes) assume_yes=1 ;;
      --dry-run) dry_run=1 ;;
      -h | --help)
        printf '%s\n' 'Usage: circleci.sh tests [--all | --module NAME ...] [--parameter KEY=VALUE ...] [--branch REF] --yes'
        return 0
        ;;
      *) die "unknown tests option: $1" ;;
    esac
    shift
  done
  require_jq
  circle_config >/dev/null ||
    die "tests requires a local .circleci/config.yml or config.yaml; use trigger for a configless/manual pipeline call"
  if ((all)) && ! config_declares_parameter run_tests; then
    die "--all requires the local CircleCI config to declare the run_tests pipeline parameter"
  fi
  if ((${#modules[@]})); then
    for module in "${modules[@]}"; do
      module="${module//-/_}"
      [[ "${module}" =~ ^[A-Za-z0-9_]+$ ]] || die "invalid module selector '${module}'"
      param="run_${module}"
      config_declares_parameter "${param}" ||
        die "local CircleCI config does not declare '${param}'; use trigger --parameter KEY=VALUE"
      parameters="$(add_parameter "${parameters}" "${param}=true")"
    done
  elif ((all)) || config_declares_parameter run_tests; then
    parameters="$(add_parameter "${parameters}" 'run_tests=true')"
  fi
  for pair in "${pairs[@]}"; do
    parameters="$(add_parameter "${parameters}" "${pair}")"
  done
  trigger_pipeline "${branch}" "${parameters}" "${watch}" "${timeout}" "${interval}"
}

cmd_list() {
  dry_run=0
  local branch="" limit=10 branch_set=0
  while (($#)); do
    case "$1" in
      --branch | --ref | -b)
        shift
        (($#)) || die "--branch requires a value"
        branch="$1"
        branch_set=1
        ;;
      --limit | -n)
        shift
        (($#)) || die "--limit requires a value"
        limit="$1"
        ;;
      --dry-run) dry_run=1 ;;
      -h | --help)
        printf '%s\n' 'Usage: circleci.sh list [--branch REF] [--limit N] [--project SLUG] [--dry-run]'
        return 0
        ;;
      *) die "unknown list option: $1" ;;
    esac
    shift
  done
  [[ "${limit}" =~ ^[1-9][0-9]*$ ]] || die "--limit must be a positive integer"
  if ((!dry_run)); then prepare_live; else require_jq; fi
  ((branch_set)) || branch="$(default_branch || true)"
  local project url body
  project="$(resolve_project)"
  url="$(api_v2)/project/${project}/pipeline"
  if ((dry_run)); then
    if [[ -n "${branch}" ]]; then
      print_command curl -G -H 'Circle-Token: <redacted>' --data-urlencode "branch=${branch}" "${url}"
    else
      print_command curl -G -H 'Circle-Token: <redacted>' "${url}"
    fi
    return 0
  fi
  if [[ -n "${branch}" ]]; then
    body="$(circle_curl -sS -G --data-urlencode "branch=${branch}" "${url}")"
  else
    body="$(circle_curl -sS -G "${url}")"
  fi
  printf '%s' "${body}" | jq -r --argjson limit "${limit}" '
    (.items // [])[:$limit][] |
    [.id, (.state // "-"), (.created_at // "-"), ((.vcs.revision // "-")[:12])] | @tsv
  '
}

cmd_await() {
  dry_run=0
  local pipeline_id="" timeout=3600 interval=15
  while (($#)); do
    case "$1" in
      --timeout)
        shift
        (($#)) || die "--timeout requires seconds"
        timeout="$1"
        ;;
      --interval)
        shift
        (($#)) || die "--interval requires seconds"
        interval="$1"
        ;;
      --dry-run) dry_run=1 ;;
      -h | --help)
        printf '%s\n' 'Usage: circleci.sh await <pipeline-id> [--timeout SEC] [--dry-run]'
        return 0
        ;;
      -*) die "unknown await option: $1" ;;
      *)
        [[ -z "${pipeline_id}" ]] || die "await takes one pipeline id"
        pipeline_id="$1"
        ;;
    esac
    shift
  done
  [[ -n "${pipeline_id}" ]] || die "await requires a pipeline id"
  watch_pipeline "${pipeline_id}" "${timeout}" "${interval}"
}

cmd_view() {
  dry_run=0
  local pipeline_id=""
  while (($#)); do
    case "$1" in
      --dry-run) dry_run=1 ;;
      -h | --help)
        printf '%s\n' 'Usage: circleci.sh view <pipeline-id> [--dry-run]'
        return 0
        ;;
      -*) die "unknown view option: $1" ;;
      *)
        [[ -z "${pipeline_id}" ]] || die "view takes one pipeline id"
        pipeline_id="$1"
        ;;
    esac
    shift
  done
  [[ -n "${pipeline_id}" ]] || die "view requires a pipeline id"
  local url="$(api_v2)/pipeline/${pipeline_id}/workflow"
  if ((dry_run)); then
    print_command curl -H 'Circle-Token: <redacted>' "${url}"
    return 0
  fi
  prepare_live
  circle_curl -sS "${url}" |
    jq -r '(.items // [])[] | [.name, .status, .id] | @tsv'
}

cmd_jobs() {
  dry_run=0
  local workflow_id=""
  while (($#)); do
    case "$1" in
      --dry-run) dry_run=1 ;;
      -h | --help)
        printf '%s\n' 'Usage: circleci.sh jobs <workflow-id> [--dry-run]'
        return 0
        ;;
      -*) die "unknown jobs option: $1" ;;
      *)
        [[ -z "${workflow_id}" ]] || die "jobs takes one workflow id"
        workflow_id="$1"
        ;;
    esac
    shift
  done
  [[ -n "${workflow_id}" ]] || die "jobs requires a workflow id"
  local url="$(api_v2)/workflow/${workflow_id}/job"
  if ((dry_run)); then
    print_command curl -H 'Circle-Token: <redacted>' "${url}"
    return 0
  fi
  prepare_live
  circle_curl -sS "${url}" |
    jq -r '(.items // [])[] | [(.job_number // "-"), .status, .name] | @tsv'
}

cmd_job() {
  dry_run=0
  local job_number=""
  while (($#)); do
    case "$1" in
      --dry-run) dry_run=1 ;;
      -h | --help)
        printf '%s\n' 'Usage: circleci.sh job <job-number> [--project SLUG] [--dry-run]'
        return 0
        ;;
      -*) die "unknown job option: $1" ;;
      *)
        [[ -z "${job_number}" ]] || die "job takes one job number"
        job_number="$1"
        ;;
    esac
    shift
  done
  [[ -n "${job_number}" ]] || die "job requires a job number"
  [[ "${job_number}" =~ ^[0-9]+$ ]] || die "job number must be numeric"
  if ((!dry_run)); then prepare_live; fi
  local project project_v1 url
  project="$(resolve_project)"
  project_v1="$(resolve_project_v1 "${project}")"
  url="$(api_v1)/project/${project_v1}/${job_number}"
  if ((dry_run)); then
    print_command curl -H 'Circle-Token: <redacted>' "${url}"
    return 0
  fi
  circle_curl -sS "${url}" | jq -r '
    (.steps // [])[] | .actions[]? |
    [.status, .name, (if .failed then (.output_url // "") else "" end)] | @tsv
  '
}

cmd_cancel() {
  dry_run=0
  assume_yes=0
  local workflow_id=""
  while (($#)); do
    case "$1" in
      --yes) assume_yes=1 ;;
      --dry-run) dry_run=1 ;;
      -h | --help)
        printf '%s\n' 'Usage: circleci.sh cancel <workflow-id> --yes'
        return 0
        ;;
      -*) die "unknown cancel option: $1" ;;
      *)
        [[ -z "${workflow_id}" ]] || die "cancel takes one workflow id"
        workflow_id="$1"
        ;;
    esac
    shift
  done
  [[ -n "${workflow_id}" ]] || die "cancel requires a workflow id"
  require_confirmation "cancel"
  local url="$(api_v2)/workflow/${workflow_id}/cancel"
  if ((dry_run)); then
    print_command curl -X POST -H 'Circle-Token: <redacted>' "${url}"
    return 0
  fi
  prepare_live
  circle_curl -sS -X POST "${url}" | jq .
}

resolve_project_id() {
  local project="$1" body id
  body="$(circle_curl -sS "$(api_v2)/project/${project}")"
  id="$(printf '%s' "${body}" | jq -r '.id // empty')"
  [[ -n "${id}" ]] || die "could not resolve CircleCI project id for ${project}"
  printf '%s\n' "${id}"
}

cmd_definitions() {
  dry_run=0
  while (($#)); do
    case "$1" in
      --dry-run) dry_run=1 ;;
      -h | --help)
        printf '%s\n' 'Usage: circleci.sh definitions [--project SLUG] [--dry-run]'
        return 0
        ;;
      *) die "unknown definitions option: $1" ;;
    esac
    shift
  done
  if ((dry_run)); then
    local project
    project="$(resolve_project)"
    print_command curl -H 'Circle-Token: <redacted>' "$(api_v2)/project/${project}"
    print_command curl -H 'Circle-Token: <redacted>' "$(api_v2)/projects/<project-id>/pipeline-definitions"
    return 0
  fi
  prepare_live
  local project project_id
  project="$(resolve_project)"
  project_id="$(resolve_project_id "${project}")"
  circle_curl -sS "$(api_v2)/projects/${project_id}/pipeline-definitions" |
    jq -r '(.items // [])[] | [.id, .name, (.config_source.file_path // "")] | @tsv'
}

cmd_delete_definition() {
  dry_run=0
  assume_yes=0
  local name_or_id=""
  while (($#)); do
    case "$1" in
      --yes) assume_yes=1 ;;
      --dry-run) dry_run=1 ;;
      -h | --help)
        printf '%s\n' 'Usage: circleci.sh delete-definition <name|id> --yes'
        return 0
        ;;
      -*) die "unknown delete-definition option: $1" ;;
      *)
        [[ -z "${name_or_id}" ]] || die "delete-definition takes one name or id"
        name_or_id="$1"
        ;;
    esac
    shift
  done
  [[ -n "${name_or_id}" ]] || die "delete-definition requires a name or id"
  require_confirmation "delete-definition"
  if ((dry_run)); then
    local shown_id="${name_or_id}"
    [[ "${shown_id}" == *-* ]] || shown_id="<definition-id-for:${name_or_id}>"
    print_command curl -X DELETE -H 'Circle-Token: <redacted>' \
      "$(api_v2)/projects/<project-id>/pipeline-definitions/${shown_id}"
    return 0
  fi
  prepare_live
  local project project_id definitions definition_id
  project="$(resolve_project)"
  project_id="$(resolve_project_id "${project}")"
  definitions="$(circle_curl -sS "$(api_v2)/projects/${project_id}/pipeline-definitions")"
  definition_id="$(printf '%s' "${definitions}" | jq -r --arg want "${name_or_id}" \
    '(.items // []) | map(select(.id == $want or ((.name // "") | ascii_downcase) == ($want | ascii_downcase))) | .[0].id // empty')"
  [[ -n "${definition_id}" ]] || die "no pipeline definition named or identified by '${name_or_id}'"
  circle_curl -sS -X DELETE \
    "$(api_v2)/projects/${project_id}/pipeline-definitions/${definition_id}" | jq .
}

main() {
  [[ $# -gt 0 ]] || {
    usage
    exit 1
  }
  local command="$1"
  shift
  parse_common_options "$@"
  set -- "${REMAINING[@]}"
  case "${command}" in
    trigger) cmd_trigger "$@" ;;
    tests) cmd_tests "$@" ;;
    list) cmd_list "$@" ;;
    await | watch) cmd_await "$@" ;;
    view | status) cmd_view "$@" ;;
    jobs) cmd_jobs "$@" ;;
    job) cmd_job "$@" ;;
    cancel) cmd_cancel "$@" ;;
    definitions) cmd_definitions "$@" ;;
    delete-definition) cmd_delete_definition "$@" ;;
    help | -h | --help) usage ;;
    *) die "unknown command '${command}' (try: circleci.sh help)" ;;
  esac
}

main "$@"
