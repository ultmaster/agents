#!/usr/bin/env bash
set -euo pipefail

# OctoStaff umbrella CircleCI orchestrator.
#
# CI is split across two systems:
#   GitHub Actions  — .github/workflows/ci.yml: checks + unit tests.
#   GitHub Actions  — .github/workflows/release.yml: npm publish on vX.Y.Z tags.
#   CircleCI        — .circleci/config.yml: the large integration suites only.
#
# CircleCI now has one live config again, so triggering integration uses the
# default pipeline endpoint:
#   POST /api/v2/project/{slug}/pipeline
#        { branch, parameters:{...} }
#
# Style mirrors .agents/skills/release/scripts/release.sh.

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# The skill is self-contained: its .env (CIRCLECI_TOKEN) lives next to this
# script's parent, i.e. .agents/skills/ci/.env - not the umbrella root.
skill_root="$(cd -- "${script_dir}/.." && pwd)"
readonly skill_root
env_file="${skill_root}/.env"
readonly env_file

# --- Constants ---------------------------------------------------------------

readonly CI_BRANCH="dev"
readonly CIRCLE_PROJECT_SLUG="gh/octostaff/umbrella"
readonly CIRCLE_API="https://circleci.com/api/v2"
readonly CIRCLE_API_V1="https://circleci.com/api/v1.1"
# v1.1 project path uses the long VCS name (github, not gh).
readonly CIRCLE_PROJECT_V1="github/octostaff/umbrella"
readonly CIRCLE_UI="https://app.circleci.com/pipelines/github/octostaff/umbrella"

# Allowed module selectors (one per CircleCI integration job; kept in sync with
# the run_<module> gates in .circleci/config.yml). `query_cost` is reachable
# ONLY by naming it — a bare `tests` sends run_tests, which deliberately does
# not light it (it profiles rather than gates, and is the priciest job here).
readonly TEST_MODULES="bubble claude_scuba codex_scuba reef starfish playwright query_cost"

project_id="" # resolved lazily from the slug (legacy definition cleanup only)
dry_run=0
assume_yes=0

# --- Generic helpers ---------------------------------------------------------

usage() {
  cat <<'USAGE'
Usage: circleci.sh <command> [options]

CI is split: checks + unit run on GitHub Actions (ci.yml), npm publish runs on
GitHub Actions (release.yml), and this script owns only the CircleCI integration
pipeline in .circleci/config.yml. Use gha.sh for GitHub Actions operations.

Trigger commands:
  tests [selectors]            Trigger the integration tests pipeline.

CircleCI triage commands (read-only unless noted):
  list [options]               List recent pipelines.
  await <pipeline-id>          Poll a pipeline to a terminal state.
  watch <pipeline-id>          Alias for await.
  view <pipeline-id>           List a pipeline's workflows (name, status, id).
  status <pipeline-id>         Alias for view.
  jobs <workflow-id>           List a workflow's jobs (number, status, name).
  job <job-number>             Per-step detail + failure log URLs for a job.
  cancel <workflow-id> --yes   Cancel a running workflow.

Legacy CircleCI definition cleanup:
  definitions                  List leftover pipeline definitions. Read-only.
  delete-definition <name>     Delete a leftover multi-config definition by name.

  help                         Show this help text.

tests selectors (default: every integration job):
  --all                        Every module job (run_tests).
  --module <name>              One module's integration job (repeatable): bubble,
                               claude-scuba, codex-scuba, reef, starfish, playwright.

Common options:
  --yes                        Confirm a trigger / write (every trigger costs CircleCI minutes).
  --dry-run                    Print the API call(s) without running them.
  --watch                      Poll the triggered pipeline(s) to completion.

Examples:
  circleci.sh tests --module bubble --module reef --yes
  circleci.sh tests --all --yes --watch
  circleci.sh list --branch dev
  circleci.sh view <pipeline-id>
  circleci.sh definitions
  circleci.sh delete-definition tests --yes
USAGE
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '==> %s\n' "$*"
}

require_node() {
  command -v node >/dev/null 2>&1 || die "node is required for JSON handling but was not found on PATH"
}

