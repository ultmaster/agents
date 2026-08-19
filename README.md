# Personal agent library

This repository is the source of truth for personal instructions and reusable
skills shared by Codex and Claude across unrelated projects. Repository-specific
architecture and commands stay in each project; this library holds portable
working preferences and workflows.

## What it contains

- `RULES.md` — portable personal instructions installed for Codex and Claude.
- `AGENTS.md` — repository-specific instructions for maintaining this library.
- `CLAUDE.md` — a regular Claude Code import of `AGENTS.md`.
- `setup.sh` — a conflict-safe installer for user-level rule, skill, and
  subagent links.
- `skills/` — the canonical reusable skill tree.
- `subagents/` — the canonical subagent tree, one directory per role.

The repository itself contains no symlinks. `setup.sh` creates links only in
user-level discovery paths outside the checkout.

## Skills

| Skill | Purpose |
| --- | --- |
| `ai-marker-triage` | Triage typed AI markers without guessing away questions. |
| `circleci` | Reproduce, inspect, trigger, and diagnose CircleCI pipelines. |
| `github-actions` | Reproduce, inspect, dispatch, and diagnose workflow runs. |
| `github-issues` | Work GitHub issues as durable records and archive inactive terminal issues. |
| `test-strategy` | Choose truthful test boundaries and verify changes at the right layers. |
| `ui-work` | Design, implement, and prove visual changes in the running interface. |
| `windows-dev` | Diagnose shell, filesystem, build, and process failures on Windows and WSL. |

These names are deliberately concrete. A skill installed at user scope applies in
every repository, and Claude Code resolves a personal skill above a project skill
of the same name — so a personal skill called `ci` would make every project's own
`ci` skill unreachable. Naming each skill for what it actually does leaves the
natural generic names free for the projects that own them.

## Subagents

| Subagent | Purpose |
| --- | --- |
| `ui-screenshot-reviewer` | Read rendered UI captures and report what is visually wrong. |

Each `subagents/<role>/` directory owns one logical role in both harnesses'
native formats: `<role>.md` with YAML frontmatter for Claude, and `<role>.toml`
for Codex. The directory name, both filenames, and both `name` fields agree, and
the Claude system prompt and the Codex `developer_instructions` hold identical
text — the test suite enforces all of it, so keeping two native definitions never
turns into two diverging ones. Neither format is generated from the other: their
schemas differ enough that a generator would be a third thing to maintain.

Subagent names are concrete for the same reason skill names are. A personal
subagent is offered in every repository, so a name like `reviewer` would compete
with whatever each project means by that word. Precedence runs the other way
here — a project's own `.claude/agents/<name>.md` wins over the personal one —
so a generic name collides quietly rather than shadowing.

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
| Codex subagents | `~/.codex/agents/<name>.toml` or `$CODEX_HOME/agents/<name>.toml` | `subagents/<name>/<name>.toml` |
| Claude subagents | `~/.claude/agents/<name>.md` or `$CLAUDE_CONFIG_DIR/agents/<name>.md` | `subagents/<name>/<name>.md` |

Each skill and each subagent definition is linked individually so other personal
skills and subagents can coexist. The installer never replaces a file,
directory, dangling link, or link to another source; it reports every conflict
before changing anything. It does not touch `~/.codex/skills`, where bundled and
managed Codex skills may live.

Every install records what it linked in `~/.agents/setup-manifest`, so a later
run recognizes its own links even after this checkout is renamed or moved.
Moving the checkout leaves every link dangling; rerun `./setup.sh --prune` from
the new location to re-point them. Run `./setup.sh --uninstall` before deleting
the checkout: it removes the links it owns and the manifest, leaving
directories and unrelated links in place.

`CODEX_HOME` and `CLAUDE_CONFIG_DIR` relocate the two rules files and the
subagent definitions, which each client discovers only under its own
configuration directory. Skills live under `AGENTS_HOME` (default `~/.agents`)
because `~/.agents/skills` is a shared discovery path rather than Codex state.
`--target-home` ignores all three.

Codex and Claude detect skill and subagent edits automatically in most cases.
Restart the client if a newly created user skill or agents directory does not
appear. The target paths follow the official
[Codex instruction](https://learn.chatgpt.com/docs/agent-configuration/agents-md),
[Codex skill](https://learn.chatgpt.com/docs/build-skills),
[Codex subagent](https://learn.chatgpt.com/docs/agent-configuration/subagents),
[Claude instruction](https://code.claude.com/docs/en/memory),
[Claude skill](https://code.claude.com/docs/en/skills), and
[Claude subagent](https://code.claude.com/docs/en/sub-agents) discovery
contracts.

## Maintaining the library

Follow `AGENTS.md` when changing this repository. Keep only cross-repository
preferences and workflows in `RULES.md`, `skills/`, and `subagents/`; leave
unavoidable project values in the project that owns them.

Never commit credentials, generated caches, or raw conversation transcripts.
Validate every changed skill and subagent with the validators and test bundled
scripts before committing.

## Verify

The deterministic test suite runs on Linux and requires Bash 5, Python 3.11 or
newer, `skills-ref==0.1.1`, Git, ShellCheck, curl, file, jq, lsof, ripgrep,
`setsid`, and `ss`. Run the same entry point used by GitHub Actions:

```bash
./tests/run.sh
```

The suite validates every skill and subagent definition, exercises the installer
in disposable homes, and tests bundled helpers without credentials or live
GitHub and CircleCI API calls.
