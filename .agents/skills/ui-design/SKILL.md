---
name: ui-design
description: Use whenever you're designing a new OctoStaff/starfish UI or making a UI change — the workflow is design-first: before writing UI code, sketch the intended UI in the Starfish Product Design Figma file (composing from Foundations tokens + Component Families), have the user review it, then implement, then verify with the ui-verifier skill (which includes a Figma visual-parity check), then promote any net-new reusable parts into the Component Families catalog so the design system doesn't drift. Trigger it the moment a visual feature or change is requested — creating, adding, building, restyling, or redesigning a component, screen, panel, dialog, popover, menu, tray, sidebar, composer, message, or settings view; a new interaction, empty/error state, or mobile/compact variant; "implement this UI", "the X should look like…", or asking how to approach a UI — even when the user never says "design" or "Figma" and just says "add X to starfish". Do NOT use for non-visual work: backend/API or bubble-store logic, writing tests or debugging a failing visual snapshot, copy-only typo fixes, dependency/version bumps, or editing docs.
---

# UI Design

Designing a UI — or changing one — starts in Figma, not in code. A sketch is a
cheap, shared, reviewable artifact: it surfaces layout, hierarchy, and missing-state
problems before you've written a line of TSX, and it keeps starfish consistent with
the design system instead of drifting one hand-styled component at a time. The loop is

**sketch → the user checks it out → implement → verify → promote**

and each arrow is a checkpoint you don't skip.

This is the process skill for the whole loop. It leans on **figma-use** (the Plugin
API protocol — mandatory before any `use_figma` write), **frontend-design** (aesthetic
direction), **figma-generate-design** / **figma-generate-library** (composing
screens/components from a design system), and closes on **[ui-verifier]** (the runtime
+ design-parity proof) before **promoting** the change's net-new reusable parts back
into the Component Families catalog. Invoke those by name as each step needs them.

## When to sketch, and when to skip

Sketch by default — the sketch pays for itself the moment there's a real design
decision. Skip it only when the change has exactly one obvious rendering and you'd
just be drawing what you're about to type.

| Sketch first | Skip — implement directly |
| --- | --- |
| A new component, screen, panel, dialog, or empty/error state | A copy edit |
| Restructuring layout or visual hierarchy | Swapping one existing token for another (`color/*`, `spacing/*`, `radius/*`) |
| A new interaction or access state | A one-line state/logic fix with no visual ambiguity |
| Anything touching multiple surfaces, or where two reasonable designs exist | Nudging, hiding, or removing an element that already exists |

When you're unsure which column you're in, you're in the left one — a sketch is
cheaper than a rebuild.

## Where sketches live — embedded target

The home is the **Starfish Product Design** file, **UI Design** page:

- URL: `https://www.figma.com/design/X7EUKdvekmvAlHjOJ4foFV/Starfish-Product-Design?node-id=250-10`
- `fileKey` **`X7EUKdvekmvAlHjOJ4foFV`**, page **`250:10`**

Give every change its **own titled frame** on that page, labelled with the change or
issue (e.g. `#123 · Composer attachment tray`). That frame is what the user reviews in
Step 2 and what **[ui-verifier]** compares the built UI against in its parity step — so
one frame per change, named to match, is the contract that makes the rest of the loop
work.

**Everything you create goes on the UI Design page — never the Cover page.** `use_figma`
resets `figma.currentPage` to the file's first page (**Cover**) at the start of every
call, so a script that creates nodes without first switching lands them on the Cover by
accident. Call `await figma.setCurrentPageAsync(<UI Design page>)` at the top of **every**
write, and stage any sketch-local helper components (e.g. a shared row you instance
across frames) on the UI Design page too — not the Cover, not Component Families.

## Step 1 — Sketch the intended UI

1. **Load the `figma-use` skill first.** It's mandatory before any `use_figma` write;
   skipping it causes the common font-not-loaded and coordinate failures.
2. **Compose from the design system — don't invent.** Instance the existing
   **Component Families** (Button, Input, Avatar, Chip, Message, Composer, Tool Card,
   Dialog, …) and bind **Foundations** tokens (`color/*`, `spacing/*`, `radius/*`, the
   Geist text styles) rather than hardcoding hexes and pixels. Reuse *is* the protocol:
   a sketch built from real components is one the implementation can mirror 1:1, and it
   stays on-theme in light and dark for free. Match the file's conventions (Geist text
   styles; semantic-color binding; the opacity-bound-paint gotcha where a bound SOLID
   paint with `opacity` renders full-strength — use a literal light fill for tint
   states).
3. **Invoke the `frontend-design:frontend-design` skill** (Skill tool) for aesthetic
   judgment — type scale, spacing rhythm, hierarchy, and keeping it from reading as a
   templated default. Load it alongside this one before you sketch; it shapes the
   visual direction that Step 1's composition then expresses in design-system parts.
4. **Screenshot the frame** (`get_screenshot`) and **show it to the user.** A sketch
   nobody looked at isn't a design.

## Step 2 — Let the user check out the design

Stop and wait for the user to review the Figma frame and approve — or redirect —
before writing any implementation code. This checkpoint is the entire point of
designing first; don't roll past it into code in the same breath. Iterate on the
sketch until they're happy, then proceed.

## Step 3 — Implement to match the approved sketch

