#!/usr/bin/env bash
set -euo pipefail

# OctoStaff GitHub issue tracker helper.
#
# A thin, opinionated wrapper over `gh` that makes the issue tracker the
# centralized place for tracking OctoStaff work (bug fixes, feature planning,
# architecture refactors, …): list issues across any of the
# umbrella / standalone (mirror) repos, read a full issue (title, body, every comment,
# and its image attachments cached locally so they can be viewed), post progress
# comments, and tag an issue's status with a label.
#
# Style mirrors the `ci` skill's gha.sh: die/log helpers, per-command arg
# loops, --dry-run to preview, and --yes required for every outward write.

readonly DEFAULT_REPO="umbrella"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly SKILL_DIR="${SCRIPT_DIR%/scripts}"
readonly CACHE_BASE="${SKILL_DIR}/cache" # view caches issue text + attachments here (gitignored)
dry_run=0
assume_yes=0

usage() {
  cat <<'USAGE'
Usage: issue-tracker.sh <command> [options]

Read-only commands:
  list [options]                List issues (default repo: umbrella).
  view <issue> [options]        Show one issue: body, comments, image attachments.
  labels [--repo R]             List a repo's labels.
  repos                         Show the repo-alias table.
  doctor [--live --yes]         Check this machine can upload issue images.

Write commands (require --yes; --dry-run previews):
  create --title TEXT [...]      Open a new issue (labels, modules, status, images).
  comment <issue> [--body TEXT] Post a comment, optionally uploading images.
  status <issue> --set <name>   Set the issue's status label (and optionally close/reopen).
  module <issue> --set <names>  Tag which module(s) the issue concerns (additive).

Repo selection (any command): --repo <alias|owner/repo>   default: umbrella
  Aliases: umbrella, reef, claude-scuba, codex-scuba, bubble, starfish,
           sdk (->sdk-typescript), devkit (->devkit-typescript), octopus,
           sponge, office, tui. A value containing '/' is used verbatim.

Common options:
  --dry-run                     Print the gh command(s) without running them.
  --yes                         Confirm a write operation.

Examples:
  issue-tracker.sh list                                   # open umbrella issues
  issue-tracker.sh list --repo reef --state all
  issue-tracker.sh list --label bug --search "scuba"
  issue-tracker.sh view 8                                 # umbrella issue #8 + images
  issue-tracker.sh view 12 --repo starfish --dir /tmp/iss
  issue-tracker.sh create --title "Bug: …" --body-file report.md --module starfish --status triage --yes
  issue-tracker.sh comment 8 --body "Fixed in abc1234" --yes
  issue-tracker.sh comment 8 --body-file proof.md --image screenshot.png --yes
  issue-tracker.sh status 8 --set resolved --close --yes
  issue-tracker.sh module 8 --set bubble,starfish --yes
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
  command -v gh >/dev/null 2>&1 || die "gh CLI not found on PATH"
}

require_gh_image() {
  require_gh
  if gh image --help >/dev/null 2>&1; then
    return 0
  fi
  cat >&2 <<'GHIMAGE'
error: gh-image extension not found.

Install the GitHub image upload extension before using --image:
  gh extension install drogers0/gh-image

Image uploads use GitHub's internal web attachment flow. They require write
access to the target repository and either an active browser GitHub session or
GH_SESSION_TOKEN in the environment.
GHIMAGE
  exit 1
}

require_gh_auth() {
  require_gh
  if gh auth status -h github.com >/dev/null 2>&1 && gh api user --jq .login >/dev/null 2>&1; then
    return 0
  fi
  cat >&2 <<'AUTH'
error: gh is not authenticated for github.com.

Configure GitHub CLI auth before using issue-tracker.sh:
  gh auth login --hostname github.com --scopes repo

For automation, provide a token in GH_TOKEN (or GITHUB_TOKEN) with `repo` scope
(read for list/view; write for comment/status) on the octostaff org.
AUTH
  exit 1
}

require_gh_image_session() {
  require_gh_image
  # Primary path: gh-image extracts the GitHub web session straight from a local
  # browser. This works on a normal desktop and is what we prefer. (If the
  # caller already exported GH_SESSION_TOKEN, check-token validates that instead
  # — also fine.)
  if gh image check-token >/dev/null 2>&1; then
    return 0
  fi
  # Fallback path: some environments can't reach the browser keyring — notably
  # WSL, where gh-image's backend is kwallet-bound and extraction always fails.
  # There, pull GH_SESSION_TOKEN from the skill's gitignored .env and retry. We
  # only do this when the env didn't already supply a token, so an explicit
  # exported value is never clobbered by a stale file. See .env.example.
  local env_file="${SKILL_DIR}/.env"
  if [[ -z "${GH_SESSION_TOKEN:-}" && -f "${env_file}" ]]; then
    set -a
    # shellcheck disable=SC1090
    . "${env_file}"
    set +a
    if [[ -n "${GH_SESSION_TOKEN:-}" ]] && gh image check-token >/dev/null 2>&1; then
      return 0
    fi
  fi
  cat >&2 <<GHIMAGEAUTH
error: gh-image cannot find a valid GitHub web session token.

Image uploads need a GitHub *web session* cookie. gh-image extracts it from a
local browser by default — which works on a normal desktop, but not where it
can't reach the browser keyring (e.g. WSL, whose backend is kwallet-bound).

Fallback: copy the example env file and set your session cookie, then retry:
  cp ${SKILL_DIR}/.env.example ${SKILL_DIR}/.env
  # edit .env and set GH_SESSION_TOKEN — instructions are in the file
Verify it works with:
  GH_SESSION_TOKEN=... gh image check-token     # or rely on the .env fallback

Do not pass session tokens as command arguments; use GH_SESSION_TOKEN (the .env
fallback, or an exported variable) instead.
GHIMAGEAUTH
  exit 1
}

require_confirmation() {
  ((dry_run)) && return 0
  ((assume_yes)) && return 0
  die "$1 is an outward action; re-run with --yes to confirm (or --dry-run to preview)"
}

