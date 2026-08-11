#!/usr/bin/env bash
set -euo pipefail

# Repository-agnostic GitHub Actions operator. Repository selection is explicit
# or derived from git; write operations always require --yes.

dry_run=0
assume_yes=0
repo_override="${CI_REPO:-}"
remote_override="${CI_REMOTE:-}"
REMAINING=()

usage() {
  cat <<'USAGE'
Usage: gha.sh <command> [options]

Read-only commands:
  list [options]                 List workflow runs.
  await [options]                Find a run and watch it to completion.
  watch <run-id>                 Watch a known run to completion.
  view <run-id> [--failed]       Show run details or failed logs.

Write commands (require --yes unless --dry-run):
  dispatch <workflow> [options]  Dispatch a workflow.
  rerun <run-id> [--failed]      Rerun a workflow run.
  cancel <run-id>                Cancel a workflow run.

Selection options (accepted by every command):
  --repo OWNER/REPO              Target repository (or HOST/OWNER/REPO).
  --remote NAME                  Git remote used for repository discovery.

Common options:
  --dry-run                      Print commands without auth or network access.
  --yes                          Confirm a write operation.

Environment overrides:
  CI_REPO, CI_REMOTE, CI_BRANCH, GHA_WORKFLOW

Examples:
  gha.sh list --workflow ci.yml --branch feature/name --dry-run
  gha.sh await --workflow ci.yml --sha <commit> --dry-run
  gha.sh view <run-id> --failed --dry-run
  gha.sh rerun <run-id> --failed --yes
  gha.sh dispatch ci.yml --ref feature/name --field reason=manual --yes
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

require_gh() {
  command -v gh >/dev/null 2>&1 || die "gh CLI not found on PATH"
}

require_confirmation() {
  ((dry_run)) && return 0
  ((assume_yes)) && return 0
  die "$1 changes remote CI state; re-run with --yes to confirm (or --dry-run to preview)"
}

parse_common_options() {
  REMAINING=()
  while (($#)); do
    case "$1" in
      --repo)
        shift
        (($#)) || die "--repo requires a value"
        repo_override="$1"
        ;;
      --repo=*) repo_override="${1#*=}" ;;
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

# Print OWNER/REPO for github.com or HOST/OWNER/REPO for another GitHub host.
github_repo_from_value() {
  local value="$1" host="" path="" rest=""
  value="${value%/}"
  value="${value%.git}"
  case "${value}" in
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
    */*/* )
      host="${value%%/*}"
      path="${value#*/}"
      ;;
    */* ) path="${value}" ;;
    * ) return 1 ;;
  esac
  path="${path#/}"
  path="${path%.git}"
  [[ "${path}" == */* && "${path}" != */*/* ]] || return 1
  if [[ -z "${host}" || "${host}" == "github.com" ]]; then
    printf '%s\n' "${path}"
  else
    printf '%s/%s\n' "${host}" "${path}"
  fi
}

resolve_repo() {
  if [[ -n "${repo_override}" ]]; then
    github_repo_from_value "${repo_override}" ||
      die "cannot parse --repo/CI_REPO '${repo_override}'"
    return 0
  fi
  local remote url
  remote="$(selected_remote)"
  [[ -n "${remote}" ]] || die "cannot discover a git remote; pass --repo OWNER/REPO"
  url="$(git remote get-url "${remote}")"
  github_repo_from_value "${url}" ||
    die "remote '${remote}' is not a recognizable GitHub repository; pass --repo"
}

repo_host() {
  local repo="$1"
  if [[ "${repo}" == */*/* ]]; then
    printf '%s\n' "${repo%%/*}"
  else
    printf '%s\n' "${GH_HOST:-github.com}"
  fi
}

require_gh_auth() {
  local repo="$1" host
  require_gh
  host="$(repo_host "${repo}")"
  gh auth status --hostname "${host}" >/dev/null 2>&1 ||
    die "gh is not authenticated for ${host}; use 'gh auth login --hostname ${host}' or an approved token environment variable"
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

cmd_list() {
  dry_run=0
  local workflow="${GHA_WORKFLOW:-}" branch="" limit=10 branch_set=0
  while (($#)); do
    case "$1" in
      --workflow | -w)
        shift
        (($#)) || die "--workflow requires a value"
        workflow="$1"
        ;;
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
        printf '%s\n' 'Usage: gha.sh list [--workflow FILE] [--branch REF] [--limit N] [--repo OWNER/REPO] [--dry-run]'
        return 0
        ;;
      *) die "unknown list option: $1" ;;
    esac
    shift
  done
  ((branch_set)) || branch="$(default_branch || true)"
  local repo
  repo="$(resolve_repo)"
  local -a args=(gh run list --repo "${repo}" --limit "${limit}")
  [[ -n "${workflow}" ]] && args+=(--workflow "${workflow}")
  [[ -n "${branch}" ]] && args+=(--branch "${branch}")
  if ((dry_run)); then
    print_command "${args[@]}"
    return 0
  fi
  require_gh_auth "${repo}"
  "${args[@]}"
}

cmd_await() {
  dry_run=0
  local workflow="${GHA_WORKFLOW:-}" ref="" want_sha="" label="" limit=20
  local timeout=120 interval=5 ref_set=0
  while (($#)); do
    case "$1" in
      --workflow | -w)
        shift
        (($#)) || die "--workflow requires a value"
        workflow="$1"
        ;;
      --branch | --ref | -b)
        shift
        (($#)) || die "--branch requires a value"
        ref="$1"
        ref_set=1
        ;;
      --sha)
        shift
        (($#)) || die "--sha requires a value"
        want_sha="$1"
        ;;
      --label)
        shift
        (($#)) || die "--label requires a value"
        label="$1"
        ;;
      --limit)
        shift
        (($#)) || die "--limit requires a value"
        limit="$1"
        ;;
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
        printf '%s\n' 'Usage: gha.sh await [--workflow FILE] [--branch REF | --sha COMMIT] [--timeout SEC] [--dry-run]'
        return 0
        ;;
      *) die "unknown await option: $1" ;;
    esac
    shift
  done
  [[ "${timeout}" =~ ^[0-9]+$ && "${interval}" =~ ^[1-9][0-9]*$ ]] ||
    die "--timeout and --interval must be non-negative/positive integer seconds"
  if [[ -z "${want_sha}" && ${ref_set} -eq 0 ]]; then
    ref="$(default_branch || true)"
  fi
  [[ -n "${want_sha}" || -n "${ref}" ]] ||
    die "cannot discover a branch; pass --branch or --sha"
  [[ -n "${label}" ]] || label="${workflow:-CI}"

  local repo run_id="" elapsed=0
  repo="$(resolve_repo)"
  local -a find_args=(gh run list --repo "${repo}" --limit "${limit}" --json databaseId --jq '.[0].databaseId')
  [[ -n "${workflow}" ]] && find_args+=(--workflow "${workflow}")
  if [[ -n "${want_sha}" ]]; then
    find_args+=(--commit "${want_sha}")
  else
    find_args+=(--branch "${ref}")
  fi
  local -a watch_args=(gh run watch --repo "${repo}" '<run-id>' --exit-status)
  if ((dry_run)); then
    print_command "${find_args[@]}"
    print_command "${watch_args[@]}"
    return 0
  fi
  require_gh_auth "${repo}"
  while ((elapsed <= timeout)); do
    run_id="$("${find_args[@]}" 2>/dev/null || true)"
    [[ -n "${run_id}" && "${run_id}" != "null" ]] && break
    ((elapsed == timeout)) && break
    sleep "${interval}"
    elapsed=$((elapsed + interval))
  done
  [[ -n "${run_id}" && "${run_id}" != "null" ]] ||
    die "no ${label} run appeared within ${timeout}s"
  log "watching ${label} run ${run_id} in ${repo}"
  gh run watch --repo "${repo}" "${run_id}" --exit-status
}

cmd_watch() {
  dry_run=0
  local run_id=""
  while (($#)); do
    case "$1" in
      --dry-run) dry_run=1 ;;
      -h | --help)
        printf '%s\n' 'Usage: gha.sh watch <run-id> [--repo OWNER/REPO] [--dry-run]'
        return 0
        ;;
      -*) die "unknown watch option: $1" ;;
      *)
        [[ -z "${run_id}" ]] || die "watch takes one run id"
        run_id="$1"
        ;;
    esac
    shift
  done
  [[ -n "${run_id}" ]] || die "watch requires a run id"
  local repo
  repo="$(resolve_repo)"
  local -a args=(gh run watch --repo "${repo}" "${run_id}" --exit-status)
  if ((dry_run)); then
    print_command "${args[@]}"
    return 0
  fi
  require_gh_auth "${repo}"
  "${args[@]}"
}

cmd_view() {
  dry_run=0
  local run_id="" failed=0
  while (($#)); do
    case "$1" in
      --failed | --log-failed) failed=1 ;;
      --dry-run) dry_run=1 ;;
      -h | --help)
        printf '%s\n' 'Usage: gha.sh view <run-id> [--failed] [--repo OWNER/REPO] [--dry-run]'
        return 0
        ;;
      -*) die "unknown view option: $1" ;;
      *)
        [[ -z "${run_id}" ]] || die "view takes one run id"
        run_id="$1"
        ;;
    esac
    shift
  done
  [[ -n "${run_id}" ]] || die "view requires a run id"
  local repo
  repo="$(resolve_repo)"
  local -a args=(gh run view --repo "${repo}" "${run_id}")
  ((failed)) && args+=(--log-failed)
  if ((dry_run)); then
    print_command "${args[@]}"
    return 0
  fi
  require_gh_auth "${repo}"
  "${args[@]}"
}

cmd_dispatch() {
  dry_run=0
  assume_yes=0
  local workflow="" ref="${CI_BRANCH:-}"
  local -a fields=()
  while (($#)); do
    case "$1" in
      --ref | --branch | -b)
        shift
        (($#)) || die "--ref requires a value"
        ref="$1"
        ;;
      --field | -f)
        shift
        (($#)) || die "--field requires KEY=VALUE"
        [[ "$1" == *=* ]] || die "--field requires KEY=VALUE"
        fields+=("$1")
        ;;
      --yes) assume_yes=1 ;;
      --dry-run) dry_run=1 ;;
      -h | --help)
        printf '%s\n' 'Usage: gha.sh dispatch <workflow> [--ref REF] [--field KEY=VALUE ...] --yes'
        return 0
        ;;
      -*) die "unknown dispatch option: $1" ;;
      *)
        [[ -z "${workflow}" ]] || die "dispatch takes one workflow"
        workflow="$1"
        ;;
    esac
    shift
  done
  [[ -n "${workflow}" ]] || die "dispatch requires a workflow name or file"
  [[ -n "${ref}" ]] ||
    die "dispatch requires an explicit --ref (or CI_BRANCH); do not infer a mutation ref across fork/upstream remotes"
  require_confirmation "dispatch"
  local repo field
  repo="$(resolve_repo)"
  local -a args=(gh workflow run "${workflow}" --repo "${repo}" --ref "${ref}")
  for field in "${fields[@]}"; do
    args+=(--field "${field}")
  done
  if ((dry_run)); then
    print_command "${args[@]}"
    return 0
  fi
  require_gh_auth "${repo}"
  "${args[@]}"
}

cmd_rerun() {
  dry_run=0
  assume_yes=0
  local run_id="" failed=0
  while (($#)); do
    case "$1" in
      --failed) failed=1 ;;
      --yes) assume_yes=1 ;;
      --dry-run) dry_run=1 ;;
      -h | --help)
        printf '%s\n' 'Usage: gha.sh rerun <run-id> [--failed] --yes'
        return 0
        ;;
      -*) die "unknown rerun option: $1" ;;
      *)
        [[ -z "${run_id}" ]] || die "rerun takes one run id"
        run_id="$1"
        ;;
    esac
    shift
  done
  [[ -n "${run_id}" ]] || die "rerun requires a run id"
  require_confirmation "rerun"
  local repo
  repo="$(resolve_repo)"
  local -a args=(gh run rerun --repo "${repo}" "${run_id}")
  ((failed)) && args+=(--failed)
  if ((dry_run)); then
    print_command "${args[@]}"
    return 0
  fi
  require_gh_auth "${repo}"
  "${args[@]}"
}

cmd_cancel() {
  dry_run=0
  assume_yes=0
  local run_id=""
  while (($#)); do
    case "$1" in
      --yes) assume_yes=1 ;;
      --dry-run) dry_run=1 ;;
      -h | --help)
        printf '%s\n' 'Usage: gha.sh cancel <run-id> --yes'
        return 0
        ;;
      -*) die "unknown cancel option: $1" ;;
      *)
        [[ -z "${run_id}" ]] || die "cancel takes one run id"
        run_id="$1"
        ;;
    esac
    shift
  done
  [[ -n "${run_id}" ]] || die "cancel requires a run id"
  require_confirmation "cancel"
  local repo
  repo="$(resolve_repo)"
  local -a args=(gh run cancel --repo "${repo}" "${run_id}")
  if ((dry_run)); then
    print_command "${args[@]}"
    return 0
  fi
  require_gh_auth "${repo}"
  "${args[@]}"
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
    list) cmd_list "$@" ;;
    await) cmd_await "$@" ;;
    watch) cmd_watch "$@" ;;
    view) cmd_view "$@" ;;
    dispatch) cmd_dispatch "$@" ;;
    rerun) cmd_rerun "$@" ;;
    cancel) cmd_cancel "$@" ;;
    help | -h | --help) usage ;;
    *) die "unknown command '${command}' (try: gha.sh help)" ;;
  esac
}

main "$@"
