#!/usr/bin/env bash
# Launch a caller-specified application in its own session, wait for explicit
# health URLs, and record enough identity to tear down only this run.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  launch.sh --command CMD --port PORT --health-url URL [options]

Required (repeat --port and --health-url for multi-service stacks):
  --command CMD       Shell command that launches the complete application
  --port PORT         TCP port the launched application is expected to own
  --health-url URL    HTTP(S) URL that must answer successfully

Options:
  --cwd DIR           Working directory for CMD (default: current directory)
  --state FILE        State file for teardown.sh (default: per-directory /tmp file)
  --log FILE          Combined stdout/stderr log (default: beside state file)
  --timeout SECONDS   Startup timeout (default: 120)
  --foreground        Remain attached after readiness; tear down on exit/signal
  --dry-run           Validate and print the plan without writing or launching
  -h, --help          Show this help

CMD is evaluated by bash. Quote it as one argument and do not include secrets.
All ports are explicit: this script never guesses, advances, or reuses a busy port.
EOF
}

die() { echo "launch.sh: $*" >&2; exit 2; }

COMMAND=''
CWD=$PWD
STATE=''
LOG=''
TIMEOUT=120
FOREGROUND=0
DRY_RUN=0
PORTS=()
HEALTH_URLS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command) [ "$#" -ge 2 ] || die '--command requires a value'; COMMAND=$2; shift 2 ;;
    --cwd) [ "$#" -ge 2 ] || die '--cwd requires a value'; CWD=$2; shift 2 ;;
    --state) [ "$#" -ge 2 ] || die '--state requires a value'; STATE=$2; shift 2 ;;
    --log) [ "$#" -ge 2 ] || die '--log requires a value'; LOG=$2; shift 2 ;;
    --port) [ "$#" -ge 2 ] || die '--port requires a value'; PORTS+=("$2"); shift 2 ;;
    --health-url) [ "$#" -ge 2 ] || die '--health-url requires a value'; HEALTH_URLS+=("$2"); shift 2 ;;
    --timeout) [ "$#" -ge 2 ] || die '--timeout requires a value'; TIMEOUT=$2; shift 2 ;;
    --foreground) FOREGROUND=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$COMMAND" ] || die '--command is required'
[ "${#PORTS[@]}" -gt 0 ] || die 'at least one --port is required'
[ "${#HEALTH_URLS[@]}" -gt 0 ] || die 'at least one --health-url is required'
[ -d "$CWD" ] || die "working directory does not exist: $CWD"
[[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die '--timeout must be a positive integer'
command -v curl >/dev/null 2>&1 || die 'curl is required'
command -v setsid >/dev/null 2>&1 || die 'setsid is required to isolate the process group safely'

CWD=$(cd "$CWD" && pwd -P)
if [ -z "$STATE" ]; then
  root_id=$(printf '%s' "$CWD" | cksum | awk '{print $1}')
  STATE="${TMPDIR:-/tmp}/ui-verifier/stack-$root_id.state"
fi
if [ -z "$LOG" ]; then
  LOG="${STATE%.state}-$(date +%Y%m%d-%H%M%S)-$$.log"
  [ "$LOG" != "$STATE" ] || LOG="$STATE-$(date +%Y%m%d-%H%M%S)-$$.log"
fi

case "$STATE$LOG$COMMAND$CWD" in *$'\n'*) die 'paths and command must not contain newlines' ;; esac
for url in "${HEALTH_URLS[@]}"; do
  case "$url" in
    http://*|https://*) ;;
    *) die "health URL must use http:// or https://: $url" ;;
  esac
  case "$url" in *$'\n'*) die 'health URL must not contain newlines' ;; esac
done

declare -A seen_ports=()
for port in "${PORTS[@]}"; do
  [[ "$port" =~ ^[0-9]+$ ]] || die "invalid port: $port"
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || die "port out of range: $port"
  [ -z "${seen_ports[$port]:-}" ] || die "duplicate port: $port"
  seen_ports[$port]=1
done

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

for port in "${PORTS[@]}"; do
  port_busy "$port" && die "port $port is already occupied; choose another and leave its owner alone"
done
[ ! -e "$STATE" ] || die "state file already exists: $STATE (tear it down or choose another path)"
[ ! -e "$LOG" ] || die "log file already exists: $LOG (choose another path; it will not be overwritten)"

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'dry run; no process will be launched\n'
  printf '  cwd: %s\n  command: %s\n  state: %s\n  log: %s\n' "$CWD" "$COMMAND" "$STATE" "$LOG"
  printf '  ports:'; printf ' %s' "${PORTS[@]}"; printf '\n'
  printf '  health URLs:\n'; printf '    %s\n' "${HEALTH_URLS[@]}"
  printf '  mode: %s\n' "$([ "$FOREGROUND" -eq 1 ] && printf foreground || printf detached)"
  exit 0
fi

