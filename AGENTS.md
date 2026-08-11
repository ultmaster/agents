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
- `setup.sh` owns installation into user-level discovery paths.
- `README.md` documents the layout, skill catalog, and installation contract.
- Keep the repository tree free of symlinks. Symlinks created by `setup.sh`
  must live outside the checkout.

## Place changes deliberately

- Put a durable preference in `RULES.md` only when it should apply across
  unrelated repositories and agent harnesses.
- Put a situational, reusable workflow in a focused skill under `skills/`.
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

## Preserve the installer contract

- Keep `setup.sh` idempotent and conflict-safe. It must report all conflicts
  before writing and must never overwrite or delete an existing user path.
- Keep `--dry-run` truthful and preserve support for `HOME`, `CODEX_HOME`,
  `CLAUDE_CONFIG_DIR`, and isolated `--target-home` verification.
- Install individual skill links so unrelated user skills can coexist. Never
  replace or write into `~/.codex/skills`, which may contain managed skills.
- Do not make `setup.sh` create links inside this repository.

## Verify changes

- Run `git diff --check`.
- Run `bash -n` on `setup.sh` and every changed shell script; run `shellcheck`
  when it is available.
- Validate every changed skill with the skill validator and forward-test any
  changed helper against a disposable fixture.
- For installer changes, exercise dry-run, first install, idempotent reinstall,
  and preserved-conflict behavior under a disposable `--target-home`.
- Confirm `find . -path './.git' -prune -o -type l -print` produces no paths.
- Before committing, confirm the index contains no mode `120000` entries.

Make each completed stage a coherent commit. Treat committing and pushing as
separate actions, and do not push unless the user authorized it.
