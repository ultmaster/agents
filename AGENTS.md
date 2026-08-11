# Personal Agent Instructions

This repository stores guidance intended to work across unrelated projects and
agent harnesses.

## Scope

- Keep only personal preferences and workflows that are useful in more than one
  repository. Leave architecture, commands, package names, and exceptions that
  belong to one project in that project's instructions.
- Treat `.agents/skills/` as the canonical portable skill tree. Keep
  harness-specific configuration in `.codex/` or `.claude/` only when a shared
  skill or instruction cannot express it.
- Never commit credentials, generated caches, raw transcripts, or other private
  runtime state. Distill conversation history into concise rules instead.

## Working style

- Treat the named task, phase, design, or pull request as a hard scope boundary.
  Understand the surrounding structure and trace concrete callers before
  changing it. Do not fold in adjacent fixes, refactors, or documents unless
  they are necessary; ask before expanding the scope.
- Prefer the smallest coherent design with one clear owner for each behavior.
  Before adding an abstraction or another representation of the same concept,
  state the concrete problem it solves and check whether an existing owner can
  solve it.
- Keep transient plans in the agent harness. Treat an existing canonical
  proposal or plan as the source of truth. When planning documentation itself is
  in scope, update that artifact in place; do not create a parallel plan or spec
  unless the user asks for a new durable artifact.
- Before declaring an environment blocker or handing executable work back to the
  user, inspect the repository's tooling and configuration and attempt the safe,
  documented path. Request the required execution permission when sandboxing is
  the blocker; do not mistake a sandbox failure for a missing host capability.
- Complete the full authorized scope and run the relevant verification surface,
  not only the narrowest passing check. For UI or visual changes, verify the real
  running interface and inspect the produced visual evidence. Report unfinished
  background work and unrun checks explicitly.

## Git and GitHub

- Before editing, reviewing, committing, merging, or opening a pull request,
  identify the repository root, intended working branch, and base/head
  relationship. Never assume the checked-out branch owns the work; ask when
  ownership remains ambiguous. Review the actual base/head diff and history,
  not only the pull request description or current checkout.
- Inspect remotes before opening a pull request. When a canonical `upstream`
  repository exists, target the pull request there and use the personal fork
  only as the pushed head remote, unless the user explicitly requests another
  target.
- In Codex, request the approved host/out-of-sandbox execution path before every
  direct `gh` command and every script or wrapper that invokes `gh`, including
  reads. The sandbox cannot use the host's GitHub authentication reliably; do
  not interpret that failure as evidence that credentials are missing.
- Make coherent, reviewable commits when a completed stage has a stable boundary.
  Treat committing, pushing, and opening a pull request as distinct actions and
  report their states precisely. Do not push, publish, or open a pull request
  unless the user authorized that outward action.

## Maintaining the library

- Preserve source material exactly in its import commit. Make portability edits
  in a later commit so provenance remains reviewable.
- Keep skills focused, self-contained, and concise. Put essential trigger
  conditions in `SKILL.md` frontmatter and validate changed skills before
  committing them.
- Prefer capability-based wording over repository names, fixed package layouts,
  usernames, ports, or tool paths. Discover project details from local
  instructions and configuration at runtime.
