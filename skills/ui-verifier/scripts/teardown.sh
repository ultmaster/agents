#!/usr/bin/env bash
# Stop only processes whose identity matches a state file written by launch.sh.
set -uo pipefail

usage() {
  cat <<'EOF'
Usage: teardown.sh [--state FILE] [--dry-run]

Options:
  --state FILE   State file written by launch.sh (required unless one argument is supplied)
  --dry-run      Show verified owned processes without signaling or removing files
  -h, --help     Show this help

An absent state file is a successful no-op. The script never kills a process
merely because it listens on a recorded port.
EOF
}

die() { echo "teardown.sh: $*" >&2; exit 2; }

STATE=''
DRY_RUN=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --state) [ "$#" -ge 2 ] || die '--state requires a value'; STATE=$2; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --*) die "unknown argument: $1" ;;
    *) [ -z "$STATE" ] || die 'state file specified more than once'; STATE=$1; shift ;;
  esac
done
[ -n "$STATE" ] || die '--state FILE is required'

if [ ! -f "$STATE" ]; then
  echo "no state file at $STATE; nothing to tear down"
  exit 0
fi

VERSION=''
RUN_ID=''
LAUNCH_PID=''
LAUNCH_ID=''
PGID=''
LOG=''
PORTS=()

while IFS= read -r line || [ -n "$line" ]; do
  key=${line%%=*}
  value=${line#*=}
  [ "$key" != "$line" ] || die "malformed state line: $line"
  case "$key" in
    VERSION) VERSION=$value ;;
    RUN_ID) RUN_ID=$value ;;
    LAUNCH_PID) LAUNCH_PID=$value ;;
    LAUNCH_ID) LAUNCH_ID=$value ;;
    PGID) PGID=$value ;;
    LOG) LOG=$value ;;
    PORT) PORTS+=("$value") ;;
    CWD|HEALTH_URL) ;;
    *) die "unknown state key: $key" ;;
  esac
done < "$STATE"

[ "$VERSION" = 1 ] || die 'unsupported or missing state version'
[[ "$RUN_ID" =~ ^[A-Za-z0-9._-]+$ ]] || die 'invalid or missing run identity'
[[ "$LAUNCH_PID" =~ ^[1-9][0-9]*$ ]] || die 'invalid or missing launcher PID'
[[ "$PGID" =~ ^[1-9][0-9]*$ ]] || die 'invalid or missing process group'
[ "$PGID" = "$LAUNCH_PID" ] || die 'state does not describe an isolated launcher process group'
[ -n "$LAUNCH_ID" ] || die 'missing launcher process identity'
for port in "${PORTS[@]}"; do
  [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || die "invalid recorded port: $port"
done
process_id() {
  local pid=$1 line rest
  if [ -r "/proc/$pid/stat" ]; then
    IFS= read -r line < "/proc/$pid/stat" || return 1
    rest=${line##*) }
    awk '{print $20}' <<<"$rest"
  else
    ps -p "$pid" -o lstart= 2>/dev/null | cksum | awk '{print $1}'
  fi
}

has_run_token() {
  local pid=$1 arg
  if [ -r "/proc/$pid/environ" ]; then
    while IFS= read -r -d '' arg; do
      [ "$arg" = "UI_VERIFIER_RUN_ID=$RUN_ID" ] && return 0
    done < "/proc/$pid/environ"
    return 1
  fi
  # Without a readable environment, only the still-live launcher can be proven
  # by its recorded start identity. Refuse to infer ownership of descendants.
  [ "$pid" = "$LAUNCH_PID" ] && [ "$(process_id "$pid" 2>/dev/null)" = "$LAUNCH_ID" ]
}

collect_owned() {
  local pid pgid
  while read -r pid pgid; do
    [[ "$pid" =~ ^[0-9]+$ && "$pgid" =~ ^[0-9]+$ ]] || continue
    [ "$pgid" = "$PGID" ] || continue
    has_run_token "$pid" && printf '%s\n' "$pid"
  done < <(ps -eo pid=,pgid= 2>/dev/null)
}

if kill -0 "$LAUNCH_PID" 2>/dev/null; then
  current_id=$(process_id "$LAUNCH_PID" 2>/dev/null || true)
  [ "$current_id" = "$LAUNCH_ID" ] || die "PID $LAUNCH_PID was reused; refusing to signal it or its process group"
  has_run_token "$LAUNCH_PID" || die "launcher PID $LAUNCH_PID lacks the recorded run token; refusing to signal"
fi

mapfile -t owned < <(collect_owned | sort -n -u)
printf 'recorded run %s; owned processes:' "$RUN_ID"
if [ "${#owned[@]}" -eq 0 ]; then printf ' <none>\n'; else printf ' %s' "${owned[@]}"; printf '\n'; fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo 'dry run; no signals sent and state retained'
  exit 0
fi

signal_owned() {
  local signal=$1 pid
  shift
  for pid in "$@"; do
    [ "$pid" = "$$" ] && continue
    kill "-$signal" "$pid" 2>/dev/null || true
  done
}

[ "${#owned[@]}" -eq 0 ] || signal_owned TERM "${owned[@]}"
for _ in 1 2 3 4 5; do
  sleep 1
  mapfile -t owned < <(collect_owned | sort -n -u)
  [ "${#owned[@]}" -eq 0 ] && break
done
[ "${#owned[@]}" -eq 0 ] || signal_owned KILL "${owned[@]}"
sleep 1
mapfile -t owned < <(collect_owned | sort -n -u)
if [ "${#owned[@]}" -gt 0 ]; then
  echo "teardown.sh: owned processes survived: ${owned[*]}" >&2
  exit 1
fi

ss_listeners() {
  local output
  output=$(ss -ltnH 2>&1) || return 1
  if [ -n "$output" ] && ! awk 'NF && $1 != "LISTEN" { exit 1 }' <<<"$output"; then
    return 1
  fi
  printf '%s\n' "$output"
}

port_busy() {
  local port=$1 output status
  if command -v ss >/dev/null 2>&1 && output=$(ss_listeners); then
    awk -v p="$port" '{ a=$4; if (a ~ (":" p "$") || a ~ ("\\." p "$")) found=1 } END { exit !found }' <<<"$output"
    return
  fi
  if command -v lsof >/dev/null 2>&1; then
    if output=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>&1); then
      return 0
    else
      status=$?
    fi
    [ "$status" -eq 1 ] && [ -z "$output" ] && return 1
  fi
  die 'could not inspect listening ports with ss or lsof; run through the harness approved host-execution path'
}

busy=()
for port in "${PORTS[@]}"; do
  port_busy "$port" && busy+=("$port")
done
if [ "${#busy[@]}" -gt 0 ]; then
  echo "teardown.sh: recorded ports still busy: ${busy[*]}" >&2
  echo 'Their current listeners were not proven to belong to this run and were left untouched.' >&2
  exit 1
fi

rm -f "$STATE"
echo 'owned processes stopped, recorded ports are free, and state was removed'
