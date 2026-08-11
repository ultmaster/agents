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

## Maintaining the library

- Preserve source material exactly in its import commit. Make portability edits
  in a later commit so provenance remains reviewable.
- Keep skills focused, self-contained, and concise. Put essential trigger
  conditions in `SKILL.md` frontmatter and validate changed skills before
  committing them.
- Prefer capability-based wording over repository names, fixed package layouts,
  usernames, ports, or tool paths. Discover project details from local
  instructions and configuration at runtime.
- Do not push or publish changes unless the user explicitly asks.
