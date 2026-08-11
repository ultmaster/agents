#!/usr/bin/env bash
#
# Tear down the verification stack that launch.sh recorded — and ONLY that one.
#
# Ownership is proven by the state file (recorded ports + launcher PID), not by
# pattern-matching `fixtures` in a process list: the user runs their own
# `pnpm dev:app dev:fixtures` too, so a broad `pkill -f fixtures` can kill their
# server. We kill (a) the recorded launcher's process tree and (b) whatever is
# actually listening on the recorded ports, then re-probe until both are free.
#
# Usage:
#   teardown.sh [state-file]      # default: $TMPDIR/octostaff-ui-verifier/stack.env
set -uo pipefail

STATE_DIR="${TMPDIR:-/tmp}/octostaff-ui-verifier"
STATE="${1:-$STATE_DIR/stack.env}"

if [ ! -f "$STATE" ]; then
  echo "no state file at $STATE — nothing recorded to tear down"
  exit 0
fi
# shellcheck disable=SC1090
. "$STATE"

# Hard guard: never act on the user's ports, whatever the state file claims.
for p in "${BUBBLE_PORT:-}" "${STARFISH_PORT:-}"; do
  if [ "$p" = 3000 ] || [ "$p" = 3001 ]; then
    echo "state file points at $p (3000/3001 are the user's) — refusing to act" >&2
    exit 2
  fi
done

# PIDs listening on our two ports right now (survivors reparent off the launcher,
# so this is the source of truth, not the recorded PID alone).
listener_pids() {
  ss -ltnp 2>/dev/null \
    | grep -E "[:.]($BUBBLE_PORT|$STARFISH_PORT)[[:space:]]" \
    | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u
}

# The recorded launcher and its descendants (caught while the launcher is alive;
# once it exits, children reparent and we rely on listener_pids instead).
tree_pids() {
  local p="$1"
  [ -n "$p" ] || return 0
  echo "$p"
  local c
  for c in $(pgrep -P "$p" 2>/dev/null); do tree_pids "$c"; done
}

kill_set() {
  local sig="$1"; shift
  local pid
  for pid in "$@"; do
    [ -n "$pid" ] || continue
    kill "$sig" "$pid" 2>/dev/null || true
  done
}

collect() { { tree_pids "${LAUNCH_PID:-}"; listener_pids; } | sort -u | tr '\n' ' '; }

pids="$(collect)"
echo "stopping stack on $BUBBLE_PORT/$STARFISH_PORT — pids: ${pids:-<none>}"
# shellcheck disable=SC2086
kill_set -TERM $pids
sleep 2
# shellcheck disable=SC2086
kill_set -KILL $(collect)
sleep 1

# Re-probe: a kill returning 0 is not proof the port is free (watch-supervisor
# may respawn, or the listener lived under another PID). Loop until clear.
ok=1
for _ in 1 2 3 4 5; do
  survivors="$(collect)"
  busy=0
  curl -sf "http://127.0.0.1:$BUBBLE_PORT/healthz" >/dev/null 2>&1 && busy=1
  ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]($BUBBLE_PORT|$STARFISH_PORT)$" && busy=1
  if [ "$busy" = 0 ]; then ok=0; break; fi
  # shellcheck disable=SC2086
  kill_set -KILL $survivors
  sleep 1
done

if [ "$ok" = 0 ]; then
  echo "ports $BUBBLE_PORT/$STARFISH_PORT are free; stack down"
  rm -f "$STATE"
else
  echo "WARNING: something still bound on $BUBBLE_PORT/$STARFISH_PORT — inspect:" >&2
  ss -ltnp 2>/dev/null | grep -E "[:.]($BUBBLE_PORT|$STARFISH_PORT)[[:space:]]" >&2 || true
  exit 1
fi
