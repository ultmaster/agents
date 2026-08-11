---
name: ci
description: Use to run and triage OctoStaff umbrella CI. CI is split across two systems — GitHub Actions runs the build + lint/tsc + unit-tests job, and npm publish, firing automatically on push to dev / PRs / the vX.Y.Z tag; CircleCI runs only the large integration suites (Postgres testcontainers, docker-agent, Playwright), triggered manually. Use circleci.sh for CircleCI operations and gha.sh for GitHub Actions operations. Every CircleCI trigger costs minutes.
---

# CI

OctoStaff CI runs across two systems. Everything runs in the umbrella **monorepo**
— all packages are in-tree (no submodules), so a checkout already has the whole
workspace; CI just installs and builds it.

| System             | What                                                          | Trigger                                          |
| ------------------ | ------------------------------------------------------------- | ------------------------------------------------ |
| **GitHub Actions** | `ci` (single `build-test` job: build + lint/tsc + unit tests) | automatic on push to `dev` + PRs targeting `dev` |
| **GitHub Actions** | `release` (npm publish: sdk + bubble + claude-scuba + codex-scuba + reef) | automatic on the `vX.Y.Z` umbrella tag           |
| **GitHub Actions** | `mirror` (content-sync packages to standalone repos)          | automatic on push to umbrella `main`             |
| **CircleCI**       | integration suites only (`.circleci/config.yml`)              | manual, via `circleci.sh` (this skill)           |

The integration suites stay on CircleCI because they need a real Docker daemon
(testcontainers Postgres, `docker agent serve a2a`), a browser, or a stable
pixel-rendering env — CircleCI's `machine` VMs. The cheap/fast build + lint/tsc + unit work
moved to GitHub Actions (cheaper, auto on push). `circleci.sh` owns the
CircleCI integration pipeline and triggers the default `.circleci/config.yml`;
`gha.sh` owns GitHub Actions triage/watch operations.

## GitHub Actions side — drive through the helper

```bash
pnpm ci:gha <command> [options]                 # from the umbrella root
<skill-root>/ci/scripts/gha.sh <command> [options]   # or by path
```

The `mirror` workflow needs the repo secret `OCTOSTAFF_BOT_SSH_KEY` (octostaff-bot
SSH private key, now with **write** access) to push each package out to its
standalone repo; `release` also needs `NPM_TOKEN`. The `ci` workflow needs no
secrets (the monorepo checkout already contains every package). Workflows live in
`.github/workflows/`; the shared bootstrap is the composite `.github/actions/setup`.

**Commands:** `list`, `await`, `watch`, `view`, `rerun`, `cancel`.

### GitHub Actions auth

`gha.sh` checks `gh auth status -h github.com` before every live command. Configure
one of these before using it:

```bash
gh auth login --hostname github.com --git-protocol ssh --scopes repo,workflow
```

For non-interactive use, set `GH_TOKEN` (or `GITHUB_TOKEN`) in the environment.
The token must have access to `octostaff/umbrella`. Fine-grained tokens need
**Actions: read** for `list` / `await` / `watch` / `view`, and **Actions: write**
for `rerun` / `cancel`. Classic PATs should include `repo`; include `workflow`
when the same credential is also used for workflow-file maintenance.

```bash
gha.sh list --workflow ci.yml --branch dev
gha.sh await --workflow ci.yml --branch dev --sha <commit-sha>
gha.sh view <run-id> --failed
```

## CircleCI side — drive through the helper

Self-contained; reads its own `.env`:

```bash
pnpm ci:circleci <command> [options]                  # from the umbrella root
<skill-root>/ci/scripts/circleci.sh <command> [options]   # or by path
```

`<skill-root>` is `.agents/skills` or `.claude/skills` (a symlink to it). Below,
`circleci.sh` and `gha.sh` are shorthand for those paths (or their `pnpm ci:circleci`
/ `pnpm ci:gha` umbrella-root aliases).

### Commands

**Trigger** — costs CircleCI minutes, requires `--yes`:

- `tests [--all | --module <name> …]` — the integration pipeline; default runs every gating job. Modules: `bubble`, `claude-scuba`, `codex-scuba`, `reef`, `starfish`, `playwright`, `query-cost` (dashes/underscores interchangeable). **`query-cost` is opt-in only** — it is a profiling report, not a gate, and the priciest job here, so neither the default `tests` nor `release.sh preflight` lights it. Name it explicitly (`tests --module query-cost`) when query cost is what you are working on, then read the `profile-report` artifact off the job.

**Triage** — read-only unless noted:

