---
name: ci
description: Operate and diagnose repository CI safely across GitHub Actions and CircleCI. Use when a user asks to inspect checks, reproduce a CI failure, read logs, wait for a run or pipeline, rerun or cancel work, or explicitly trigger CI. Discover providers, workflows, commands, repository, and branch from the current project instead of assuming a package manager or repository layout.
---

# CI

## Orient from the repository

1. Read the repository's agent instructions and identify its root with
   `git rev-parse --show-toplevel`.
2. Discover providers from local configuration:
   - GitHub Actions: `.github/workflows/*.yml` or `*.yaml`
   - CircleCI: `.circleci/config.yml` or `config.yaml`
3. Read the relevant workflow before acting. Copy its command, working directory,
   runtime, service, and environment assumptions exactly. Discover the project's
   package/build tool from its lockfiles, manifests, and scripts; never assume one.
4. Resolve the remote deliberately. The helpers prefer `upstream` when it exists,
   then `origin`; override with `--remote`, `CI_REMOTE`, `--repo`/`CI_REPO`, or
   `--project`/`CIRCLECI_PROJECT_SLUG`.

## Reproduce before spending CI

Run the narrow failing command locally first, then the widest relevant local group
when shared code or test helpers changed. Match the CI command and environment as
closely as practical. Before any trigger or rerun, state:

- what evidence the run should produce;
- why local verification is insufficient; and
- what each likely outcome changes next.

Do not use CI as an exploratory loop. Keep diagnostic instrumentation separate
from the production fix when it could prevent the fix from building.

Live CI commands use network credentials and may need the harness's approved
out-of-sandbox execution path. Do not work around sandbox policy. Run `--dry-run`
locally first. Triggering, rerunning, cancelling, dispatching, and deleting require
an explicit `--yes`; use them only when the user authorized the outward action.

## GitHub Actions helper

Use `scripts/gha.sh`. It wraps `gh run` while making repository selection visible.

```bash
scripts/gha.sh list --workflow ci.yml --branch feature/name --dry-run
scripts/gha.sh await --workflow ci.yml --sha <commit> --dry-run
scripts/gha.sh view <run-id> --failed --dry-run
scripts/gha.sh rerun <run-id> --failed --dry-run
scripts/gha.sh rerun <run-id> --failed --yes
scripts/gha.sh dispatch ci.yml --ref feature/name --field key=value --dry-run
```

Selection order is explicit flag, environment, then git discovery. `--repo` accepts
`OWNER/REPO` or `HOST/OWNER/REPO`. Without `--workflow`, `list` and `await` search
all workflows. Read-only branch-oriented commands use `CI_BRANCH`, the current
branch, then the chosen remote's default branch. `dispatch` requires an explicit
`--ref` or `CI_BRANCH`.

Read-only commands: `list`, `await`, `watch`, `view`. Gated commands: `dispatch`,
`rerun`, `cancel`. Authentication comes from `gh`; do not store GitHub tokens here.

## CircleCI helper

Use `scripts/circleci.sh`. Copy `.env.example` to `.env` only when a local token
file is necessary, and never commit `.env`.

```bash
scripts/circleci.sh trigger --branch feature/name --parameter run_tests=true --dry-run
scripts/circleci.sh tests --module api --branch feature/name --dry-run
scripts/circleci.sh list --branch feature/name
scripts/circleci.sh view <pipeline-id>
scripts/circleci.sh jobs <workflow-id>
scripts/circleci.sh job <job-number>
scripts/circleci.sh cancel <workflow-id> --dry-run
```

`trigger` accepts repeatable `--parameter KEY=VALUE` or one
`--parameters-json '{...}'`. Values `true`, `false`, `null`, and numbers retain
their JSON types; other values are strings. `tests` is a compatibility convenience:
it requires a local CircleCI config and discovers `run_tests` and `run_<module>`
pipeline parameters from it; without either convention, it performs that config's
ordinary parameterless trigger. Inspect the config before relying on any convention.

CircleCI project selection is `--project`, `CIRCLECI_PROJECT_SLUG`, then the chosen
git remote. Every trigger requires an explicit `--branch` or `CI_BRANCH`, so a
fork-only current branch cannot be inferred against the upstream project. Every
trigger and mutation requires `--yes`; `--dry-run` never loads credentials or calls
the network.

## Triage sequence

1. Identify the exact run, commit, workflow, and failing job.
2. Read the first causal failure, not only the final cascade.
3. Reproduce the workflow step locally.
4. Change the smallest relevant surface and rerun local verification.
5. Use a single well-instrumented remote run only when it adds evidence local
   execution cannot provide.
