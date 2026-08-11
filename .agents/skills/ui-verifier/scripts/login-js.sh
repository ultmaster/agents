#!/usr/bin/env bash
#
# Print the master-key login snippet to paste into the Chrome DevTools MCP
# `evaluate_script` call, then reload the page to apply it. This seeds the same
# localStorage entry the starfish login page writes (saveBubbleAuthSession in
# packages/starfish/src/lib/auth/session.ts) — driver `master-key` works only
# against the bubble *fixtures* config.
#
# Usage:  login-js.sh <principalId> [token]      # token defaults to dev
#
# Example:
#   .../login-js.sh root            # act as root (can mutate anything)
#   .../login-js.sh user-ada        # see exactly what user-ada sees
set -euo pipefail

PID="${1:?usage: login-js.sh <principalId> [token]}"
TOKEN="${2:-dev}"

cat <<EOF
() => {
  localStorage.setItem('octostaff:bubble-auth-session', JSON.stringify({
    driver: 'master-key',
    token: '$TOKEN',
    principalId: '$PID',
    savedAt: new Date().toISOString(),
  }));
  return localStorage.getItem('octostaff:bubble-auth-session');
}
EOF