# Triggering CI is an outward (paid) action; dry-run is always allowed, otherwise
# --yes is mandatory. No interactive TTY is assumed.
require_confirmation() {
  ((dry_run)) && return 0
  ((assume_yes)) && return 0
  die "$1 is an outward action (CircleCI trigger or config change); re-run with --yes to confirm (or --dry-run to preview)"
}

load_env() {
  if [[ -z "${CIRCLECI_TOKEN:-}" && -f "${env_file}" ]]; then
    set -a
    # shellcheck disable=SC1091
    . "${env_file}" 2>/dev/null || true
    set +a
  fi
  [[ -n "${CIRCLECI_TOKEN:-}" ]] || die "CIRCLECI_TOKEN not set and not readable from ${env_file}.
       Create it:  cp ${skill_root}/.env.example ${env_file}  (then fill in the token)"
}

# --- Trigger + watch ---------------------------------------------------------

# Trigger the default CircleCI config with a parameters JSON object; echo the new
# pipeline id (or a placeholder on dry-run).
circleci_run() {
  local params="$1" payload
  payload="$(printf '{"branch":"%s","parameters":%s}' "${CI_BRANCH}" "${params}")"
  if ((dry_run)); then
    printf '+ curl -X POST %s/project/%s/pipeline -d %q\n' "${CIRCLE_API}" "${CIRCLE_PROJECT_SLUG}" "${payload}" >&2
    printf 'DRYRUN_PIPELINE_ID\n'
    return 0
  fi

  load_env
  local body id
  body="$(curl -s -X POST \
    -H "Circle-Token: ${CIRCLECI_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${payload}" \
    "${CIRCLE_API}/project/${CIRCLE_PROJECT_SLUG}/pipeline")"
  id="$(printf '%s' "${body}" | node -e 'const s=require("fs").readFileSync(0,"utf8");let j;try{j=JSON.parse(s)}catch(e){process.exit(1)};process.stdout.write(j.id||"")')" ||
    die "could not parse CircleCI response: ${body}"
  [[ -n "${id}" ]] || die "CircleCI did not return a pipeline id. Response: ${body}"
  printf '%s\n' "${id}"
}

watch_circleci() {
  local pid="$1"
  if ((dry_run)) || [[ "${pid}" == "DRYRUN_PIPELINE_ID" ]]; then
    log "(dry-run) would poll pipeline ${pid} to completion"
    return 0
  fi
  load_env
  log "Watching pipeline ${pid} (${CIRCLE_UI})"

  local tries=0 max=240 body code
  while ((tries < max)); do
    body="$(curl -s -H "Circle-Token: ${CIRCLECI_TOKEN}" "${CIRCLE_API}/pipeline/${pid}/workflow")" || body=""
    set +e
    printf '%s' "${body}" | node -e '
      const s = require("fs").readFileSync(0, "utf8");
      let j; try { j = JSON.parse(s); } catch (e) { process.exit(3); }
      const items = j.items || [];
      if (!items.length) process.exit(2);
      const pending = new Set(["running","failing","on_hold","created","pending","new","queued"]);
      let pend = 0, bad = 0;
      for (const w of items) {
        process.stderr.write("    " + w.name + ": " + w.status + "\n");
        if (pending.has(w.status)) pend++;
        else if (w.status !== "success") bad++;
      }
      if (pend) process.exit(10);
      process.exit(bad ? 1 : 0);
    '
    code=$?
    set -e
    case "${code}" in
      0)
        log "All workflows succeeded for ${pid}"
        return 0
        ;;
      1)
        log "One or more workflows did not succeed for ${pid}"
        return 1
        ;;
      2 | 3) ;; # no workflows yet / transient parse: keep polling
      10) printf '    ...still running\n' ;;
      *) ;;
    esac
    sleep 15
    ((++tries))
  done
  die "timed out watching pipeline ${pid}"
}

# --- Parameter builders ------------------------------------------------------

