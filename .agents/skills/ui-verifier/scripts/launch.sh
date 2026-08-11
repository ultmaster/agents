#!/usr/bin/env bash
#
# Launch an isolated starfish + bubble fixtures stack for UI verification, then
# block until both answer. Prints the URLs and a state file that teardown.sh
# consumes.
#
# Why this exists (every line is a bug someone hit by hand):
#   * NEXT_DIST_DIR=.next-verify  — the Next dev lock lives at
#     <pkg>/.next/dev/lock and is shared by EVERY `next dev` against that build
#     dir, regardless of port. A developer's running `next dev` therefore makes
#     a naive `:3101` launch fail with "Unable to acquire lock" even though the
#     ports were free. A separate build dir gives our stack its own lock.
#   * 3100/3101, never 3000/3001 — the latter are the user's; we never bind or
#     kill them. If our pair is taken by something we can't claim, we advance.
#   * record the launcher PID — so teardown kills exactly this stack, never a
#     `ps | grep fixtures` match that could be the user's identical command.
#
# Usage:
#   launch.sh [--foreground] [bubble-script]
#                                      # default bubble-script: dev:fixtures
#   BUBBLE_PORT=3200 STARFISH_PORT=3201 launch.sh
#   launch.sh --foreground             # remain attached after readiness
#
# Env overrides:
#   BUBBLE_PORT / STARFISH_PORT  explicit ports (disables auto-advance; errors
#                                if busy). Unset → 3100/3101 with auto-advance.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
STATE_DIR="${TMPDIR:-/tmp}/octostaff-ui-verifier"
mkdir -p "$STATE_DIR"

FOREGROUND=0
if [ "${1:-}" = --foreground ]; then
  FOREGROUND=1
  shift
fi
if [ "$#" -gt 1 ]; then
  echo "usage: launch.sh [--foreground] [bubble-script]" >&2
  exit 2
fi
BUBBLE_SCRIPT="${1:-dev:fixtures}"

# Explicit ports disable auto-advance: if the caller named a pair, honour it or
# fail loudly rather than silently drifting to a different one.
EXPLICIT=0
if [ -n "${BUBBLE_PORT:-}" ] || [ -n "${STARFISH_PORT:-}" ]; then EXPLICIT=1; fi
BUBBLE_PORT="${BUBBLE_PORT:-3100}"
STARFISH_PORT="${STARFISH_PORT:-3101}"

port_busy() { ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1$"; }

reject_user_ports() {
  for p in "$BUBBLE_PORT" "$STARFISH_PORT"; do
    if [ "$p" = 3000 ] || [ "$p" = 3001 ]; then
      echo "refusing to use $p — 3000/3001 are the user's ports" >&2
      exit 2
    fi
  done
}
reject_user_ports

# Auto-advance the pair by +100 (3100/3101 → 3200/3201 → …) when the defaults
# are taken and the caller didn't pin them. Cap the search so we never loop.
if [ "$EXPLICIT" = 0 ]; then
  tries=0
  while port_busy "$BUBBLE_PORT" || port_busy "$STARFISH_PORT"; do
    tries=$((tries + 1))
    if [ "$tries" -gt 5 ]; then
      echo "could not find a free port pair after 5 tries (last: $BUBBLE_PORT/$STARFISH_PORT)" >&2
      exit 1
    fi
    BUBBLE_PORT=$((BUBBLE_PORT + 100))
    STARFISH_PORT=$((STARFISH_PORT + 100))
    reject_user_ports
  done
else
  if port_busy "$BUBBLE_PORT" || port_busy "$STARFISH_PORT"; then
    echo "explicit port pair $BUBBLE_PORT/$STARFISH_PORT is busy — free it or pick another" >&2
    echo "(probe with: ss -ltnp | grep -E ':$BUBBLE_PORT|:$STARFISH_PORT')" >&2
    exit 1
  fi
fi

LOG="$STATE_DIR/stack-$BUBBLE_PORT-$STARFISH_PORT.log"
STATE="$STATE_DIR/stack.env"
: > "$LOG"

echo "launching bubble:$BUBBLE_PORT + starfish:$STARFISH_PORT ($BUBBLE_SCRIPT), dist=.next-verify"
cd "$ROOT"
# Detached mode returns after readiness; foreground mode remains the process
# supervisor so managed command harnesses retain the stack.
if [ "$FOREGROUND" = 1 ]; then
  env NEXT_DIST_DIR=.next-verify BUBBLE_PORT="$BUBBLE_PORT" STARFISH_PORT="$STARFISH_PORT" \
    pnpm dev:app "$BUBBLE_SCRIPT" >"$LOG" 2>&1 &
else
  nohup env NEXT_DIST_DIR=.next-verify BUBBLE_PORT="$BUBBLE_PORT" STARFISH_PORT="$STARFISH_PORT" \
    pnpm dev:app "$BUBBLE_SCRIPT" >"$LOG" 2>&1 &
fi
LAUNCH_PID=$!
if [ "$FOREGROUND" = 0 ]; then disown "$LAUNCH_PID" 2>/dev/null || true; fi

cat > "$STATE" <<EOF
BUBBLE_PORT=$BUBBLE_PORT
STARFISH_PORT=$STARFISH_PORT
LAUNCH_PID=$LAUNCH_PID
LOG=$LOG
EOF

fail() { echo "$1" >&2; echo "--- last 25 log lines ($LOG) ---" >&2; tail -25 "$LOG" >&2; exit 1; }

echo "waiting for bubble /healthz ..."
for _ in $(seq 1 120); do
  curl -sf "http://127.0.0.1:$BUBBLE_PORT/healthz" >/dev/null 2>&1 && { echo "  bubble up"; break; }
  kill -0 "$LAUNCH_PID" 2>/dev/null || fail "launcher exited before bubble came up"
  sleep 1
done
curl -sf "http://127.0.0.1:$BUBBLE_PORT/healthz" >/dev/null 2>&1 || fail "bubble never answered on :$BUBBLE_PORT"

echo "waiting for starfish (first compile is slow) ..."
for _ in $(seq 1 180); do
  curl -sf "http://127.0.0.1:$STARFISH_PORT" >/dev/null 2>&1 && { echo "  starfish up"; break; }
  # A lock collision means NEXT_DIST_DIR didn't isolate us — fail fast, don't
  # wait out the full timeout.
  grep -q "Unable to acquire lock" "$LOG" 2>/dev/null &&
    fail "Next dev lock collision despite NEXT_DIST_DIR — is another verify stack already using .next-verify?"
  kill -0 "$LAUNCH_PID" 2>/dev/null || fail "launcher exited before starfish came up"
  sleep 1
done
curl -sf "http://127.0.0.1:$STARFISH_PORT" >/dev/null 2>&1 || fail "starfish never answered on :$STARFISH_PORT"

cat <<EOF

stack ready:
  bubble    http://127.0.0.1:$BUBBLE_PORT
  starfish  http://127.0.0.1:$STARFISH_PORT
  log       $LOG
  state     $STATE

tear down with:  $(dirname "${BASH_SOURCE[0]}")/teardown.sh
EOF

if [ "$FOREGROUND" = 1 ]; then
  TEARDOWN="$(dirname "${BASH_SOURCE[0]}")/teardown.sh"
  cleanup_foreground() {
    trap - INT TERM EXIT
    "$TEARDOWN" "$STATE" >/dev/null 2>&1 || true
  }
  trap cleanup_foreground INT TERM EXIT
  echo "remaining attached; run teardown.sh from another command when verification is done"
  wait "$LAUNCH_PID" || true
  cleanup_foreground
fi
