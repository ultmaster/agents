# Personal agent library

This repository is the source of truth for personal instructions and reusable
skills shared by Codex and Claude across unrelated projects. Repository-specific
architecture and commands stay in each project; this library holds portable
working preferences and workflows.

## What it contains

- `RULES.md` — portable personal instructions installed for Codex and Claude.
- `AGENTS.md` — repository-specific instructions for maintaining this library.
- `CLAUDE.md` — a regular Claude Code import of `AGENTS.md`.
- `setup.sh` — a conflict-safe installer for user-level rule and skill links.
- `skills/` — the canonical reusable skill tree.

The repository itself contains no symlinks. `setup.sh` creates links only in
user-level discovery paths outside the checkout.

## Skills

| Skill | Purpose |
| --- | --- |
| `ai-comment` | Triage typed AI markers without guessing away questions. |
| `ci` | Reproduce, inspect, trigger, and diagnose CI across providers. |
| `issue-tracker` | Work GitHub issues as durable, evidence-backed task records. |
| `test` | Choose truthful test boundaries and verify changes at the right layers. |
| `ui-design` | Run the design-review-implementation-promotion loop for visual work. |
| `ui-verifier` | Prove UI changes in the running application without harming user processes. |
| `windows-dev` | Diagnose shell and platform differences on Windows and WSL. |

## Install

Clone the repository at a stable location, preview the links, then install them:

```bash
git clone git@github.com:ultmaster/agents.git ~/agents
cd ~/agents
./setup.sh --dry-run
./setup.sh
```

The setup is idempotent and creates these links:

| Consumer | Link | Source |
| --- | --- | --- |
| Codex rules | `~/.codex/AGENTS.md` or `$CODEX_HOME/AGENTS.md` | `RULES.md` |
| Claude rules | `~/.claude/CLAUDE.md` or `$CLAUDE_CONFIG_DIR/CLAUDE.md` | `RULES.md` |
| Codex skills | `~/.agents/skills/<name>` | `skills/<name>` |
| Claude skills | `~/.claude/skills/<name>` or `$CLAUDE_CONFIG_DIR/skills/<name>` | `skills/<name>` |

Each skill is linked individually so other personal skills can coexist. The
installer never replaces a file, directory, dangling link, or link to another
source; it reports every conflict before changing anything. It does not touch
`~/.codex/skills`, where bundled and managed Codex skills may live.

Codex and Claude detect skill edits automatically in most cases. Restart the
client if a newly created user skill directory does not appear. The target paths
follow the official [Codex instruction](https://learn.chatgpt.com/docs/agent-configuration/agents-md),
[Codex skill](https://learn.chatgpt.com/docs/build-skills),
[Claude instruction](https://code.claude.com/docs/en/memory), and
[Claude skill](https://code.claude.com/docs/en/skills) discovery contracts.

## Maintaining the library

Follow `AGENTS.md` when changing this repository. Keep only cross-repository
preferences and workflows in `RULES.md` and `skills/`; leave unavoidable
project values in the project that owns them.

Never commit credentials, generated caches, or raw conversation transcripts.
Validate every changed skill with the skill validator and test bundled scripts
before committing it.