# Build a parameters JSON object from --module selectors (env: MODULES).
build_test_params() {
  ALLOWED_MODULES="${TEST_MODULES}" node -e '
    const norm = (s) => s.replace(/-/g, "_");
    const modules = (process.env.MODULES || "").split(",").filter(Boolean);
    const M = new Set((process.env.ALLOWED_MODULES || "").split(" ").filter(Boolean));
    const out = {};
    for (const m of modules) {
      const k = norm(m);
      if (!M.has(k)) { console.error("unknown --module: " + m); process.exit(2); }
      out["run_" + k] = true;
    }
    process.stdout.write(JSON.stringify(out));
  '
}

# --- Commands ----------------------------------------------------------------

cmd_list() {
  local branch="${CI_BRANCH}" limit=10 page_token=""
  while (($#)); do
    case "$1" in
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
      -h | --help)
        cat <<'USAGE'
Usage: circleci.sh list [--branch dev] [--limit 10]
USAGE
        return 0
        ;;
      *) die "Unknown list option: $1" ;;
    esac
    shift
  done
  require_node
  load_env

  local url="${CIRCLE_API}/project/${CIRCLE_PROJECT_SLUG}/pipeline?branch=${branch}"
  if [[ -n "${page_token}" ]]; then
    url="${url}&page-token=${page_token}"
  fi
  curl -s -H "Circle-Token: ${CIRCLECI_TOKEN}" "${url}" | LIMIT="${limit}" node -e '
    const j = JSON.parse(require("fs").readFileSync(0, "utf8"));
    const limit = Number(process.env.LIMIT || 10);
    const items = (j.items || []).slice(0, limit);
    if (!items.length) { console.log("(no pipelines)"); process.exit(0); }
    for (const p of items) {
      const vcs = p.vcs || {};
      const rev = vcs.revision ? String(vcs.revision).slice(0, 12) : "-";
      console.log([p.id, p.state || "-", p.created_at || "-", rev].join("  "));
    }
  '
}

cmd_tests() {
  dry_run=0
  assume_yes=0
  local watch=0 all=0
  local modules=""
  while (($#)); do
    case "$1" in
      --all) all=1 ;;
      --module | -m)
        shift
        [[ $# -gt 0 ]] || die "--module needs a name"
        modules="${modules:+${modules},}$1"
        ;;
      --yes) assume_yes=1 ;;
      --dry-run) dry_run=1 ;;
      --watch) watch=1 ;;
      -h | --help)
        usage
        return 0
        ;;
      *) die "Unknown tests option: $1" ;;
    esac
    shift
  done
  require_node

  local params
  if ((all)) || [[ -z "${modules}" ]]; then
    params='{"run_tests":true}'
  else
    params="$(MODULES="${modules}" build_test_params)" ||
      die "invalid tests selector"
  fi

  require_confirmation "tests"
  log "Triggering CircleCI integration on ${CI_BRANCH} (parameters: ${params})"
  local pid
  pid="$(circleci_run "${params}")"
  log "Pipeline: ${pid}  ->  ${CIRCLE_UI}"
  ((watch)) && watch_circleci "${pid}"
  return 0
}

cmd_await() {
  dry_run=0
  local pid=""
  while (($#)); do
    case "$1" in
      -h | --help)
        usage
        return 0
        ;;
      *)
        [[ -z "${pid}" ]] || die "await takes a single pipeline id"
        pid="$1"
        ;;
    esac
    shift
  done
  [[ -n "${pid}" ]] || die "await requires a pipeline id"
  require_node
  watch_circleci "${pid}"
}

cmd_watch() {
  cmd_await "$@"
}

# --- Triage ------------------------------------------------------------------

# List the workflows of a pipeline (name, status, id). Read-only.
cmd_view() {
  local pid=""
  while (($#)); do
    case "$1" in
      -h | --help)
        usage
        return 0
        ;;
      -*) die "Unknown view option: $1" ;;
      *)
        [[ -z "${pid}" ]] || die "view takes a single pipeline id"
        pid="$1"
        ;;
    esac
    shift
  done
  [[ -n "${pid}" ]] || die "view requires a pipeline id (printed when you trigger)"
  require_node
  load_env
  curl -s -H "Circle-Token: ${CIRCLECI_TOKEN}" "${CIRCLE_API}/pipeline/${pid}/workflow" | node -e '
    const j=JSON.parse(require("fs").readFileSync(0,"utf8"));
    const it=j.items||[];
    if(!it.length){console.log("(no workflows - gate produced none, or still processing)");process.exit(0)}
    for(const w of it) console.log(String(w.status).padEnd(10), w.name, " ", w.id);
  '
}