Build the change in starfish (or the relevant package), mirroring the approved frame —
same components, same tokens, same states. Follow the repo's coding standards: reuse
existing components and atoms, prefer surgical edits, and never hardcode a value the
design system already names (that's what breaks dark mode and drifts the theme).

## Step 4 — Verify with ui-verifier

Invoke the **[ui-verifier]** skill. It runs the affected tests, drives the real UI,
screenshots it, and does a **visual-parity compare** of the built UI against your
Step 1 frame, flagging divergences before the change is called done. A change isn't
finished until the running UI matches the design the user signed off on.

## Step 5 — Promote the reusable parts into the Component Families catalog

Once the change is verified, its sketch frames usually hold **net-new reusable pieces**
that were invented for it — an atom, a molecule, a panel, a dialog. Left on the UI
Design page they're invisible to the next designer, who re-invents them and lets the
system drift one hand-built frame at a time. Closing the loop means lifting those pieces
into the canonical catalog so they become first-class, instanceable families. This is
the mirror image of Step 1: Step 1 *consumes* the catalog, Step 5 *feeds it back*.

**Where the catalog lives:** the same file's **Component Families** page (`fileKey
X7EUKdvekmvAlHjOJ4foFV`, page **`10:5`** — distinct from the UI Design page `250:10`).
It's organized into numbered sections (`01 · Atoms`, `02 · Navigation`, …), each holding
component **sets** — every family is a `COMPONENT_SET` named `Family` whose variants are
named `Prop=Value` (`State=…`, `Kind=…`, `Tone=…`, `Type=…`). Set `currentPage` to it
(never the Cover) at the top of every write.

Promote like this:

1. **Lift the parts that matter, not the screen.** Take the genuinely reusable units —
   the panel, the dialog, the row, the pill, the dropzone — and **drop the chrome**: the
   app behind, scrims, dialog backdrops, nav sidebars, the desktop frame. Skip anything
   that's a pure composition of existing families with nothing new (a message group
   that's just Avatar + Message earns no new component). When it's ambiguous which parts
   are worth promoting, **surface the candidate list and let the user pick** before you
   build — promoting reshapes a shared file, so treat it like the other outward steps.
2. **Capture states as a variant set.** If a part has states, `combineAsVariants` them
   into a set with a `Prop=Value` property — don't drop a bare single component next to
   families that are all sets. Name each component `State=Foo` *before* combining;
   `combineAsVariants` infers the property name from the component names.
3. **Clone the real nodes — never rebuild from the `get_design_context` CSS.** Cloning
   preserves the vector icons, nested instances, and — critically — the **bound
   Foundations variables**. Rebuilding from the emitted `#e4e4e7 / 8px` CSS hardcodes
   values and breaks dark mode. To retint a state, rebind its paint to the token
   variable with `setBoundVariableForPaint`, don't assign a literal color. (Read a
   token's `VariableID` off any existing catalog component's
   `fills[0].boundVariables.color` / `strokes[0].boundVariables.color` when you need it.)
4. **Move a true master; clone a loose part.** If the sketch already defined a real
   master component that's instanced across frames, **move that master** into the catalog
   as the base variant — the existing sketch instances relink to the now-canonical
   component (real promotion, and instances survive the cross-page move). If the part was
   only ever loose frames, `createComponentFromNode` on a **clone** and leave the sketch
   frames untouched — they're the [ui-verifier] parity record. Composite parts (panels,
   dialogs, panes) clone wholesale; their nested `Button` / `Input` / row instances and
   bindings carry through — nested components are fine.
5. **Slot it into a section.** Extend the right existing section, or add the next
   numbered one (`08 · …`) with a title + a muted description text matching the pattern
   (clone an existing section's description text to inherit its style). Section children
   use **section-relative** coordinates. Lay the sets out in a row, then
   `resizeWithoutConstraints` the section to fit its content.
6. **Verify authoritatively.** `get_screenshot` the section (not the inline
   `node.screenshot()`, which can render stale). If you moved a master (sub-step 4
   above), re-screenshot one sketch frame to confirm its instances still resolve.

## Gotchas

- **Don't skip the review checkpoint (Step 2).** Sketching and implementing in one
  breath throws away the whole reason to design first.
- **Don't hardcode what Foundations names.** A sketch (or an implementation) full of
  literal `#0A0A0A` / `16px` can't be mirrored by token-bound code and breaks in dark
  mode. Bind the token.
- **A sketch you didn't screenshot and show is an assumption, not a design.**
- **Verify the final frame with `get_screenshot`, not just `use_figma`'s inline
  `node.screenshot()`.** The in-canvas `screenshot()` can return a *stale, pre-reflow*
  render — most visibly, `FILL`-width component instances nested a few auto-layout
  levels deep (list rows inside a section inside a content pane) render collapsed to
  near-zero width even when the node geometry reads correct (884px, text present).
  `get_screenshot` renders the committed desktop state and is authoritative; confirm
  every frame there before showing the user. When a row/card mysteriously collapses,
  give it a FIXED width instead of `FILL`.
- **"Small and clear enough" is an exemption, not a loophole.** If you're unsure
  whether a change qualifies, it doesn't — sketch it.
- **Verified isn't done — done is promoted.** Shipping a change that introduced a new
  reusable part without running Step 5 leaves the catalog stale and the next designer
  re-inventing it from scratch. Close the loop: lift the part into Component Families.
- **Promote by cloning, and drop the chrome.** Rebuilding a catalog component from the
  `get_design_context` CSS hardcodes hexes/pixels and breaks dark mode; dragging the
  whole end-to-end screen in makes an unmaintainable entry. Clone the real node (for its
  icons + variable bindings) and keep only the reusable part.

[ui-verifier]: ../ui-verifier/SKILL.md