append_image_separator() {
  local file="$1" last_byte
  [[ -s "${file}" ]] || return 0
  last_byte="$(tail -c 1 "${file}" 2>/dev/null | od -An -tx1 | tr -d '[:space:]')"
  if [[ "${last_byte}" == "0a" ]]; then
    printf '\n' >>"${file}"
  else
    printf '\n\n' >>"${file}"
  fi
}

# Weave uploaded images into an already-written body file.
#
# `gh image` emits one `![basename](url)` line per input file, in the order the
# files were passed. For each image, if the body already references it inline —
# `![alt](<path-you-passed-to---image>)` or `![alt](<basename>)`, the natural way
# to author "put this screenshot HERE" — rewrite that reference to the uploaded
# URL. Images NOT referenced inline are appended at the end (the plain "just
# attach these" flow). This is what makes inline `/tmp/foo.png` references resolve
# instead of rendering broken while the real upload is dumped at the bottom.
#
#   apply_images_to_body <body_file> <uploaded_markdown> <image_path>...
apply_images_to_body() {
  local body_file="$1" uploaded_markdown="$2"; shift 2
  local -a paths=("$@")
  [[ -n "${uploaded_markdown}" ]] || return 0

  # Split `gh image`'s output into parallel line + URL arrays (one per image).
  local -a up_lines=() up_urls=()
  local line url
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    up_lines+=("${line}")
    url="${line#*](}"; url="${url%)}" # ![alt](URL) -> URL
    up_urls+=("${url}")
  done <<<"${uploaded_markdown}"

  # If we can't pair the emitted lines 1:1 with the inputs (unexpected output
  # shape), fall back to appending the whole block so nothing is silently lost.
  if ((${#up_lines[@]} != ${#paths[@]})); then
    append_image_separator "${body_file}"
    printf '%s\n' "${uploaded_markdown}" >>"${body_file}"
    return 0
  fi

  local content; content="$(cat "${body_file}")"
  local -a append_lines=()
  local i p base inlined
  for ((i = 0; i < ${#paths[@]}; i++)); do
    p="${paths[i]}"; url="${up_urls[i]}"; base="$(basename -- "${p}")"; inlined=0
    # Prefer the exact path the caller passed; also accept a bare basename.
    if [[ "${content}" == *"](${p})"* ]]; then
      content="${content//"](${p})"/"](${url})"}"; inlined=1
    fi
    if [[ "${content}" == *"](${base})"* ]]; then
      content="${content//"](${base})"/"](${url})"}"; inlined=1
    fi
    ((inlined)) || append_lines+=("${up_lines[i]}")
  done

  # Rewrite the body with inline substitutions applied (skip when empty so an
  # image-only comment doesn't gain a leading blank line).
  [[ -n "${content}" ]] && printf '%s\n' "${content}" >"${body_file}"
  if ((${#append_lines[@]})); then
    append_image_separator "${body_file}"
    printf '%s\n' "${append_lines[@]}" >>"${body_file}"
  fi
}

# Read a single KEY's value from the skill's .env WITHOUT exporting anything into
# this process. This keeps GH_SESSION_TOKEN's fallback-only semantics intact
# (it must not become a global override) while letting other config — e.g.
# ISSUE_TRACKER_SIGNATURE — live in the same gitignored file.
read_env_value() {
  local key="$1" env_file="${SKILL_DIR}/.env"
  [[ -f "${env_file}" ]] || return 0
  ( set -a; . "${env_file}" 2>/dev/null || true; printf '%s' "${!key-}" )
}

# Resolve the author signature every comment must carry, in priority order:
# the --sign flag, the ISSUE_TRACKER_SIGNATURE env var, then the .env file.
resolve_signature() {
  local override="${1:-}"
  if [[ -n "${override}" ]]; then printf '%s' "${override}"; return 0; fi
  if [[ -n "${ISSUE_TRACKER_SIGNATURE:-}" ]]; then printf '%s' "${ISSUE_TRACKER_SIGNATURE}"; return 0; fi
  read_env_value ISSUE_TRACKER_SIGNATURE
}

# Append the attribution footer so every comment states who posted it.
append_signature() {
  local file="$1" sig="$2"
  append_image_separator "${file}"
  printf '%s\n' "_— posted by ${sig} (via the issue-tracker skill)_" >>"${file}"
}

# Map a short alias to owner/repo. A value with a slash is treated as owner/repo.
resolve_repo() {
  local name="${1:-${DEFAULT_REPO}}"
  case "${name}" in
    */*) printf '%s' "${name}" ;;
    sdk) printf 'octostaff/sdk-typescript' ;;
    devkit) printf 'octostaff/devkit-typescript' ;;
    umbrella | reef | claude-scuba | codex-scuba | bubble | starfish | octopus | sponge | office | tui)
      printf 'octostaff/%s' "${name}"
      ;;
    *) printf 'octostaff/%s' "${name}" ;; # passthrough for any other octostaff repo
  esac
}

# Canonical status vocabulary -> label color (hex, no #).
status_color() {
  case "$1" in
    triage) printf 'ededed' ;;
    investigating) printf 'fbca04' ;;
    in-progress) printf '1d76db' ;;
    blocked) printf 'b60205' ;;
    needs-info) printf 'd876e3' ;;
    resolved) printf '0e8a16' ;;
    wontfix) printf 'ffffff' ;;
    duplicate) printf 'cfd3d7' ;;
    *) printf 'c5def5' ;; # unknown status -> light blue
  esac
}

# The canonical status labels, used to clear a prior status when setting a new
# one (so an issue carries at most one status label at a time).
readonly STATUS_NAMES="triage investigating in-progress blocked needs-info resolved wontfix duplicate"
is_status_name() {
  case " ${STATUS_NAMES} " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

# Module/area labels — which part of the system an issue concerns. Unlike status
# these are additive (an issue may span several). The package set plus a few
# cross-cutting areas; any other name is accepted too. All share one color so
# they still cluster visually despite being prefix-free.
readonly MODULE_NAMES="bubble claude-scuba codex-scuba reef starfish sdk devkit octopus sponge office tui ci deploy docs infra"
readonly MODULE_COLOR="bfdadc"
is_module_name() {
  case " ${MODULE_NAMES} " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

# Split a comma/space-separated list into one item per line.
split_list() {
  printf '%s' "$1" | tr ',' ' ' | tr -s ' ' '\n' | sed '/^$/d'
}

cmd_repos() {
  cat <<'REPOS'
Alias          Repository
-----          ----------
umbrella *     octostaff/umbrella
reef           octostaff/reef
claude-scuba   octostaff/claude-scuba
codex-scuba    octostaff/codex-scuba
bubble         octostaff/bubble
starfish       octostaff/starfish
sdk            octostaff/sdk-typescript
devkit         octostaff/devkit-typescript
octopus        octostaff/octopus
sponge         octostaff/sponge
office         octostaff/office
tui            octostaff/tui
(* default)    any other value is passed through as octostaff/<value>; a value
               containing '/' is used verbatim as owner/repo.
REPOS
}

cmd_list() {
  dry_run=0
  local repo_in="${DEFAULT_REPO}" state="open" limit=30
  local -a passthru=()
  while (($#)); do
    case "$1" in
      --repo | -R)
        shift; (($#)) || die "--repo requires a value"; repo_in="$1" ;;
      --state | -s)
        shift; (($#)) || die "--state requires a value"; state="$1" ;;
      --limit | -n)
        shift; (($#)) || die "--limit requires a value"; limit="$1" ;;
      --label | -l)
        shift; (($#)) || die "--label requires a value"; passthru+=(--label "$1") ;;
      --assignee | -a)
        shift; (($#)) || die "--assignee requires a value"; passthru+=(--assignee "$1") ;;
      --author)
        shift; (($#)) || die "--author requires a value"; passthru+=(--author "$1") ;;
      --search | -S)
        shift; (($#)) || die "--search requires a value"; passthru+=(--search "$1") ;;
      --dry-run) dry_run=1 ;;
      -h | --help)
        echo "Usage: issue-tracker.sh list [--repo R] [--state open|closed|all] [--label L] [--assignee U] [--author U] [--search Q] [--limit N]"
        return 0 ;;
      *) die "Unknown list option: $1" ;;
    esac
    shift
  done
  local repo; repo="$(resolve_repo "${repo_in}")"
  if ((dry_run)); then
    printf '+ gh issue list -R %q --state %q --limit %q' "${repo}" "${state}" "${limit}"
    ((${#passthru[@]})) && printf ' %q' "${passthru[@]}"
    printf '\n'
    return 0
  fi
  require_gh_auth
  gh issue list -R "${repo}" --state "${state}" --limit "${limit}" "${passthru[@]}"
}

cmd_labels() {
  dry_run=0
  local repo_in="${DEFAULT_REPO}"
  while (($#)); do
    case "$1" in
      --repo | -R) shift; (($#)) || die "--repo requires a value"; repo_in="$1" ;;
      --dry-run) dry_run=1 ;;
      -h | --help) echo "Usage: issue-tracker.sh labels [--repo R]"; return 0 ;;
      *) die "Unknown labels option: $1" ;;
    esac
    shift
  done
  local repo; repo="$(resolve_repo "${repo_in}")"
  if ((dry_run)); then
    printf '+ gh label list -R %q --limit 100\n' "${repo}"
    return 0
  fi
  require_gh_auth
  gh label list -R "${repo}" --limit 100
}

# Extract image-like URLs from arbitrary markdown/HTML text on stdin.
extract_image_urls() {
  grep -oE "https?://[^][:space:]\")(<>']+" 2>/dev/null \
    | grep -iE 'user-attachments/assets/|user-images\.githubusercontent\.com|\.(png|jpe?g|gif|webp|bmp|svg)([?#]|$)' \
    | awk '!seen[$0]++' || true
}

mime_to_ext() {
  case "$1" in
    image/png) printf 'png' ;;
    image/jpeg) printf 'jpg' ;;
    image/gif) printf 'gif' ;;
    image/webp) printf 'webp' ;;
    image/bmp) printf 'bmp' ;;
    image/svg+xml) printf 'svg' ;;
    *) printf 'bin' ;;
  esac
}

cmd_view() {
  dry_run=0
  local repo_in="${DEFAULT_REPO}" num="" dir="" no_images=0
  while (($#)); do
    case "$1" in
      --repo | -R) shift; (($#)) || die "--repo requires a value"; repo_in="$1" ;;
      --dir) shift; (($#)) || die "--dir requires a value"; dir="$1" ;;
      --no-images) no_images=1 ;;
      --dry-run) dry_run=1 ;;
      -h | --help)
        echo "Usage: issue-tracker.sh view <issue> [--repo R] [--dir DIR] [--no-images]"
        echo "  Caches issue.json + issue.md + images under cache/<issue> (gitignored) by default."
        return 0 ;;
      -*) die "Unknown view option: $1" ;;
      *) [[ -z "${num}" ]] || die "view takes a single issue number"; num="$1" ;;
    esac
    shift
  done
  [[ -n "${num}" ]] || die "view requires an issue number"
  local repo; repo="$(resolve_repo "${repo_in}")"
  if ((dry_run)); then
    printf '+ gh issue view %q -R %q --json number,title,state,labels,author,assignees,milestone,createdAt,updatedAt,url,body,comments\n' "${num}" "${repo}"
    printf '+ cache -> %q\n' "${dir:-${CACHE_BASE}/${num}}"
    return 0
  fi
  require_gh_auth

  [[ -n "${dir}" ]] || dir="${CACHE_BASE}/${num}"
  mkdir -p "${dir}"

  local json
  json="$(gh issue view "${num}" -R "${repo}" --json number,title,state,labels,author,assignees,milestone,createdAt,updatedAt,url,body,comments)"
  printf '%s' "${json}" >"${dir}/issue.json"

  # Human-readable render of metadata, body, and comments.
  local rendered
  rendered="$(printf '%s' "${json}" | jq -r '
    "#\(.number)  \(.title)",
    "state:     \(.state)",
    "author:    \(.author.login // "?")",
    "assignees: \((.assignees // []) | map(.login) | join(", ") // "-")",
    "labels:    \((.labels // []) | map(.name) | join(", ") // "-")",
    "milestone: \(.milestone.title // "-")",
    "created:   \(.createdAt)   updated: \(.updatedAt)",
    "url:       \(.url)",
    "",
    "──────── body ────────",
    (.body // "(no description)"),
    "",
    "──────── comments (\((.comments // []) | length)) ────────",
    ((.comments // [])[] |
      "\n• \(.author.login // "?")  (\(.createdAt)):\n\(.body)")
  ')"
  printf '%s\n' "${rendered}"
  printf '%s\n' "${rendered}" >"${dir}/issue.md"

  ((no_images)) && { printf '\nCached to %s\n' "${dir}"; return 0; }

  # Clear stale attachments from a previous view of this issue before refetching.
  rm -f "${dir}/issue-${num}-"*.* 2>/dev/null || true

  # Collect image URLs from body + all comment bodies, download them.
  local urls
  urls="$(printf '%s' "${json}" | jq -r '[.body] + [(.comments // [])[].body] | .[] // ""' | extract_image_urls)"
  if [[ -z "${urls}" ]]; then
    printf '\n(no image attachments found)\nCached to %s\n' "${dir}"
    return 0
  fi

  local token=""
  token="$(gh auth token 2>/dev/null || true)"

  printf '\n──────── attachments ────────\n'
  local i=0 url out ext mime
  while IFS= read -r url; do
    [[ -n "${url}" ]] || continue
    i=$((i + 1))
    out="$(printf '%s/issue-%s-%02d' "${dir}" "${num}" "${i}")"
    # Authenticated fetch; curl drops the auth header on cross-host redirect
    # (the signed CDN URL), which is exactly what GitHub's attachment host wants.
    if [[ -n "${token}" ]]; then
      curl -fsSL -H "Authorization: token ${token}" -o "${out}" "${url}" 2>/dev/null \
        || curl -fsSL -o "${out}" "${url}" 2>/dev/null || { printf '  ! failed: %s\n' "${url}"; continue; }
    else
      curl -fsSL -o "${out}" "${url}" 2>/dev/null || { printf '  ! failed: %s\n' "${url}"; continue; }
    fi
    mime="$(file -b --mime-type "${out}" 2>/dev/null || echo application/octet-stream)"
    ext="$(mime_to_ext "${mime}")"
    mv "${out}" "${out}.${ext}"
    printf '  %s\n    <- %s\n' "${out}.${ext}" "${url}"
  done <<<"${urls}"
  printf '\n%d attachment(s) cached under %s\n' "${i}" "${dir}"
  printf 'Read these files to view the images.\n'
}

cmd_comment() {
  dry_run=0
  assume_yes=0
  local repo_in="${DEFAULT_REPO}" num="" body="" body_file="" sign_override=""
  local -a image_paths=()
  local image_count=0
  while (($#)); do
    case "$1" in
      --repo | -R) shift; (($#)) || die "--repo requires a value"; repo_in="$1" ;;
      --body | -b) shift; (($#)) || die "--body requires a value"; body="$1" ;;
      --body-file | -F) shift; (($#)) || die "--body-file requires a value"; body_file="$1" ;;
      --image | --attach) shift; (($#)) || die "--image requires a file path"; image_paths+=("$1"); image_count=$((image_count + 1)) ;;
      --sign | --as) shift; (($#)) || die "--sign requires a value"; sign_override="$1" ;;
      --yes) assume_yes=1 ;;
      --dry-run) dry_run=1 ;;
      -h | --help)
        cat <<'USAGE'
Usage: issue-tracker.sh comment <issue> [--body TEXT | --body-file FILE] [--image FILE ...] [--sign WHO] [--repo R] --yes
  Posts an issue comment. Repeat --image to upload images with gh-image.
  Image-only comments are allowed.

  Inline placement: reference an image in the body with the SAME path you pass
  to --image (or just its basename) — e.g. --image /tmp/a.png alongside
  "![shot](/tmp/a.png)" — and that reference is rewritten to the uploaded URL
  in place. Any --image NOT referenced inline is appended at the end. So don't
  hand-write GitHub asset URLs; point at the local file and let the upload wire
  it up.

  Every comment is signed with who posted it. Provide the signature with
  --sign "Claude Code Opus 4.8" (or "Codex", …), or set ISSUE_TRACKER_SIGNATURE
  in the environment / the skill's .env (see .env.example).
USAGE
        return 0 ;;
      -*) die "Unknown comment option: $1" ;;
      *) [[ -z "${num}" ]] || die "comment takes a single issue number"; num="$1" ;;
    esac
    shift
  done
  [[ -n "${num}" ]] || die "comment requires an issue number"
  [[ -n "${body}" || -n "${body_file}" || ${image_count} -gt 0 ]] || die "comment requires --body, --body-file, or --image"
  [[ -z "${body}" || -z "${body_file}" ]] || die "use only one of --body / --body-file"
  local repo; repo="$(resolve_repo "${repo_in}")"

  local image_path
  if ((image_count)); then
    for image_path in "${image_paths[@]}"; do
      [[ -r "${image_path}" ]] || die "cannot read --image file: ${image_path}"
      [[ -f "${image_path}" ]] || die "--image must be a regular file: ${image_path}"
    done
  fi
  if [[ -n "${body_file}" && "${body_file}" != "-" ]]; then
    [[ -r "${body_file}" ]] || die "cannot read --body-file: ${body_file}"
  fi

  require_confirmation "comment"

  # Every comment must say who posted it. Resolve up front so a dry-run also
  # surfaces (and previews) a missing signature.
  local signature; signature="$(resolve_signature "${sign_override}")"
  [[ -n "${signature}" ]] || die "comment requires a signature identifying who is posting. Provide it via:
  --sign \"Claude Code Opus 4.8\"                       (per call; also \"Codex\", etc.)
  export ISSUE_TRACKER_SIGNATURE=\"...\"                 (per shell)
  set ISSUE_TRACKER_SIGNATURE in ${SKILL_DIR}/.env   (persistent; see .env.example)"

  if ((dry_run)); then
    if ((image_count)); then
      printf '+ gh image --repo %q --' "${repo}"
      printf ' %q' "${image_paths[@]}"
      printf '\n'
    fi
    printf '+ compose comment body'
    [[ -n "${body}" ]] && printf ' from --body'
    [[ -n "${body_file}" ]] && printf ' from --body-file %q' "${body_file}"
    ((image_count)) && printf ' plus uploaded image markdown'
    printf ' plus signature footer (%q)\n' "${signature}"
    printf '+ gh issue comment %q -R %q --body-file <generated>\n' "${num}" "${repo}"
    return 0
  fi
  require_gh_auth

  # Upload images first (if any) so a failed upload aborts before we post.
  local uploaded_markdown=""
  if ((image_count)); then
    require_gh_image_session
    if ! uploaded_markdown="$(gh image --repo "${repo}" -- "${image_paths[@]}")"; then
      die "one or more image uploads failed; comment was not posted"
    fi
    [[ -n "${uploaded_markdown}" ]] || die "image upload produced no markdown; comment was not posted"
  fi

  # Compose the final body: base text, then image markdown, then the signature.
  local tmp_body; tmp_body="$(mktemp "${TMPDIR:-/tmp}/issue-tracker-comment.XXXXXX.md")"
  if [[ -n "${body}" ]]; then
    printf '%s\n' "${body}" >>"${tmp_body}"
  elif [[ -n "${body_file}" ]]; then
    if [[ "${body_file}" == "-" ]]; then
      cat >>"${tmp_body}"
    else
      cat "${body_file}" >>"${tmp_body}"
    fi
  fi
  if [[ -n "${uploaded_markdown}" ]]; then
    apply_images_to_body "${tmp_body}" "${uploaded_markdown}" "${image_paths[@]}"
  fi
  append_signature "${tmp_body}" "${signature}"

  gh issue comment "${num}" -R "${repo}" --body-file "${tmp_body}" \
    || { local rc=$?; rm -f "${tmp_body}"; return "${rc}"; }
  rm -f "${tmp_body}"
}

cmd_status() {
  dry_run=0
  assume_yes=0
  local repo_in="${DEFAULT_REPO}" num="" set_status="" do_close=0 do_reopen=0
  while (($#)); do
    case "$1" in
      --repo | -R) shift; (($#)) || die "--repo requires a value"; repo_in="$1" ;;
      --set) shift; (($#)) || die "--set requires a value"; set_status="$1" ;;
      --close) do_close=1 ;;
      --reopen) do_reopen=1 ;;
      --yes) assume_yes=1 ;;
      --dry-run) dry_run=1 ;;
      -h | --help)
        cat <<'USAGE'
Usage: issue-tracker.sh status <issue> --set <name> [--repo R] [--close] [--reopen] --yes
  Sets a single status label (replacing any existing canonical status label),
  creating the label if missing. Canonical names:
    triage investigating in-progress blocked needs-info resolved wontfix duplicate
  (any other name is accepted too). --close/--reopen also change issue state.
USAGE
        return 0 ;;
      -*) die "Unknown status option: $1" ;;
      *) [[ -z "${num}" ]] || die "status takes a single issue number"; num="$1" ;;
    esac
    shift
  done
  [[ -n "${num}" ]] || die "status requires an issue number"
  [[ -n "${set_status}" ]] || die "status requires --set <name>"
  ((do_close && do_reopen)) && die "--close and --reopen are mutually exclusive"
  # Tolerate a leading status: if the user typed it; the label itself is bare.
  set_status="${set_status#status:}"
  local repo; repo="$(resolve_repo "${repo_in}")"
  local new_label="${set_status}"
  local color; color="$(status_color "${set_status}")"

  require_confirmation "status"
  if ((dry_run)); then
    printf '+ gh label create %q -R %q -c %q  (if missing)\n' "${new_label}" "${repo}" "${color}"
    printf '+ remove any other canonical status label, then\n'
    printf '+ gh issue edit %q -R %q --add-label %q\n' "${num}" "${repo}" "${new_label}"
    ((do_close)) && printf '+ gh issue close %q -R %q\n' "${num}" "${repo}"
    ((do_reopen)) && printf '+ gh issue reopen %q -R %q\n' "${num}" "${repo}"
    return 0
  fi
  require_gh_auth

  # Create the label only if absent (no --force, so existing label colors and
  # descriptions are left untouched).
  gh label create "${new_label}" -R "${repo}" -c "${color}" \
    -d "Status: ${set_status}" >/dev/null 2>&1 || true

  # Drop any other canonical status label currently on the issue.
  local current
  current="$(gh issue view "${num}" -R "${repo}" --json labels \
    --jq '.labels[].name' 2>/dev/null || true)"
  local -a remove=()
  local lbl
  while IFS= read -r lbl; do
    [[ -n "${lbl}" && "${lbl}" != "${new_label}" ]] && is_status_name "${lbl}" \
      && remove+=(--remove-label "${lbl}")
  done <<<"${current}"

  log "Setting ${repo}#${num} -> ${new_label}"
  gh issue edit "${num}" -R "${repo}" --add-label "${new_label}" "${remove[@]}"
  ((do_close)) && gh issue close "${num}" -R "${repo}"
  ((do_reopen)) && gh issue reopen "${num}" -R "${repo}"
  return 0
}

cmd_module() {
  dry_run=0
  assume_yes=0
  local repo_in="${DEFAULT_REPO}" num="" set_list="" add_list="" remove_list=""
  while (($#)); do
    case "$1" in
      --repo | -R) shift; (($#)) || die "--repo requires a value"; repo_in="$1" ;;
      --set) shift; (($#)) || die "--set requires a value"; set_list+=" $1" ;;
      --add) shift; (($#)) || die "--add requires a value"; add_list+=" $1" ;;
      --remove) shift; (($#)) || die "--remove requires a value"; remove_list+=" $1" ;;
      --yes) assume_yes=1 ;;
      --dry-run) dry_run=1 ;;
      -h | --help)
        cat <<'USAGE'
Usage: issue-tracker.sh module <issue> (--set <m,...> | --add <m,...> | --remove <m,...>) [--repo R] --yes
  Tag which module(s) an issue concerns (additive — an issue may span several).
  --set replaces the whole module set (drops other canonical module labels);
  --add / --remove adjust incrementally. Values are comma/space lists, repeatable.
  Canonical modules:
    bubble claude-scuba codex-scuba reef starfish sdk devkit octopus sponge
    office tui ci deploy docs infra
  (any other name is accepted too).
USAGE
        return 0 ;;
      -*) die "Unknown module option: $1" ;;
      *) [[ -z "${num}" ]] || die "module takes a single issue number"; num="$1" ;;
    esac
    shift
  done
  [[ -n "${num}" ]] || die "module requires an issue number"
  if [[ -n "${set_list}" && ( -n "${add_list}" || -n "${remove_list}" ) ]]; then
    die "--set is exclusive with --add/--remove"
  fi
  [[ -n "${set_list}${add_list}${remove_list}" ]] || die "module requires --set, --add, or --remove"
  local repo; repo="$(resolve_repo "${repo_in}")"

  # Build the explicit add and remove sets.
  local -a add=() remove=()
  local m
  while IFS= read -r m || [[ -n "${m}" ]]; do [[ -n "${m}" ]] && add+=("${m}"); done < <(split_list "${set_list}${add_list}")
  while IFS= read -r m || [[ -n "${m}" ]]; do [[ -n "${m}" ]] && remove+=("${m}"); done < <(split_list "${remove_list}")

  # For --set, also drop any other canonical module label currently on the issue.
  if [[ -n "${set_list}" && ${dry_run} -eq 0 ]]; then
    local current
    current="$(gh issue view "${num}" -R "${repo}" --json labels --jq '.labels[].name' 2>/dev/null || true)"
    local lbl keep
    while IFS= read -r lbl; do
      [[ -n "${lbl}" ]] || continue
      is_module_name "${lbl}" || continue
      keep=0
      for m in "${add[@]}"; do [[ "${lbl}" == "${m}" ]] && keep=1 && break; done
      ((keep)) || remove+=("${lbl}")
    done <<<"${current}"
  fi

  require_confirmation "module"
  if ((dry_run)); then
    for m in "${add[@]}"; do printf '+ gh label create %q -R %q -c %q  (if missing)\n' "${m}" "${repo}" "${MODULE_COLOR}"; done
    [[ -n "${set_list}" ]] && printf '+ (--set) also remove other canonical module labels on the issue\n'
    printf '+ gh issue edit %q -R %q' "${num}" "${repo}"
    for m in "${add[@]}"; do printf ' --add-label %q' "${m}"; done
    for m in "${remove[@]}"; do printf ' --remove-label %q' "${m}"; done
    printf '\n'
    return 0
  fi
  require_gh_auth

  # Create each added label if absent (existing labels keep their color/desc).
  for m in "${add[@]}"; do
    gh label create "${m}" -R "${repo}" -c "${MODULE_COLOR}" -d "Module: ${m}" >/dev/null 2>&1 || true
  done

  local -a edit_args=()
  for m in "${add[@]}"; do edit_args+=(--add-label "${m}"); done
  for m in "${remove[@]}"; do edit_args+=(--remove-label "${m}"); done
  ((${#edit_args[@]})) || { log "nothing to change"; return 0; }
  log "Tagging modules on ${repo}#${num}"
  gh issue edit "${num}" -R "${repo}" "${edit_args[@]}"
  return 0
}

cmd_create() {
  dry_run=0
  assume_yes=0
  local repo_in="${DEFAULT_REPO}" title="" body="" body_file="" sign_override=""
  local status_name="" module_list="" milestone=""
  local -a image_paths=() plain_labels=() assignees=()
  while (($#)); do
    case "$1" in
      --repo | -R) shift; (($#)) || die "--repo requires a value"; repo_in="$1" ;;
      --title | -t) shift; (($#)) || die "--title requires a value"; title="$1" ;;
      --body | -b) shift; (($#)) || die "--body requires a value"; body="$1" ;;
      --body-file | -F) shift; (($#)) || die "--body-file requires a value"; body_file="$1" ;;
      --image | --attach) shift; (($#)) || die "--image requires a file path"; image_paths+=("$1") ;;
      --label | -l) shift; (($#)) || die "--label requires a value"; plain_labels+=("$1") ;;
      --module | -m) shift; (($#)) || die "--module requires a value"; module_list+=" $1" ;;
      --status | -s) shift; (($#)) || die "--status requires a value"; status_name="$1" ;;
      --assignee | -a) shift; (($#)) || die "--assignee requires a value"; assignees+=("$1") ;;
      --milestone) shift; (($#)) || die "--milestone requires a value"; milestone="$1" ;;
      --sign | --as) shift; (($#)) || die "--sign requires a value"; sign_override="$1" ;;
      --yes) assume_yes=1 ;;
      --dry-run) dry_run=1 ;;
      -h | --help)
        cat <<'USAGE'
Usage: issue-tracker.sh create --title TEXT [--body TEXT | --body-file FILE]
         [--image FILE ...] [--label L ...] [--module m,...] [--status NAME]
         [--assignee U ...] [--milestone M] [--sign WHO] [--repo R] --yes

  Open a new issue. --module / --status tag it with the canonical module and
  status labels (created if missing, same vocabulary as the module/status
  commands); --label attaches arbitrary labels (also created if missing).
  Repeat --image to upload screenshots with gh-image. An image referenced in
  the body by the path you pass to --image (or its basename) is rewritten to
  the uploaded URL in place; any --image not referenced inline is appended.

  Like comment, the body is signed with who filed it. Provide the signature
  with --sign "Claude Code Opus 4.8", or set ISSUE_TRACKER_SIGNATURE in the
  environment / the skill's .env (see .env.example).
USAGE
        return 0 ;;
      -*) die "Unknown create option: $1" ;;
      *) die "create takes no positional arguments (did you mean --title?)" ;;
    esac
    shift
  done
  [[ -n "${title}" ]] || die "create requires --title"
  [[ -z "${body}" || -z "${body_file}" ]] || die "use only one of --body / --body-file"
  local repo; repo="$(resolve_repo "${repo_in}")"

  local image_path
  for image_path in "${image_paths[@]}"; do
    [[ -r "${image_path}" ]] || die "cannot read --image file: ${image_path}"
    [[ -f "${image_path}" ]] || die "--image must be a regular file: ${image_path}"
  done
  if [[ -n "${body_file}" && "${body_file}" != "-" ]]; then
    [[ -r "${body_file}" ]] || die "cannot read --body-file: ${body_file}"
  fi
  # Tolerate a leading status: if the user typed it; the label itself is bare.
  status_name="${status_name#status:}"

  require_confirmation "create"

  # The issue body is signed just like a comment, so the tracker stays
  # attributable. Resolve up front so a dry-run also catches a missing one.
  local signature; signature="$(resolve_signature "${sign_override}")"
  [[ -n "${signature}" ]] || die "create requires a signature identifying who is filing the issue. Provide it via:
  --sign \"Claude Code Opus 4.8\"                       (per call; also \"Codex\", etc.)
  export ISSUE_TRACKER_SIGNATURE=\"...\"                 (per shell)
  set ISSUE_TRACKER_SIGNATURE in ${SKILL_DIR}/.env   (persistent; see .env.example)"

  # Expand the module list and assemble the full set of labels to attach. The
  # creation pass below colors each by kind (module / status / bare label).
  local -a modules=() attach_labels=()
  local m l
  while IFS= read -r m || [[ -n "${m}" ]]; do [[ -n "${m}" ]] && modules+=("${m}"); done < <(split_list "${module_list}")
  for l in "${plain_labels[@]}"; do attach_labels+=("${l}"); done
  for m in "${modules[@]}"; do attach_labels+=("${m}"); done
  [[ -n "${status_name}" ]] && attach_labels+=("${status_name}")

  if ((dry_run)); then
    if ((${#image_paths[@]})); then
      printf '+ gh image --repo %q --' "${repo}"
      printf ' %q' "${image_paths[@]}"
      printf '\n'
    fi
    for l in "${plain_labels[@]}"; do printf '+ gh label create %q -R %q -c ededed  (if missing)\n' "${l}" "${repo}"; done
    for m in "${modules[@]}"; do printf '+ gh label create %q -R %q -c %q  (if missing)\n' "${m}" "${repo}" "${MODULE_COLOR}"; done
    [[ -n "${status_name}" ]] && printf '+ gh label create %q -R %q -c %q  (if missing)\n' "${status_name}" "${repo}" "$(status_color "${status_name}")"
    printf '+ compose issue body'
    [[ -n "${body}" ]] && printf ' from --body'
    [[ -n "${body_file}" ]] && printf ' from --body-file %q' "${body_file}"
    ((${#image_paths[@]})) && printf ' plus uploaded image markdown'
    printf ' plus signature footer (%q)\n' "${signature}"
    printf '+ gh issue create -R %q --title %q --body-file <generated>' "${repo}" "${title}"
    for l in "${attach_labels[@]}"; do printf ' --label %q' "${l}"; done
    local a
    for a in "${assignees[@]}"; do printf ' --assignee %q' "${a}"; done
    [[ -n "${milestone}" ]] && printf ' --milestone %q' "${milestone}"
    printf '\n'
    return 0
  fi
  require_gh_auth

  # Upload images first (if any) so a failed upload aborts before we create.
  local uploaded_markdown=""
  if ((${#image_paths[@]})); then
    require_gh_image_session
    if ! uploaded_markdown="$(gh image --repo "${repo}" -- "${image_paths[@]}")"; then
      die "one or more image uploads failed; issue was not created"
    fi
    [[ -n "${uploaded_markdown}" ]] || die "image upload produced no markdown; issue was not created"
  fi

  # Compose the body: base text, then image markdown, then the signature.
  local tmp_body; tmp_body="$(mktemp "${TMPDIR:-/tmp}/issue-tracker-create.XXXXXX.md")"
  if [[ -n "${body}" ]]; then
    printf '%s\n' "${body}" >>"${tmp_body}"
  elif [[ -n "${body_file}" ]]; then
    if [[ "${body_file}" == "-" ]]; then
      cat >>"${tmp_body}"
    else
      cat "${body_file}" >>"${tmp_body}"
    fi
  fi
  if [[ -n "${uploaded_markdown}" ]]; then
    apply_images_to_body "${tmp_body}" "${uploaded_markdown}" "${image_paths[@]}"
  fi
  append_signature "${tmp_body}" "${signature}"

  # Create any labels that may not exist yet (no --force; existing labels keep
  # their color/description). Mirrors status/module label creation.
  for l in "${plain_labels[@]}"; do
    gh label create "${l}" -R "${repo}" -c "ededed" >/dev/null 2>&1 || true
  done
  for m in "${modules[@]}"; do
    gh label create "${m}" -R "${repo}" -c "${MODULE_COLOR}" -d "Module: ${m}" >/dev/null 2>&1 || true
  done
  if [[ -n "${status_name}" ]]; then
    gh label create "${status_name}" -R "${repo}" -c "$(status_color "${status_name}")" -d "Status: ${status_name}" >/dev/null 2>&1 || true
  fi

  local -a create_args=(--title "${title}" --body-file "${tmp_body}")
  for l in "${attach_labels[@]}"; do create_args+=(--label "${l}"); done
  local a
  for a in "${assignees[@]}"; do create_args+=(--assignee "${a}"); done
  [[ -n "${milestone}" ]] && create_args+=(--milestone "${milestone}")

  log "Creating issue on ${repo}"
  gh issue create -R "${repo}" "${create_args[@]}" \
    || { local rc=$?; rm -f "${tmp_body}"; return "${rc}"; }
  rm -f "${tmp_body}"
}

cmd_doctor() {
  local repo_in="${DEFAULT_REPO}" do_live=0 live_yes=0
  while (($#)); do
    case "$1" in
      --repo | -R) shift; (($#)) || die "--repo requires a value"; repo_in="$1" ;;
      --live) do_live=1 ;;
      --yes) live_yes=1 ;;
      -h | --help)
        cat <<'DOC'
Usage: issue-tracker.sh doctor [--repo R] [--live --yes]

Sanity-check this machine's setup for posting issue comments with images.
Read-only by default: verifies gh auth, the gh-image extension, and that a
GitHub web session token resolves (browser session, an exported
GH_SESSION_TOKEN, or the gitignored .env fallback). Reports which path worked.

With --live --yes it also performs ONE real throwaway upload end-to-end. Note:
gh-image has no delete API, so a live upload leaves a tiny unreferenced image
on GitHub's CDN. The default (token-validating) check is enough for most uses.
DOC
        return 0 ;;
      *) die "Unknown doctor option: $1" ;;
    esac
    shift
  done
  local repo; repo="$(resolve_repo "${repo_in}")"

  local fails=0
  log "checking image-upload setup…"

  # 1. gh CLI present + authenticated for github.com.
  local login=""
  if login="$(gh api user --jq .login 2>/dev/null)" && [[ -n "${login}" ]]; then
    printf '  ok    gh authenticated (user: %s)\n' "${login}"
  else
    printf '  FAIL  gh not authenticated for github.com — run: gh auth login -h github.com\n'
    fails=$((fails + 1))
  fi

  # 2. gh-image extension installed. Token + upload checks below need it.
  local have_image=0
  if gh image --help >/dev/null 2>&1; then
    printf '  ok    gh-image extension installed\n'
    have_image=1
  else
    printf '  FAIL  gh-image not installed — run: gh extension install drogers0/gh-image\n'
    fails=$((fails + 1))
  fi

  # 3. A GitHub web session token must resolve. Mirror require_gh_image_session:
  # try tokenless extraction first (browser / exported var stays primary), then
  # fall back to the skill's .env. Report which path won.
  local token_ok=0
  if ((have_image)); then
    local user=""
    if user="$(gh image check-token 2>/dev/null)" && [[ -n "${user}" ]]; then
      local via="browser session"
      [[ -n "${GH_SESSION_TOKEN:-}" ]] && via="exported GH_SESSION_TOKEN"
      printf '  ok    web session token valid via %s (user: %s)\n' "${via}" "${user}"
      token_ok=1
    else
      local env_file="${SKILL_DIR}/.env"
      if [[ -z "${GH_SESSION_TOKEN:-}" && -f "${env_file}" ]]; then
        set -a
        # shellcheck disable=SC1090
        . "${env_file}"
        set +a
        if [[ -n "${GH_SESSION_TOKEN:-}" ]] && user="$(gh image check-token 2>/dev/null)" && [[ -n "${user}" ]]; then
          printf '  ok    web session token valid via .env fallback (user: %s)\n' "${user}"
          token_ok=1
        fi
      fi
    fi
    if ((! token_ok)); then
      printf '  FAIL  no valid web session token (browser extraction failed, no working .env)\n'
      printf '        fallback: cp %s/.env.example %s/.env and set GH_SESSION_TOKEN (see that file)\n' "${SKILL_DIR}" "${SKILL_DIR}"
      fails=$((fails + 1))
    fi
  fi

  # 4. Optional real upload — the only 100% check, but it's an outward write.
  if ((do_live)); then
    if ((! token_ok)); then
      printf '  skip  live upload — no valid token to upload with\n'
    elif ((! live_yes)); then
      die "doctor --live performs a real upload (leaves a small orphaned asset on GitHub); re-run with --yes"
    else
      local img out
      img="$(mktemp "${TMPDIR:-/tmp}/issue-tracker-doctor.XXXXXX.png")"
      # 1x1 transparent PNG so GitHub accepts the attachment.
      printf 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==\n' \
        | base64 -d >"${img}" 2>/dev/null || true
      if out="$(gh image --repo "${repo}" -- "${img}" 2>/dev/null)" \
        && grep -qiE 'user-attachments/assets/|githubusercontent' <<<"${out}"; then
        printf '  ok    live upload to %s succeeded\n' "${repo}"
      else
        printf '  FAIL  live upload to %s failed\n' "${repo}"
        fails=$((fails + 1))
      fi
      rm -f "${img}"
    fi
  fi

  printf '\n'
  if ((fails)); then
    die "${fails} check(s) failed — see above"
  fi
  local extra=""
  ((do_live)) && extra=" (incl. live upload)"
  log "all checks passed${extra} — image uploads should work"
}

main() {
  [[ $# -gt 0 ]] || { usage; exit 1; }
  local cmd="$1"; shift
  case "${cmd}" in
    list) cmd_list "$@" ;;
    view) cmd_view "$@" ;;
    create | new) cmd_create "$@" ;;
    comment) cmd_comment "$@" ;;
    status) cmd_status "$@" ;;
    module) cmd_module "$@" ;;
    labels) cmd_labels "$@" ;;
    repos) cmd_repos "$@" ;;
    doctor) cmd_doctor "$@" ;;
    help | -h | --help) usage ;;
    *) die "unknown command '${cmd}' (try: issue-tracker.sh help)" ;;
  esac
}

main "$@"
