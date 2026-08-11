---
name: ui-design
description: Plan and implement visual UI changes with a design-first review loop. Use for new or redesigned components, screens, dialogs, panels, navigation, responsive states, empty/error/loading states, interactions, or any request with meaningful layout or visual choices. Discover and reuse the project's design system, create a reviewable sketch before code when more than one reasonable rendering exists, obtain user approval, implement the approved design, verify the running UI, and promote genuinely reusable parts back into the design system. Skip only mechanical copy/token changes or visual fixes with one unambiguous rendering.
---

# UI Design

Use this loop for meaningful visual work:

**discover → sketch → user review → implement → verify → promote**

The review checkpoint is the reason to design first. Do not create a sketch and
roll directly into implementation before the user has seen it.

## Decide whether to sketch

Sketch when the task introduces a component/surface/state, changes hierarchy or
layout, affects responsive behavior, or admits two reasonable designs. Skip a
separate sketch for copy edits, a direct replacement of one established token,
or a one-line visual correction whose result is already dictated by an approved
design. If uncertain, sketch.

## 1. Discover the design source

Inspect local instructions and the codebase for:

- the canonical design file or other approved visual source;
- component libraries, stories, screenshots, and existing surfaces;
- semantic color, spacing, type, radius, motion, and breakpoint tokens;
- accessibility and platform conventions.

Use connected design tooling when available. Load any mandatory tool-specific
skill before writing to a design file. If the repository has no design file,
create the smallest reviewable artifact the environment supports and name the
assumption explicitly; do not invent an undocumented design system.

## 2. Sketch from existing parts

- Compose with existing components and semantic tokens before drawing custom
  elements or hard-coding values.
- Show the states the implementation must support: default, loading, empty,
  error, disabled, focus/hover where material, narrow/wide layouts, and relevant
  light/dark modes.
- Put the sketch in the project-designated work area. Give it a task/issue title
  so the approved artifact can be found during verification.
- Capture the committed design with the design tool's authoritative screenshot
  path and show it to the user.

Stop for approval or redirection. Iterate on the artifact until the visual
direction is clear.

## 3. Implement the approved design

Mirror the approved component choices, tokens, hierarchy, states, and responsive
behavior. Reuse the repository's primitives and extend an existing owner when it
fits. Do not translate token-bound design values into unrelated literals, and do
not replace accessible native/design-system behavior with custom chrome.

If implementation constraints require a visible deviation, surface it and
reconcile the design instead of silently drifting.

## 4. Verify the running interface

Invoke the [`ui-verifier`](../ui-verifier/SKILL.md) skill. Run automated checks,
drive the real UI to every changed state, inspect screenshots, and compare them
against the approved artifact. Check component choice, alignment, spacing,
typography, semantic colors, responsive behavior, themes, focus behavior, and
content overflow. A passing test suite is not visual proof.

## 5. Promote reusable parts

After verification, identify what is genuinely reusable. Promote a stable
component, token, or pattern into the project's canonical library; leave
one-off screen composition with the screen. When promotion changes a shared
design file or public component API, surface the candidate set to the user
before making the outward/shared change.

Preserve token bindings, nested instances, vectors, variants, and interaction
states when promoting. Prefer moving a true master or cloning the real designed
node over rebuilding it from generated CSS. Verify both the library entry and an
existing consumer after promotion.

## Guardrails

- A sketch that was never shown is still an assumption.
- “Small” is not a reason to skip review when a real design choice remains.
- Use the design system as the default vocabulary; create a new primitive only
  when existing parts cannot express the approved design.
- Keep the approved artifact available as the parity record until runtime
  verification is complete.
