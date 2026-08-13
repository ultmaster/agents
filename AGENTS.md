# Maintaining this repository

This repository publishes personal rules and reusable skills for unrelated
projects. These instructions govern changes to this repository itself.
`RULES.md` is the cross-repository guidance installed for Codex and Claude; it
is not this repository's maintenance guide.

## Source ownership

- `RULES.md` contains portable personal instructions installed at user scope.
- `AGENTS.md` contains repository-specific maintenance instructions.
- `CLAUDE.md` is a regular file that imports `AGENTS.md` for Claude Code.
- `skills/<name>/` is the only canonical skill tree.
- `subagents/<name>/` is the only canonical subagent tree. Never define a
  subagent under `skills/*/agents/`; those files are skill interface metadata.
- `setup.sh` owns installation into user-level discovery paths.
- `README.md` documents the layout, skill and subagent catalogs, and the
  installation contract.
- Keep the repository tree free of symlinks. Symlinks created by `setup.sh`
  must live outside the checkout.

## Place changes deliberately

- Put a durable preference in `RULES.md` only when it should apply across
  unrelated repositories and agent harnesses.
- Put a situational, reusable workflow in a focused skill under `skills/`.
- Put a delegable role — work a harness should hand to a separate agent with its
  own context and narrower tools — in a subagent under `subagents/`. A workflow
  the acting agent follows itself is a skill, not a subagent.
- Keep instructions about maintaining this library in `AGENTS.md`, not
  `RULES.md`.
- Leave project architecture, commands, package names, and exceptions in the
  project that owns them.
- Distill conversation history into concise guidance. Never commit raw
  transcripts, credentials, generated caches, or private runtime state.
- Preserve imported material unchanged in its import commit; make portability
  edits in a later commit so provenance remains reviewable.

## Change skills safely

- Follow the active harness's skill-creation guidance when adding or changing a
  skill. Keep its trigger conditions accurate in `SKILL.md` frontmatter.
- Prefer capability-based language and runtime discovery over repository names,
  usernames, fixed ports, package layouts, or machine-specific paths.
- Name each skill for what it concretely does. These skills install at user
  scope and shadow any project skill of the same name, so a generic name such as
  `ci`, `test`, or `ui-design` would make that project's own skill unreachable.
  Renaming a skill leaves stale user-level links behind; run `./setup.sh --prune`
  afterward.
- Keep scripts self-contained and avoid exposing credentials in command
  arguments or logs. Resolve bundled resources relative to the skill root, but
  resolve credentials, caches, and other per-repository state from the current
  repository's profile directory for that skill — the first of
  `$<SKILL>_PROFILE_DIR`, `<repository-root>/.agents/skills/<name>`,
  `<repository-root>/.claude/skills/<name>`, then the skill root. These skills
  install at user scope and are shared by every repository, so state stored
  beside the skill leaks across unrelated projects. Never create a profile
  directory in a repository that did not already opt in.
- Update the README skill catalog when a skill is added, removed, renamed, or
  materially changes purpose.
- Because setup installs each skill separately, rerun it after adding or
  removing a skill.

## Change subagents safely

- Give each role one directory, `subagents/<name>/`, holding `<name>.md` for
  Claude and `<name>.toml` for Codex. Keep each definition in its harness's
  native format rather than generating both from a neutral manifest; the schemas
  differ enough that the generator becomes a third thing to maintain.
- Keep the directory name, both filenames, and both `name` fields identical, and
  keep the Claude system prompt byte-identical to the Codex
  `developer_instructions`. Two native definitions are only safe while they say
  the same thing, so write the shared body in harness-neutral prose.
- Claude requires `name` and `description`; Codex requires `name`,
  `description`, and `developer_instructions`. Add optional keys only when they
  express a real constraint of the role, and prefer constraints that outlive a
  release — a tool allowlist or a read-only sandbox rather than a model name.
- Put everything the role needs in the definition itself. A skill is a directory
  that can carry `references/` and `scripts/` beside `SKILL.md`; a subagent is a
  single file in both harnesses, with no bundled-resource contract. Claude scans
  its agents tree recursively for `.md` files, so a reference document installed
  there would be read as a malformed definition rather than a resource.
- Name each subagent for what it concretely does, as with skills. A personal
  subagent is offered in every repository, so a generic name competes with
  whatever each project means by that word. Renaming one leaves stale user-level
  links behind; run `./setup.sh --prune` afterward.
- Keep the description a description of when to delegate. Both harnesses route
  work by matching it, so an inaccurate one silently misroutes.
- Update the README subagent catalog when a subagent is added, removed, renamed,
  or materially changes purpose, and rerun setup after adding or removing one.

## Preserve the installer contract

- Keep `setup.sh` idempotent and conflict-safe. It must report all conflicts
  before writing and must never overwrite or delete an existing user path.
- Keep `--dry-run` truthful and preserve support for `HOME`, `CODEX_HOME`,
  `CLAUDE_CONFIG_DIR`, `AGENTS_HOME`, and isolated `--target-home` verification.
- Keep link ownership evidence-based. A link may be pruned, replaced, or
  uninstalled only when the manifest records it or it points into this
  repository's skills or subagents directory; pruning and replacement
  additionally require that its target no longer exists. Everything else is the
  user's.
- Keep `--uninstall` limited to links this installer owns and the manifest it
  wrote. It must never remove a directory or a link to another source.
- Install individual skill and subagent links so unrelated user skills and
  subagents can coexist. Never replace or write into `~/.codex/skills`, which
  may contain managed skills, and never write into a user's `agents` directory
  beyond the individual definitions this repository owns.
- Do not make `setup.sh` create links inside this repository.

## Verify changes

- Run `git diff --check`.
- Run `bash -n` on `setup.sh` and every changed shell script; run `shellcheck`
  when it is available.
- Validate every changed skill with the skill validator and every changed
  subagent with the subagent validator, and forward-test any changed helper
  against a disposable fixture.
- For installer changes, exercise dry-run, first install, idempotent reinstall,
  preserved-conflict behavior, a relocated checkout, and uninstall under a
  disposable `--target-home`.
- Confirm `find . -path './.git' -prune -o -type l -print` produces no paths.
- Before committing, confirm the index contains no mode `120000` entries.

Make each completed stage a coherent commit. Treat committing and pushing as
separate actions, and do not push unless the user authorized it.
