#!/usr/bin/env bash
set -euo pipefail

# OctoStaff umbrella GitHub Actions orchestrator.
#
# CI is split across two systems:
#   GitHub Actions  — .github/workflows/ci.yml: checks + unit tests.
#   GitHub Actions  — .github/workflows/release.yml: npm publish on vX.Y.Z tags.
#   CircleCI        — .circleci/config.yml: the large integration suites only.
#
# Use circleci.sh for CircleCI integration operations. This helper wraps `gh run`
# with command shapes parallel to circleci.sh where possible: list/await/watch/
# view/cancel, with --yes required for write operations.

readonly CI_BRANCH="dev"
dry_run=0
assume_yes=0

usage() {
  cat <<'USAGE'
Usage: gha.sh <command> [options]

GitHub Actions commands (read-only unless noted):
  list [options]               List workflow runs.
  await [options]              Find and watch a workflow run to completion.
  watch <run-id>               Watch a known workflow run to completion.
  view <run-id> [--failed]     Show run details or failed logs.
  rerun <run-id> --yes         Rerun a workflow run.
  cancel <run-id> --yes        Cancel a workflow run.

Common options:
  --dry-run                    Print the gh command(s) without running them.
  --yes                        Confirm a write operation.

Examples:
  gha.sh list --workflow ci.yml --branch dev
  gha.sh await --workflow ci.yml --branch dev --sha <commit-sha>
  gha.sh await --workflow release.yml --branch v0.2.0
  gha.sh view <run-id> --failed
USAGE
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '==> %s\n' "$*"
}

require_gh() {
  command -v gh >/dev/null 2>&1 || die "gh CLI not found on PATH (needed for GitHub Actions operations)"
}

require_gh_auth() {
  require_gh
  if gh auth status -h github.com >/dev/null 2>&1; then
    return 0
  fi

  cat >&2 <<'AUTH'
error: gh is not authenticated for github.com.

Configure GitHub CLI auth before using gha.sh:
  gh auth login --hostname github.com --git-protocol ssh --scopes repo,workflow

For automation, provide a token in GH_TOKEN (or GITHUB_TOKEN). It must have
access to octostaff/umbrella. Fine-grained tokens need Actions: read for
list/watch/view/await and Actions: write for rerun/cancel.
AUTH
  exit 1
}

require_confirmation() {
  ((dry_run)) && return 0
  ((assume_yes)) && return 0
  die "$1 is an outward action; re-run with --yes to confirm (or --dry-run to preview)"
}

cmd_list() {
  dry_run=0
  local workflow="ci.yml" branch="${CI_BRANCH}" limit=10
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
        ;;
      --limit | -n)
        shift
        (($#)) || die "--limit requires a value"
        limit="$1"
        ;;
      --dry-run) dry_run=1 ;;
      -h | --help)
        cat <<'USAGE'
Usage: gha.sh list [--workflow ci.yml] [--branch dev] [--limit 10] [--dry-run]
USAGE
        return 0
        ;;
      *) die "Unknown list option: $1" ;;
    esac
    shift
  done
  if ((dry_run)); then
    printf '+ gh run list --workflow=%q --branch=%q --limit %q\n' "${workflow}" "${branch}" "${limit}"
    return 0
  fi
  require_gh_auth
  gh run list --workflow="${workflow}" --branch="${branch}" --limit "${limit}"
}

# Find a GitHub Actions run for a workflow and watch it to completion. Prefer
# exact head SHA when given; otherwise use the ref/branch head.
cmd_await() {
  dry_run=0
  local workflow="ci.yml" ref="${CI_BRANCH}" label="" want_sha="" limit=20
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
      --dry-run) dry_run=1 ;;
      -h | --help)
        cat <<'USAGE'
