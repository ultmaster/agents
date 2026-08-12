---
name: ui-work
description: Design, implement, and verify visual UI changes in any repository. Use for new or redesigned components, screens, dialogs, panels, navigation, responsive or empty/error/loading states, interactions, and visual bug fixes, and whenever asked to verify, QA, or provide proof for how something renders - including backend changes that affect the UI. Sketch with the project's own design tooling and get approval when a real visual choice exists, implement from the approved sketch, then prove the result in the running application with inspected screenshots. Tests alone are never visual proof.
---

# UI Work

One loop: **discover → sketch → approve → implement → verify → promote**.

Scale it to the change. A copy edit, a single token swap, or a fix with one
possible rendering needs implementation and a look at the result — not a sketch
and an approval round. A new surface, a layout or hierarchy change, or anything
with two reasonable renderings needs the whole loop. When you skip steps, say
which and why rather than pretending the loop ran.

## 1. Discover

Inspect local instructions and the codebase for:

- the canonical design file or other approved visual source;
- component libraries, stories, screenshots, and existing surfaces;
- semantic color, spacing, type, radius, motion, and breakpoint tokens;
- accessibility and platform conventions;
- how the application runs locally, its authentication flow, and its fixtures.

Use the design system as the default vocabulary. Create a new primitive only
when existing parts cannot express the design, and never invent an
undocumented design system.

## 2. Sketch with the project's own tooling

Choose the drafting surface from the project's configuration, not from habit:

- a connected design tool when the project keeps its canonical design there —
  load any mandatory tool-specific skill before writing to a design file;
- the project's own preview surface — component explorer, playground, sandbox
  route — when it has one;
- otherwise a throwaway page, route, or file rendered with the project's real
  tokens and components, which is usually the fastest reviewable artifact.

**If the project offers none of these, ask the user how to proceed** — continue
without a sketch, or be pointed at a design source — before writing
implementation code. Do not quietly drop the review checkpoint.

In the sketch, compose from existing components and semantic tokens before
drawing custom elements, and show the states the implementation must support:
default, loading, empty, error, disabled, focus and hover where material,
narrow and wide layouts, and light/dark modes when both ship. Put it in the
project's designated work area under a task or issue title so it can be found
again during verification.

Show it to the user and stop for approval or redirection. A sketch that was
never shown is still an assumption, and "small" is not a reason to skip review
while a real design choice remains open.

## 3. Implement the approved design

Mirror the approved component choices, tokens, hierarchy, states, and responsive
behavior. Reuse the repository's primitives and extend an existing owner when it
fits. Do not translate token-bound design values into unrelated literals, and do
not replace accessible native or design-system behavior with custom chrome.

If an implementation constraint forces a visible deviation, surface it and
reconcile the design instead of silently drifting.

## 4. Verify in the running interface

Automated checks prove code behavior; the running application proves
integration; an inspected screenshot proves the rendered result; comparison with
the approved sketch proves intent. A passing suite is not visual proof.

1. Run the narrowest relevant automated tests, adding a regression test when the
   change warrants one, then the repository's lint and type checks.
2. Use an already-running application or launch an isolated one. Never treat a
   process as yours because its command or port looks familiar, and never stop
   an application you did not launch.
3. Drive the real UI to every state the change can affect. Follow the project's
   authentication and fixture instructions; never invent credentials or a login
   bypass.
4. Capture screenshots and have every one of them inspected (below), recording
   the route, viewport, test data, and state that reproduces each image.
5. Compare the result against the approved sketch, reference screenshot, or
   design-system example. Report divergences instead of silently preferring
   either artifact.
6. Tear down what you launched, leaving user-owned processes untouched. Report
   the commands run, the paths exercised, the screenshots inspected, the design
   comparison, and every limitation or skipped state.

### Inspect every screenshot, in a subagent

Saving a screenshot without looking at it is not verification — and loading a
batch of images into the working context crowds out the code being changed. So
delegate the looking rather than skipping it:

- Give a subagent the image paths, the route/viewport/state behind each, the
  approved sketch when one exists, and `references/screenshot-review.md` from
  this skill directory.
- Ask for findings as text: what is wrong, in which image, where in the frame,
  which rule or token it violates, and how severe it is.
- Ask it to review, not to fix. Keep related screenshots in one pass so findings
  can be compared across states and viewports.
- If the harness offers no subagent, inspect the images yourself in one focused
  pass and write the findings down before returning to implementation.

Then act on the report: fix real defects, and state which findings you are
leaving and why. A finding list is not automatically a work list — pre-existing
issues outside the change belong in the report, not in the diff.

### Isolated application lifecycle

Use `scripts/launch.sh` when the repository does not already provide an equally
safe launcher. Supply every ownership-relevant fact explicitly:

```bash
VERIFY_PORT=<chosen-free-port>
STATE_FILE="${TMPDIR:-/tmp}/ui-work-example.state"

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

## 5. Promote reusable parts

After verification, identify what is genuinely reusable. Promote a stable
component, token, or pattern into the project's canonical library; leave one-off
screen composition with the screen. When promotion changes a shared design file
or a public component API, surface the candidate set to the user before making
that outward change.

Preserve token bindings, nested instances, vectors, variants, and interaction
states when promoting. Prefer moving a true master or cloning the real designed
node over rebuilding it from generated CSS. Verify both the library entry and an
existing consumer after promotion.

## Evidence standard

Make only claims supported by what was observed. Name the exact commands and
outcomes, describe the browser path and states exercised, cite only screenshots
that were actually inspected, say which approved design was compared or that
none existed, and keep verified behavior separate from assumptions, skipped
states, and blockers.