- `list [--branch dev]` — recent pipelines.
- `view <pipeline-id>` / `status <pipeline-id>` — a pipeline's workflows (name, status, id).
- `jobs <workflow-id>` — a workflow's jobs (number, status, name).
- `job <job-number>` — per-step detail + failure log URLs.
- `await <pipeline-id>` / `watch <pipeline-id>` — poll a pipeline to a terminal state.
- `cancel <workflow-id> --yes` — cancel a running workflow.

**Legacy definition cleanup:**

- `definitions` — list leftover multi-config pipeline definitions.
- `delete-definition <name> --yes` — delete one by name.

**Flags:** `--yes` confirms a trigger/write · `--dry-run` previews the API call · `--watch` polls a trigger to completion.

### Typical flow

```bash
circleci.sh tests --module bubble --yes --watch   # one module's integration job, wait
circleci.sh view <pipeline-id>                     # → workflow id
circleci.sh jobs <workflow-id>                     # → job number
circleci.sh job <job-number>                       # why it failed (steps + log URLs)
```

## Before triggering: reproduce locally FIRST. Always.

> **CI costs money — CircleCI especially. Treat every trigger as a paid
> measurement.** The user has flagged "you wasted CI again" more than once. A
> green run on your machine under different conditions is **not** evidence the CI
> run will pass. Only pass `--yes` when the user asked for a run.

Before triggering CI:

1. **Mirror the GHA `ci` build + `tsc` steps verbatim** from the umbrella root: `pnpm --filter '!@octostaff/office' --filter '!@octostaff/tui' -r --if-present tsc` (the bare `pnpm tsc` aggregate includes the unmaintained office/tui and fails). Cross-package casts pass a scoped tsc but fail this root tsc the same way CI does.
2. **When you touch a test helper, run the _full_ integration group** (`pnpm --filter @octostaff/integration-tests test:<group>`), not just the file you opened — helpers are exercised differently by sibling tests. Most groups need Docker (run outside the sandbox).
3. **Mirror CI's exact command.** Read the relevant `.github/workflows/ci.yml` (the `build-test` job) or `.circleci/config.yml` (integration) and copy the step verbatim — don't substitute a package's own `tsc`/`test` script.
4. **Don't combine a production fix with debug instrumentation on the same branch.** If the debug code fails to compile, the production fix doesn't ship either.

For a module's integration group specifically: `pnpm --filter @octostaff/<pkg>... -r build`, then `pnpm --filter @octostaff/integration-tests test:<group>`.

## Plan each CI run

Before pressing the button, write down (mentally is fine, in the commit message is
better):

- What evidence will this run produce?
- What will I do with each possible outcome?

If the honest answer is "let's see what happens," do more local probing first.
Server-side diagnostics (`DEBUG=...`, extra logs, timing dumps) are legitimate when
local genuinely can't reproduce — but enable them deliberately, not as a fishing
expedition. **A single well-instrumented CI run beats three blind ones.**

## Notes

- **SSH / the `octostaff-bot` key:** now used only by the GitHub Actions **`mirror`** workflow, which loads the `OCTOSTAFF_BOT_SSH_KEY` secret to **push** each package out to its standalone repo (the bot has write access). CI checkouts no longer clone submodules, so neither `ci` (GHA) nor the CircleCI jobs need the key anymore. A mirror push failing with `Repository not found` / permission denied means the key isn't loaded or the bot lost write access.
- A CircleCI trigger with **no matching `run_*` parameter** creates a pipeline record but zero workflows — that's the gate working, not a bug.
- CircleCI gate params (`run_ci`, `run_tests`, per-module `run_bubble`/`run_claude_scuba`/`run_codex_scuba`/`run_reef`/`run_starfish`/`run_playwright`/`run_query_cost`) default `false`, so a bare trigger produces zero workflows. `release.sh preflight` consumes `run_ci`/`run_tests` indirectly through this skill — **do not rename them**. `run_query_cost` is deliberately absent from both the `run_ci` and `run_tests` conditions: it profiles rather than gates, so it must never ride along on a release preflight.
- **Authoring `.circleci/config.yml`:** add `no_output_timeout` only to steps that can hang silently (Vitest, the integration suite, Playwright); lint/format/build stream output and don't need it.
- After reverting to the single `.circleci/config.yml`, delete any leftover multi-config definitions (`tests`, `checks`, or `release`) deliberately with `circleci.sh delete-definition <name> --yes`.
- `release` delegates here for integration: `release preflight` runs `circleci.sh tests` (CircleCI integration) alongside `gha.sh await` for the GitHub Actions `ci` run. The npm publish is the GitHub Actions `release` workflow (tag-triggered) — follow it with `gha.sh await --workflow release.yml --ref vX.Y.Z`; that same run also builds the bubble/starfish + bot images to GHCR (`docker-apps`/`docker-amphibian` jobs). Deploying the images to Azure is a separate step (`release` has no `deploy` subcommand).
