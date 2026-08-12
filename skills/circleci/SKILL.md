---
name: circleci
description: Operate and diagnose CircleCI safely in any repository. Use when a user asks to inspect pipelines, reproduce a pipeline failure, read job step status and log URLs, wait for a pipeline, trigger or cancel work, or manage pipeline definitions. Discover the project slug, pipeline parameters, commands, and branch from the current repository instead of assuming a package manager or repository layout.
---

# CircleCI

## Orient from the repository

1. Read the repository's agent instructions and identify its root with
   `git rev-parse --show-toplevel`.
2. Prefer the repository's own CI skill when it has one. A project that
   documents its pipelines, job layout, and helper commands in its own skill
   knows things this one cannot; follow it for what to run and where. This skill
   still owns the safety rules below.
3. Confirm the provider from local configuration: `.circleci/config.yml` or
   `config.yaml`. A repository may run a different provider instead or as well.
4. Read the relevant config before acting. Copy its command, working directory,
   executor, service, and environment assumptions exactly. Discover the project's
   package/build tool from its lockfiles, manifests, and scripts; never assume one.
5. Resolve the remote deliberately. The helper prefers `upstream` when it exists,
   then `origin`; override with `--remote`/`CI_REMOTE` or
   `--project`/`CIRCLECI_PROJECT_SLUG`.

## Reproduce before spending CI

Run the narrow failing command locally first, then the widest relevant local group
when shared code or test helpers changed. Match the CI command and environment as
closely as practical. Before any trigger, state:

- what evidence the pipeline should produce;
- why local verification is insufficient; and
- what each likely outcome changes next.

Do not use CI as an exploratory loop. Keep diagnostic instrumentation separate
from the production fix when it could prevent the fix from building.

Live commands use network credentials and may need the harness's approved
out-of-sandbox execution path. Do not work around sandbox policy. Run `--dry-run`
locally first. Triggering, cancelling, and deleting require an explicit `--yes`;
use them only when the user authorized the outward action.

## Helper

Use `scripts/circleci.sh`. Copy `.env.example` to `.env` only when a local token
file is necessary, and never commit `.env`.

The token is read from the repository's own profile directory when it has one —
the first of `$CIRCLECI_PROFILE_DIR`, `<repository-root>/.agents/skills/circleci`,
`<repository-root>/.claude/skills/circleci`, then this skill's root — so one
project's credentials never become another's default. A repository that carries a
profile owns its settings outright; this skill's `.env` is not consulted as a
fallback there. `$CIRCLECI_ENV_FILE` overrides the file directly.

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

Project selection is `--project`, `CIRCLECI_PROJECT_SLUG`, then the chosen git
remote. Every trigger requires an explicit `--branch` or `CI_BRANCH`, so a
fork-only current branch cannot be inferred against the upstream project. Every
trigger and mutation requires `--yes`; `--dry-run` never loads credentials or calls
the network.

## Triage sequence

1. Identify the exact pipeline, commit, workflow, and failing job.
2. Read the first causal failure, not only the final cascade.
3. Reproduce the failing step locally.
4. Change the smallest relevant surface and rerun local verification.
5. Use a single well-instrumented remote pipeline only when it adds evidence local
   execution cannot provide.