cmd_status() {
  cmd_view "$@"
}

# List the jobs of a workflow (number, status, name). Read-only.
cmd_jobs() {
  local wf=""
  while (($#)); do
    case "$1" in
      -h | --help)
        usage
        return 0
        ;;
      -*) die "Unknown jobs option: $1" ;;
      *)
        [[ -z "${wf}" ]] || die "jobs takes a single workflow id"
        wf="$1"
        ;;
    esac
    shift
  done
  [[ -n "${wf}" ]] || die "jobs requires a workflow id (from 'circleci.sh view <pipeline-id>')"
  require_node
  load_env
  curl -s -H "Circle-Token: ${CIRCLECI_TOKEN}" "${CIRCLE_API}/workflow/${wf}/job" | node -e '
    const j=JSON.parse(require("fs").readFileSync(0,"utf8"));
    const it=j.items||[];
    if(!it.length){console.log("(no jobs)");process.exit(0)}
    for(const job of it) console.log(String(job.job_number||"-").padEnd(7), String(job.status).padEnd(10), job.name);
  '
}

# Print step/action detail for a job number (legacy v1.1 exposes per-action
# status + log output URLs - handy for a failing job). Read-only.
cmd_job() {
  local num=""
  while (($#)); do
    case "$1" in
      -h | --help)
        usage
        return 0
        ;;
      -*) die "Unknown job option: $1" ;;
      *)
        [[ -z "${num}" ]] || die "job takes a single job number"
        num="$1"
        ;;
    esac
    shift
  done
  [[ -n "${num}" ]] || die "job requires a job number (from 'circleci.sh jobs <workflow-id>')"
  require_node
  load_env
  curl -s -H "Circle-Token: ${CIRCLECI_TOKEN}" "${CIRCLE_API_V1}/project/${CIRCLE_PROJECT_V1}/${num}" | node -e '
    const j=JSON.parse(require("fs").readFileSync(0,"utf8"));
    for(const s of (j.steps||[])){
      for(const a of (s.actions||[])){
        console.log(String(a.status).padEnd(10), a.name, a.failed? "  FAILED log: "+(a.output_url||""):"");
      }
    }
  '
}

# Cancel a running workflow.
cmd_cancel() {
  dry_run=0
  assume_yes=0
  local wf=""
  while (($#)); do
    case "$1" in
      --yes) assume_yes=1 ;;
      --dry-run) dry_run=1 ;;
      -h | --help)
        usage
        return 0
        ;;
      -*) die "Unknown cancel option: $1" ;;
      *)
        [[ -z "${wf}" ]] || die "cancel takes a single workflow id"
        wf="$1"
        ;;
    esac
    shift
  done
  [[ -n "${wf}" ]] || die "cancel requires a workflow id (from 'circleci.sh view <pipeline-id>')"
  require_node
  require_confirmation "cancel"
  if ((dry_run)); then
    printf '+ curl -X POST %s/workflow/%s/cancel\n' "${CIRCLE_API}" "${wf}"
    return 0
  fi
  load_env
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "Circle-Token: ${CIRCLECI_TOKEN}" "${CIRCLE_API}/workflow/${wf}/cancel")"
  log "cancel ${wf}: HTTP ${code}"
  [[ "${code}" =~ ^2 ]] || die "cancel failed (HTTP ${code})"
}

# --- Legacy pipeline-definition cleanup -------------------------------------

