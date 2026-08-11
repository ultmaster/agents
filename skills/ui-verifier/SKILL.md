---
name: ui-verifier
description: Verify UI and frontend changes end to end in any repository with scoped automated checks, a real running application, browser interaction, inspected screenshots, and comparison to an approved design when one exists. Use whenever asked to verify, QA, confirm, visually inspect, or provide proof for a UI change, visual bug fix, interaction, responsive state, or rendered behavior, including backend changes that affect the UI; tests alone are not sufficient runtime proof.
---

# UI Verifier

Treat verification as observed evidence. Automated checks prove code behavior;
driving the real application proves integration; an inspected screenshot proves
the rendered result; comparison with an approved design proves visual intent.

## Workflow

1. Read the repository instructions and identify the affected package, test
   commands, application launcher, authentication flow, and expected UI state.
2. Run the narrowest relevant automated tests first. Add or run a regression
   test when appropriate, then run the repository's lint and type checks.
3. Identify an already-running real application or launch an isolated one.
   Never treat a process as yours merely because its command or port looks
   familiar. Do not stop an application you did not launch.
4. Reach the changed behavior through the browser. Exercise the important
   interaction, loading, empty, error, responsive, and theme states that the
   change can affect. Follow project-provided authentication and fixture
   instructions; never invent credentials or a login bypass.
5. Capture screenshots and inspect the actual image files. Saving a screenshot
   without looking at it is not verification. Record the route, viewport, test
   data, and state needed to reproduce each image.
6. If an approved design, reference screenshot, or design-system example exists,
   compare it deliberately with the runtime result: layout, spacing, type,
   color, component choice, content, interaction states, and responsive behavior.
   Report divergences instead of silently choosing either artifact.
7. Tear down an isolated application immediately after capturing evidence.
   Leave user-owned processes untouched. Report the tests run, browser behavior
   observed, screenshots inspected, design comparison, and any limitations.

## Isolated application lifecycle

Use `scripts/launch.sh` when the repository does not already provide an equally
safe launcher. Supply every ownership-relevant fact explicitly:

```bash
VERIFY_PORT=<chosen-free-port>
STATE_FILE="${TMPDIR:-/tmp}/ui-verifier-example.state"

scripts/launch.sh \
  --command "npm run dev -- --port $VERIFY_PORT" \
  --port "$VERIFY_PORT" \
  --health-url "http://127.0.0.1:$VERIFY_PORT/health" \
  --state "$STATE_FILE"
```

Repeat `--port` and `--health-url` for a multi-service stack. Use `--cwd` when
the command must run elsewhere, `--timeout` for slow startup, and `--foreground`
to remain attached after readiness. The launcher refuses occupied ports and an
existing state file; it records the exact launcher PID, process group, run token,
ports, health URLs, and log path.

Pass the same state path to teardown:

```bash
scripts/teardown.sh --state "$STATE_FILE"
```

Teardown verifies the recorded run identity before signaling individual
processes. It never kills an arbitrary current listener just because it occupies
a recorded port. If a port remains busy after owned processes stop, investigate
and report it; never use broad matches such as `pkill -f`, `killall`, or
`ps | grep` pipelines.

Use `scripts/chrome-recover.sh --profile <automation-profile-directory>` only
when a stale automation browser owns that exact profile. The script filters for
browser processes with the exact `--user-data-dir` argument. Never point it at a
personal browser profile.

## Evidence standard

Make only claims supported by what was observed:

- Name the exact automated commands and outcomes.
- Describe the browser path and state exercised.
- Open and inspect every screenshot cited as proof.
- State which approved design was compared, or say that none was available.
- Separate verified behavior from assumptions, skipped states, and blockers.

Green tests alone do not verify a UI fix. A screenshot alone does not verify an
interaction. Proof is the combination of reproducible setup, observed behavior,
and inspected output.
