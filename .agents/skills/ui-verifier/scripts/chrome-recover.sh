#!/usr/bin/env bash
#
# Clear a stale Chrome that holds the chrome-devtools-mcp profile lock, so the
# MCP server can relaunch. Symptom this fixes:
#   "The browser is already running for .../chrome-devtools-mcp/chrome-profile.
#    Use --isolated to run multiple browser instances."
#
# Targets ONLY real Chrome processes whose --user-data-dir is the MCP automation
# profile. The user's normal browser uses a different profile, so it is never
# touched. We kill the process (which frees the Singleton* lockfiles) rather than
# rm-ing the lockfiles, which is denied as destructive.
#
# IMPORTANT: do NOT `pkill -f "chrome-devtools-mcp/chrome-profile"`. `-f` matches
# any process whose command line merely *contains* that string — including the
# shell running this script (an agent's own command text often mentions the
# profile path), so the naive pkill kills its own parent. We instead enumerate
# candidates, then keep only processes whose comm is actually chrome and which
# are not this script or its shell.
set -uo pipefail

PROFILE='chrome-devtools-mcp/chrome-profile'
SELF=$$
PARENT=${PPID:-0}

# Candidate PIDs: anything referencing the profile as a Chrome --user-data-dir.
mapfile -t cands < <(pgrep -f -- "--user-data-dir=[^ ]*${PROFILE}" 2>/dev/null || true)

chrome_pids=()
for p in "${cands[@]:-}"; do
  [ -n "${p:-}" ] || continue
  [ "$p" = "$SELF" ] && continue
  [ "$p" = "$PARENT" ] && continue
  comm=$(cat "/proc/$p/comm" 2>/dev/null || true)
  # Real browser processes only (main + zygote/gpu/renderer children + crashpad);
  # this is the safeguard that excludes the invoking shell even if pgrep matched it.
  case "$comm" in
    chrome | chrome_crashpad* | *[Cc]hrome*) chrome_pids+=("$p") ;;
  esac
done

if [ "${#chrome_pids[@]}" -eq 0 ]; then
  echo "no MCP-profile Chrome running — nothing to clear (just retry the MCP call)"
  exit 0
fi

echo "stopping ${#chrome_pids[@]} MCP-profile Chrome process(es): ${chrome_pids[*]}"
kill -TERM "${chrome_pids[@]}" 2>/dev/null || true
sleep 2
# Re-enumerate before the hard kill — pids may have changed.
mapfile -t survivors < <(pgrep -f -- "--user-data-dir=[^ ]*${PROFILE}" 2>/dev/null || true)
hard=()
for p in "${survivors[@]:-}"; do
  [ -n "${p:-}" ] || continue
  [ "$p" = "$SELF" ] && continue
  [ "$p" = "$PARENT" ] && continue
  comm=$(cat "/proc/$p/comm" 2>/dev/null || true)
  case "$comm" in chrome | chrome_crashpad* | *[Cc]hrome*) hard+=("$p") ;; esac
done
[ "${#hard[@]}" -gt 0 ] && kill -KILL "${hard[@]}" 2>/dev/null || true
sleep 1

# Final check, applying the same comm filter (never count this shell).
mapfile -t left < <(pgrep -f -- "--user-data-dir=[^ ]*${PROFILE}" 2>/dev/null || true)
still=0
for p in "${left[@]:-}"; do
  [ -n "${p:-}" ] || continue
  [ "$p" = "$SELF" ] && continue
  [ "$p" = "$PARENT" ] && continue
  comm=$(cat "/proc/$p/comm" 2>/dev/null || true)
  case "$comm" in chrome | chrome_crashpad* | *[Cc]hrome*) still=$((still + 1)) ;; esac
done

if [ "$still" -gt 0 ]; then
  echo "WARNING: $still MCP Chrome process(es) survived — inspect: pgrep -af -- '--user-data-dir=.*${PROFILE}'" >&2
  exit 1
fi
echo "cleared — retry the Chrome DevTools MCP call (new_page / navigate_page)"