resolve_project_id() {
  [[ -n "${project_id}" ]] && {
    printf '%s\n' "${project_id}"
    return 0
  }
  load_env
  local body id
  body="$(curl -s -H "Circle-Token: ${CIRCLECI_TOKEN}" \
    "${CIRCLE_API}/project/${CIRCLE_PROJECT_SLUG}")" || return 1
  id="$(printf '%s' "${body}" | node -e 'const s=require("fs").readFileSync(0,"utf8");let j;try{j=JSON.parse(s)}catch(e){process.exit(1)};process.stdout.write(j.id||"")')" || return 1
  [[ -n "${id}" ]] || return 1
  project_id="${id}"
  printf '%s\n' "${id}"
}

fetch_definitions_json() {
  local pid
  pid="$(resolve_project_id)" || return 1
  load_env
  curl -s -H "Circle-Token: ${CIRCLECI_TOKEN}" \
    "${CIRCLE_API}/projects/${pid}/pipeline-definitions"
}

discover_definition_id() {
  local name="$1"
  fetch_definitions_json | node -e '
    const s = require("fs").readFileSync(0, "utf8");
    let j; try { j = JSON.parse(s); } catch (e) { process.exit(1); }
    const want = (process.argv[1] || "").toLowerCase();
    const hit = (j.items || []).find((d) => String(d.name || "").toLowerCase() === want);
    process.stdout.write(hit && hit.id ? hit.id : "");
  ' "${name}"
}

cmd_definitions() {
  while (($#)); do
    case "$1" in
      -h | --help)
        usage
        return 0
        ;;
      *) die "Unknown definitions option: $1" ;;
    esac
    shift
  done
  require_node
  fetch_definitions_json | node -e '
    const s = require("fs").readFileSync(0, "utf8");
    let j; try { j = JSON.parse(s); } catch (e) { console.error(s); process.exit(1); }
    const items = j.items || [];
    if (!items.length) { console.log("(no pipeline definitions found)"); process.exit(0); }
    for (const d of items) {
      console.log([d.id, d.name, (d.config_source && d.config_source.file_path) || ""].join("  "));
    }
  '
}

# Delete a leftover multi-config pipeline definition by name. This is only for
# cleanup after reverting to the default .circleci/config.yml setup.
cmd_delete_definition() {
  dry_run=0
  assume_yes=0
  local name=""
  while (($#)); do
    case "$1" in
      --yes) assume_yes=1 ;;
      --dry-run) dry_run=1 ;;
      -h | --help)
        usage
        return 0
        ;;
      -*) die "Unknown delete-definition option: $1" ;;
      *)
        [[ -z "${name}" ]] || die "delete-definition takes a single name"
        name="$1"
        ;;
    esac
    shift
  done
  [[ -n "${name}" ]] || die "delete-definition requires a pipeline name"
  require_node
  require_confirmation "delete-definition"

  local pid id
  pid="$(resolve_project_id)" || die "could not resolve the project id for ${CIRCLE_PROJECT_SLUG}"
  id="$(discover_definition_id "${name}")" || true
  [[ -n "${id}" ]] || die "no pipeline definition named '${name}'"
  if ((dry_run)); then
    printf '+ curl -X DELETE %s/projects/%s/pipeline-definitions/%s\n' "${CIRCLE_API}" "${pid}" "${id}"
    return 0
  fi
  load_env
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' -X DELETE \
    -H "Circle-Token: ${CIRCLECI_TOKEN}" \
    "${CIRCLE_API}/projects/${pid}/pipeline-definitions/${id}")"
  log "delete ${name} (${id}): HTTP ${code}"
  [[ "${code}" =~ ^2 ]] || die "delete failed (HTTP ${code})"
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
    tests) cmd_tests "$@" ;;
    await) cmd_await "$@" ;;
    watch) cmd_watch "$@" ;;
    view) cmd_view "$@" ;;
    status) cmd_status "$@" ;;
    jobs) cmd_jobs "$@" ;;
    job) cmd_job "$@" ;;
    cancel) cmd_cancel "$@" ;;
    definitions) cmd_definitions "$@" ;;
    delete-definition) cmd_delete_definition "$@" ;;
    help | -h | --help) usage ;;
    *) die "unknown command '${cmd}' (try: circleci.sh help)" ;;
  esac
}

main "$@"
