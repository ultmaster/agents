#!/usr/bin/env bash
# Stop Chrome-family processes using one exact automation profile directory.
set -uo pipefail

usage() {
  cat <<'EOF'
Usage: chrome-recover.sh --profile DIRECTORY [--dry-run]

Options:
  --profile DIRECTORY  Exact automation --user-data-dir to recover
  --dry-run            List matching browser processes without signaling them
  -h, --help           Show this help

Never point this script at a personal browser profile. It matches an exact
--user-data-dir argument and refuses broad process-name or substring killing.
EOF
}

die() { echo "chrome-recover.sh: $*" >&2; exit 2; }

PROFILE=''
DRY_RUN=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile) [ "$#" -ge 2 ] || die '--profile requires a value'; PROFILE=$2; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$PROFILE" ] || die '--profile DIRECTORY is required'
[ -d /proc/1 ] || die 'exact browser-argument inspection requires a Linux /proc filesystem'
case "$PROFILE" in /) die 'refusing the filesystem root as a profile' ;; esac
case "$PROFILE" in *$'\n'*) die 'profile path must not contain newlines' ;; esac

if [ -d "$PROFILE" ]; then
  PROFILE=$(cd "$PROFILE" && pwd -P)
elif [[ "$PROFILE" != /* ]]; then
  die 'a nonexistent profile must be supplied as an absolute path'
fi
case "$PROFILE" in /) die 'refusing the filesystem root as a profile' ;; esac

is_chrome_process() {
  local pid=$1 comm
  [ -r "/proc/$pid/comm" ] || return 1
  IFS= read -r comm <"/proc/$pid/comm" || return 1
  case "$comm" in
    chrome|chrome_crashpad*|chromium|chromium-browser|google-chrome*|Google\ Chrome*) return 0 ;;
    *) return 1 ;;
  esac
}

uses_exact_profile() {
  local pid=$1 arg previous=''
  [ -r "/proc/$pid/cmdline" ] || return 1
  while IFS= read -r -d '' arg; do
    if [ "$arg" = "--user-data-dir=$PROFILE" ]; then return 0; fi
    if [ "$previous" = '--user-data-dir' ] && [ "$arg" = "$PROFILE" ]; then return 0; fi
    previous=$arg
  done < "/proc/$pid/cmdline"
  return 1
}

collect_matches() {
  local proc pid
  for proc in /proc/[0-9]*; do
    [ -d "$proc" ] || continue
    pid=${proc##*/}
    [ "$pid" = "$$" ] && continue
    is_chrome_process "$pid" && uses_exact_profile "$pid" && printf '%s\n' "$pid"
  done
}

mapfile -t matches < <(collect_matches | sort -n -u)
if [ "${#matches[@]}" -eq 0 ]; then
  echo "no Chrome-family process uses the exact profile $PROFILE; nothing to recover"
  exit 0
fi
printf 'matching browser processes:'; printf ' %s' "${matches[@]}"; printf '\n'
if [ "$DRY_RUN" -eq 1 ]; then
  echo 'dry run; no signals sent'
  exit 0
fi

kill -TERM "${matches[@]}" 2>/dev/null || true
for _ in 1 2 3 4 5; do
  sleep 1
  mapfile -t matches < <(collect_matches | sort -n -u)
  [ "${#matches[@]}" -eq 0 ] && break
done
[ "${#matches[@]}" -eq 0 ] || kill -KILL "${matches[@]}" 2>/dev/null || true
sleep 1
mapfile -t matches < <(collect_matches | sort -n -u)
if [ "${#matches[@]}" -gt 0 ]; then
  echo "chrome-recover.sh: matching processes survived: ${matches[*]}" >&2
  exit 1
fi
echo 'automation-profile browser processes stopped; retry the browser tool'