Usage: gha.sh await [--workflow ci.yml] [--branch dev|--ref vX.Y.Z] [--sha <commit-sha>] [--label name]
USAGE
        return 0
        ;;
      *) die "Unknown await option: $1" ;;
    esac
    shift
  done
  [[ -n "${label}" ]] || label="${workflow}"
  if ((dry_run)); then
    if [[ -n "${want_sha}" ]]; then
      printf '+ gh run list --workflow=%q --limit %q --json databaseId,headSha --jq <match %q>\n' "${workflow}" "${limit}" "${want_sha}"
    else
      printf '+ gh run list --workflow=%q --branch=%q --limit 1 --json databaseId --jq %q\n' "${workflow}" "${ref}" '.[0].databaseId'
    fi
    printf '+ gh run watch <run-id> --exit-status\n'
    return 0
  fi
  require_gh_auth

  local run_id="" tries=0
  while ((tries < 24)); do # ~2min for the run to appear after the trigger
    if [[ -n "${want_sha}" ]]; then
      run_id="$(gh run list --workflow="${workflow}" --limit "${limit}" \
        --json databaseId,headSha --jq \
        "[.[] | select(.headSha==\"${want_sha}\")][0].databaseId" 2>/dev/null || true)"
    else
      run_id="$(gh run list --workflow="${workflow}" --branch="${ref}" --limit 1 \
        --json databaseId --jq '.[0].databaseId' 2>/dev/null || true)"
    fi
    [[ -n "${run_id}" && "${run_id}" != "null" ]] && break
    sleep 5
    ((tries++))
  done
  [[ -n "${run_id}" && "${run_id}" != "null" ]] ||
    die "no GitHub Actions ${label} run found for ${ref} (workflow ${workflow}); check 'gha.sh list --workflow ${workflow} --branch ${ref}'"

  log "Watching GitHub Actions ${label} run ${run_id} (${ref})"
  gh run watch "${run_id}" --exit-status
}

cmd_watch() {
  dry_run=0
  local run_id=""
  while (($#)); do
    case "$1" in
      --dry-run) dry_run=1 ;;
      -h | --help)
        cat <<'USAGE'
Usage: gha.sh watch <run-id> [--dry-run]
USAGE
        return 0
        ;;
      -*) die "Unknown watch option: $1" ;;
      *)
        [[ -z "${run_id}" ]] || die "watch takes a single run id"
        run_id="$1"
        ;;
    esac
    shift
  done
  [[ -n "${run_id}" ]] || die "watch requires a run id"
  if ((dry_run)); then
    printf '+ gh run watch %q --exit-status\n' "${run_id}"
    return 0
  fi
  require_gh_auth
  gh run watch "${run_id}" --exit-status
}

cmd_view() {
  dry_run=0
  local run_id="" failed=0
  while (($#)); do
    case "$1" in
      --failed | --log-failed) failed=1 ;;
      --dry-run) dry_run=1 ;;
      -h | --help)
        cat <<'USAGE'
Usage: gha.sh view <run-id> [--failed] [--dry-run]
USAGE
        return 0
        ;;
      -*) die "Unknown view option: $1" ;;
      *)
        [[ -z "${run_id}" ]] || die "view takes a single run id"
        run_id="$1"
        ;;
    esac
    shift
  done
  [[ -n "${run_id}" ]] || die "view requires a run id"
  if ((dry_run)); then
    if ((failed)); then
      printf '+ gh run view %q --log-failed\n' "${run_id}"
    else
      printf '+ gh run view %q\n' "${run_id}"
    fi
    return 0
  fi
  require_gh_auth
  if ((failed)); then
    gh run view "${run_id}" --log-failed
  else
    gh run view "${run_id}"
  fi
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
        cat <<'USAGE'
Usage: gha.sh rerun <run-id> [--failed] --yes
USAGE
        return 0
        ;;
      -*) die "Unknown rerun option: $1" ;;
      *)
        [[ -z "${run_id}" ]] || die "rerun takes a single run id"
        run_id="$1"
        ;;
    esac
    shift
  done
  [[ -n "${run_id}" ]] || die "rerun requires a run id"
  require_confirmation "rerun"
  if ((dry_run)); then
    printf '+ gh run rerun %q%s\n' "${run_id}" "$( ((failed)) && printf ' --failed')"
    return 0
  fi
  require_gh_auth
  if ((failed)); then
    gh run rerun "${run_id}" --failed
  else
    gh run rerun "${run_id}"
  fi
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
        cat <<'USAGE'
Usage: gha.sh cancel <run-id> --yes
USAGE
        return 0
        ;;
      -*) die "Unknown cancel option: $1" ;;
      *)
        [[ -z "${run_id}" ]] || die "cancel takes a single run id"
        run_id="$1"
        ;;
    esac
    shift
  done
  [[ -n "${run_id}" ]] || die "cancel requires a run id"
  require_confirmation "cancel"
  if ((dry_run)); then
    printf '+ gh run cancel %q\n' "${run_id}"
    return 0
  fi
  require_gh_auth
  gh run cancel "${run_id}"
}

main() {
  [[ $# -gt 0 ]] || {
    usage
    exit 1
  }
  local cmd="$1"
  shift
  case "${cmd}" in
    list) cmd_list "$@" ;;
    await) cmd_await "$@" ;;
    watch) cmd_watch "$@" ;;
    view) cmd_view "$@" ;;
    rerun) cmd_rerun "$@" ;;
    cancel) cmd_cancel "$@" ;;
    help | -h | --help) usage ;;
    *) die "unknown command '${cmd}' (try: gha.sh help)" ;;
  esac
}

main "$@"
