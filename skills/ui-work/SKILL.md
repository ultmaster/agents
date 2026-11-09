---
name: ui-work
description: Design, implement, review, and verify UI behavior and rendering in any repository. Use for components, screens, dialogs, navigation, responsive and empty/error/loading states, interactions, visual bug fixes, and UI reviews or QA, including backend changes that affect the UI. Use approved designs where available, seek approval for unresolved visual choices, and verify user journeys in a real browser with an explicit checklist and inspected screenshots. Tests alone are never visual proof.
---

# UI Work

One loop: **discover → sketch → approve → implement → verify → promote**.

Scale it to the change. A copy edit, a single token swap, or a fix with one
possible rendering needs implementation and a look at the result — not a sketch
and an approval round. A new surface, a layout or hierarchy change, or anything
with two reasonable renderings needs the whole loop. When you skip steps, say
which and why rather than pretending the loop ran.

For a review or audit, discover the intended behavior and proceed to verification. Report findings within the requested scope; redesign or implementation requires the user's request to include that work.

## 1. Discover

Inspect local instructions and the codebase for:

- where approved designs live and in what form — a design tool, a hosted
  design-system project, a spec, or reference renders — and whether that source
  is authored by hand or generated from the code library;
- component libraries, stories, screenshots, and existing surfaces;
- semantic color, spacing, type, radius, motion, and breakpoint tokens;
- accessibility and platform conventions;
- how the application runs locally, its authentication flow, and its fixtures;
- the user journeys and vocabulary the affected surface must support, including what its actions change, which version or object they target, and how users inspect the source or details behind a summary;
- whether the proposed browser target and its databases, object storage, workers, and external services are production or test resources.

Use the design system as the default vocabulary. Create a new primitive only
when existing parts cannot express the design, and never invent an
undocumented design system.

## 2. Sketch with the project's own tooling

When an approved design already exists — handed over by the user, produced by a
designer or a design agent, or settled in an earlier round — do not redraw it.
Confirm which version is approved, read it closely enough to implement it, and
raise what it leaves undetermined instead of deciding silently. That design is
the sketch; skip to implementation.

Otherwise choose the drafting surface from the project's configuration, not from
habit:

- the design surface the project already keeps its canonical design in,
  whichever tool or hosted project that is — load any mandatory skill for that
  surface before writing through it;
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
narrow and wide layouts, and light/dark modes when both ship. Put it wherever
that surface keeps in-progress work, titled with the task or issue, so it can be
found again during verification.

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
the approved design proves intent. A passing suite is not visual proof.

Before browsing, make a checklist from the reported problem, affected user journeys, and consumers of changed shared components. For each check, record the route, fixture, action, expected result, and relevant viewport, theme, and locale. Include the states that expose the defect: new and existing objects, empty and populated content, current and historical versions, and expanded details where applicable. Track passed, failed, and unrun checks; a screenshot of the default state does not cover the rest.

1. Run the narrowest relevant automated tests, adding a regression test when the
   change warrants one, then the repository's lint and type checks.
2. Confirm the target environment and its dependencies before reusing a running application or launching one. Keep production probes read-only; use isolated test storage and dependencies for fixture creation, uploads, jobs, saves, and other mutations. A local frontend connected to production APIs is still production. Never treat a process as yours because its command or port looks familiar, and never stop an application you did not launch.
3. Execute the checklist through the real UI, including nested menus, dialogs, expanded images, and detail views. Follow the project's authentication and fixture instructions; never invent credentials or a login bypass. Where a journey changes state, verify the target object/version, the visible result, and persistence after reload or navigation. Compare with server state when needed to distinguish a presentation defect from a save or lifecycle defect.
4. Capture screenshots and have every one of them inspected (below), recording the route, viewport, theme, locale, test data, and state that reproduces each image. Capture relevant shared-component consumers and use close views for fine alignment or spacing without losing the surrounding layout.
5. Compare the result against the approved design, reference render, or
   design-system example. Report divergences instead of silently preferring
   either artifact.
6. Re-run failed checks after a fix and inspect the new captures. Tear down what you launched, leaving user-owned processes untouched. Report the checklist outcomes, commands run, paths exercised, screenshots inspected, design comparison, and every limitation or skipped state.

Review whether users can understand an action before taking it: what it does, which object or version it affects, and where its result appears. When a surface promises details or provenance, open it and check that counts resolve to identifiable items and that the relevant source content is available. Follow through on navigation and save behavior; static images cannot prove those interactions.

### Inspect every screenshot, in a subagent

Saving a screenshot without looking at it is not verification — and loading a
batch of images into the working context crowds out the code being changed. So
delegate the looking rather than skipping it:

- Prefer the `ui-screenshot-reviewer` subagent, which carries the review
  criteria. Any subagent works otherwise; tell it what to look for.
- Give it the image paths, the route/viewport/state behind each, and the
  approved design when one exists.
- Include theme, locale, fixture details, and the expected meaning of controls or summaries. Ask it to compare related controls and content across images, including inline counts/version labels and empty placeholders. Keep behavioral and persistence checks with the agent driving the browser; the screenshot reviewer can establish only what the captures show.
- Ask for findings as text: what is wrong, in which image, where in the frame,
  which rule or token it violates, and how severe it is.
- Ask it to review, not to fix. Keep related screenshots in one pass so findings
  can be compared across states and viewports.
- If the harness offers no subagent, inspect the images yourself in one focused
  pass — layout, spacing, typography, color and contrast, theme, component
  fidelity, states, responsiveness, content, and rendering artifacts — and write
  the findings down before returning to implementation.

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
screen composition with the screen. When promotion changes a shared design
source or a public component API, surface the candidate set to the user before
making that outward change.

Promote into whichever artifact is canonical, and follow the direction the
project's design source is maintained in:

- generated from the code library — promote in code, then re-run the project's
  own sync so the design source follows. Hand-edits to generated output are lost
  on the next sync, and a sync run has its own verification steps to complete.
- authored by hand — edit it directly, preserving token bindings, nested
  instances, vectors, variants, and interaction states. Move a true master or
  clone the real designed node rather than rebuilding it from generated CSS.

Verify both the library entry and an existing consumer after promotion.

## Evidence standard

Make only claims supported by what was observed. Name the exact commands and
outcomes, describe the browser path and states exercised, cite only screenshots
that were actually inspected, say which approved design was compared or that
none existed, and keep verified behavior separate from assumptions, skipped
states, and blockers.
