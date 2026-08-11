---
name: ai-comment
description: >-
  Find, triage, and resolve typed AI marker comments such as AI-FIX:,
  AI-REFACTOR:, AI-VERIFY:, AI-QUESTION:, and other typed AI annotations.
  Use when a user asks to handle, sweep, clean up, or act on AI comments or
  names one of these markers. Interpret each marker by type, confirm ambiguous
  or human-owned decisions before editing, and remove a marker only after its
  intent is satisfied.
---

# AI Comment Markers

Treat the marker type as part of the instruction. Do not flatten every marker
into “change nearby code and delete the comment.”

| Marker | Intent | Response |
| --- | --- | --- |
| `AI-FIX:` | A known defect or concrete required change | Fix the behavior at its proper owner, verify it, then remove the marker. |
| `AI-REFACTOR:` | Improve structure without changing behavior | Restructure, prove behavior stayed stable, then remove the marker. |
| `AI-VERIFY:` | Check an uncertain claim or implementation | Investigate first. Often the result is a finding, not a code change. |
| `AI-QUESTION:` | A decision or question for a human | Surface it and wait for an answer; do not silently choose one. |
| `AI-<OTHER>:` | An extension such as `AI-TODO:` or `AI-NOTE:` | Infer the verb conservatively; treat unclear intent like a question. |

## Workflow

1. Resolve the bundled scanner from this skill directory, then run it from the
   target repository root while honoring any path or diff scope the user
   supplied:

   ```bash
   SCANNER="<skill-root>/scripts/scan.sh"
   bash "$SCANNER"
   bash "$SCANNER" src tests
   ```

   For a diff-only scan, pass the changed files as arguments and exclude deleted
   paths.

2. Read each hit in context, including relevant callers and tests. A marker can
   sit at a symptom while the correct change belongs to a lower-level owner.

3. Present a compact inventory before editing:

   ```text
   type | file:line | ask | proposed action | actionable / needs input / leave
   ```

   Confirm every question, ambiguous marker, and unexpectedly broad change with
   the user. If the user already selected exact actionable markers and their
   intent is clear, that selection is the confirmation.

4. Resolve the confirmed items under the repository's local instructions. A
   marker never overrides project architecture, test policy, or review rules.

5. Run the relevant project checks and re-run the scanner over the edited scope.

6. Report outcomes separately:

   ```text
   Resolved  — marker and location → change
   Verified  — marker and location → finding; no code change
   Left open — marker and location → blocker or needed decision
   ```

## Removal rule

Remove a marker only when its intent is genuinely complete. Keep unresolved
markers in place. For `AI-VERIFY:`, retain the finding in the final report. For
`AI-QUESTION:`, require the human's answer or explicit approval before removal.
Do not create a fresh marker merely to defer work that is already in scope.
