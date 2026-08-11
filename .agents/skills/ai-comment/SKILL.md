---
name: ai-comment
description: Use when finding and resolving AI marker comments left in the codebase — AI-FIX:, AI-REFACTOR:, AI-VERIFY:, AI-QUESTION:, or any AI-<UPPER>: annotation. Trigger whenever the user asks to resolve, address, action, clean up, sweep, or work through the AI comments / markers / annotations they (or a previous agent) left in the code, or names any AI-FIX / AI-REFACTOR / AI-VERIFY / AI-QUESTION tag — even a terse "handle the markers" or pointing at a file full of them. Each marker type carries a distinct intent and earns a distinct response; the run is triage-first so you steer before edits land.
---

# AI Comment Markers

AI marker comments are short, typed notes left in the code for a later agent (or
human) to act on. **The type is the instruction.** The single biggest mistake is
flattening every marker into one "read it, change the code, delete the marker"
loop — that answers open questions by guessing, and "fixes" code that was only
asking to be double-checked. Read the type first; it tells you what response is
even appropriate.

## Marker vocabulary

| Marker | What the author meant | Your response | Usual outcome |
| --- | --- | --- | --- |
| `AI-FIX:` | A known defect or a concrete required change. | Implement the fix at its proper home in the code. | code change → marker removed |
| `AI-REFACTOR:` | Improve structure/clarity; **behavior must not change.** | Restructure, then confirm behavior is preserved (tests stay green, no semantic drift). | code change → marker removed |
| `AI-VERIFY:` | "I'm not sure this is correct — check it." | **Investigate, don't assume an edit.** Confirm the behavior/claim; only change code if it's genuinely wrong. | often **no** code change — confirm, remove marker, report the finding; or, if you find a real bug you can't safely fix now, rewrite it as an `AI-FIX:` |
| `AI-QUESTION:` | An open question addressed to a **human**. | Answer it and surface it to the user. Don't silently pick an answer, edit code, and delete the question. | needs human sign-off before the marker comes out |
| `AI-<OTHER>:` | Any other `AI-<UPPER>:` tag (e.g. `AI-TODO:`, `AI-NOTE:`). | Infer intent from the verb; act by best judgment. When the intent isn't clear, treat it like a question and triage it to the user. | depends |

The four named markers are the core vocabulary; the extensible row exists so a
stray `AI-TODO:` doesn't get ignored — not as license to invent new tag types.

## Workflow

Run these in order. Steps 1–3 are cheap and keep you from editing blind.

### 1. Scan

Run the bundled scanner from the repo root:

```bash
bash .agents/skills/ai-comment/scripts/scan.sh              # whole tree
bash .agents/skills/ai-comment/scripts/scan.sh packages/bubble   # scoped to a path
bash .agents/skills/ai-comment/scripts/scan.sh $(git diff --name-only)  # just your diff
```

Honor whatever scope the user implied — a package, a path, "the ones I just
added." If they gave none, default to the whole tree, but if that turns up a
large pile, confirm the scope and a sensible order (package by package) before
sweeping.

The scanner excludes `node_modules`, `dist`, the lockfile, and **this skill's own
directory** — SKILL.md documents the marker strings, so without that exclusion
every run would flag itself. Two related judgment calls the scanner can't make
for you: matches inside docs/markdown that are *explaining the convention* (like
this file) are examples, not work items; and a match without a real ask attached
is prose, not a marker.

### 2. Classify & read context

Group the hits by type. For each, read the surrounding code **and** the relevant
call sites — the marker lives at the symptom, but the fix often belongs with the
callee that owns the behavior. Enough context to know what the author was
actually asking, and where the change truly belongs, before proposing anything.

### 3. Triage → confirm

Present an inventory and get direction before edits land. One row per marker:

```
type | file:line | the ask (one line) | proposed action | actionable / needs-input / leave
```

Get a go-ahead before you start editing — and explicitly route every
`AI-QUESTION:`, anything ambiguous, and anything wide-scope to the user. This is
the checkpoint that makes an autonomous sweep safe.

### 4. Resolve — per type

Work the confirmed items following the marker semantics above, holding to the
repo's usual coding standards (`AGENTS.md` / `CLAUDE.md`). Nothing about a marker
overrides how you'd normally make the change — the type only tells you *what kind*
of response it wants.

### 5. Verify

Verify your edits the way any change in this repo is verified (`AGENTS.md` / `CLAUDE.md`),
scoped to the packages you touched. The one check unique to this skill: **re-run
the scanner** afterward, to confirm the markers you resolved are gone and no
strays slipped in.

### 6. Report

Close with a short account, split three ways:

```
Resolved      — <marker> @ file:line → what changed
Verified      — <marker> @ file:line → finding (no code change needed)
Left open     — <marker> @ file:line → why, and what input unblocks it
```

## Removing markers

A marker comes out **only when its intent is genuinely met** — not when you've
made a plausible-looking edit near it.

- `AI-VERIFY:` — remove only after you've actually verified; carry the finding into your report.
- `AI-QUESTION:` — don't remove without the human's answer or OK. Deleting someone's question because you guessed is the exact failure this skill exists to prevent.
- Can't resolve one? **Leave it in place.** A brief inline note on *why* it's blocked (e.g. `AI-FIX: … — blocked: needs product decision on X`) helps the next pass. Never delete a marker you didn't resolve, and never spawn a fresh marker to punt real work.
