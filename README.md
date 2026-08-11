# Personal agent library

This repository is the source of truth for personal instructions, skills, and
agent configuration that are useful across projects. Project-specific knowledge
stays with its project; this library holds preferences and workflows that should
travel.

## Layout

- `AGENTS.md` contains concise, always-on instructions shared by agent harnesses.
- `CLAUDE.md` points to `AGENTS.md`, so Claude and Codex receive the same baseline.
- `.agents/skills/` is the canonical home for portable skills.
- `.claude/skills` points to `.agents/skills/` for Claude Code discovery.
- `.codex/agents/` and `.codex/rules/` hold reusable Codex-only profiles and
  execution rules when a behavior cannot be expressed portably.

## Using the library from another repository

Link only the material the project needs. For example:

```bash
mkdir -p .agents/skills
ln -s ~/agents/.agents/skills/ai-comment .agents/skills/ai-comment
mkdir -p .claude
ln -s ../.agents/skills .claude/skills
```

Keep project-specific overrides in the consuming repository. When a local rule
conflicts with this library, the local rule should win.

Do not commit credentials, generated caches, or raw conversation transcripts.
Extract durable guidance from history and record the guidance instead.