mkdir -p "$(dirname "$STATE")" "$(dirname "$LOG")"
( set -o noclobber; : > "$STATE" ) 2>/dev/null || die "could not reserve state file: $STATE"
chmod 600 "$STATE"
( set -o noclobber; : > "$LOG" ) 2>/dev/null || {
  rm -f "$STATE"
  die "could not reserve log file: $LOG"
}
chmod 600 "$LOG"

random_token() {
  if command -v od >/dev/null 2>&1; then
    od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
  else
    printf '%s-%s-%s' "$$" "$(date +%s)" "$RANDOM"
  fi
}

RUN_ID=$(random_token)
export UI_VERIFIER_RUN_ID=$RUN_ID

if [ "$FOREGROUND" -eq 1 ]; then
  setsid bash -lc 'cd "$1" && exec bash -lc "$2"' bash "$CWD" "$COMMAND" >"$LOG" 2>&1 &
else
  nohup setsid bash -lc 'cd "$1" && exec bash -lc "$2"' bash "$CWD" "$COMMAND" >"$LOG" 2>&1 &
fi
LAUNCH_PID=$!
if [ "$FOREGROUND" -eq 0 ]; then disown "$LAUNCH_PID" 2>/dev/null || true; fi

# Until the complete state file exists, any failure must stop the exact process
# just launched. Otherwise a failed identity probe can leave an untracked app.
cleanup_before_state() {
  local status=$?
  trap - EXIT INT TERM
  if [ "${PGID:-}" = "$LAUNCH_PID" ]; then
    kill -TERM -- "-$PGID" 2>/dev/null || true
    sleep 0.2
    kill -KILL -- "-$PGID" 2>/dev/null || true
  else
    kill -TERM "$LAUNCH_PID" 2>/dev/null || true
    sleep 0.2
    kill -KILL "$LAUNCH_PID" 2>/dev/null || true
  fi
  rm -f "$STATE"
  exit "$status"
}
trap cleanup_before_state EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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

sleep 0.05
kill -0 "$LAUNCH_PID" 2>/dev/null || {
  echo "launch.sh: command exited immediately; log follows" >&2
  tail -n 40 "$LOG" >&2 || true
  rm -f "$STATE"
  exit 1
}
PGID=$(ps -o pgid= -p "$LAUNCH_PID" 2>/dev/null | tr -d ' ')
[[ "$PGID" =~ ^[0-9]+$ ]] || die 'could not determine launcher process group'
[ "$PGID" = "$LAUNCH_PID" ] || die "launcher did not become an isolated process-group leader (pid $LAUNCH_PID, pgid $PGID)"
LAUNCH_ID=$(process_id "$LAUNCH_PID") || die 'could not record launcher process identity'

{
  printf 'VERSION=1\nRUN_ID=%s\nLAUNCH_PID=%s\nLAUNCH_ID=%s\nPGID=%s\n' "$RUN_ID" "$LAUNCH_PID" "$LAUNCH_ID" "$PGID"
  printf 'CWD=%s\nLOG=%s\n' "$CWD" "$LOG"
  printf 'PORT=%s\n' "${PORTS[@]}"
  printf 'HEALTH_URL=%s\n' "${HEALTH_URLS[@]}"
} > "$STATE"
trap - EXIT INT TERM

TEARDOWN=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/teardown.sh
cleanup_on_failure() {
  if ! "$TEARDOWN" --state "$STATE"; then
    echo "launch.sh: automatic teardown failed; inspect and retain state at $STATE" >&2
    return 1
  fi
}
fail() {
  echo "launch.sh: $*" >&2
  echo "--- last 40 log lines ($LOG) ---" >&2
  tail -n 40 "$LOG" >&2 || true
  if ! cleanup_on_failure; then :; fi
  exit 1
}

deadline=$((SECONDS + TIMEOUT))
while :; do
  all_ready=1
  for url in "${HEALTH_URLS[@]}"; do
    curl -fsS --max-time 2 "$url" >/dev/null 2>&1 || all_ready=0
  done
  [ "$all_ready" -eq 1 ] && break
  kill -0 "$LAUNCH_PID" 2>/dev/null || fail 'launcher exited before all health checks passed'
  [ "$SECONDS" -lt "$deadline" ] || fail "health checks did not pass within $TIMEOUT seconds"
  sleep 1
done

printf 'application ready\n  launcher pid: %s\n  state: %s\n  log: %s\n' "$LAUNCH_PID" "$STATE" "$LOG"
printf '  ports:'; printf ' %s' "${PORTS[@]}"; printf '\n'
printf '  health URLs:\n'; printf '    %s\n' "${HEALTH_URLS[@]}"
printf 'tear down with: %q --state %q\n' "$TEARDOWN" "$STATE"

if [ "$FOREGROUND" -eq 1 ]; then
  cleanup_foreground() {
    trap - INT TERM EXIT
    if ! "$TEARDOWN" --state "$STATE"; then
      echo "launch.sh: foreground teardown failed; inspect and retain state at $STATE" >&2
    fi
  }
  trap cleanup_foreground INT TERM EXIT
  echo 'remaining attached; teardown will run when this launcher exits'
  wait "$LAUNCH_PID" || true
  cleanup_foreground
fi
