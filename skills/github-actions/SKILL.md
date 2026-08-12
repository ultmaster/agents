---
name: github-actions
description: Operate and diagnose GitHub Actions safely in any repository. Use when a user asks to inspect checks, find a failing workflow run, read failed job logs, wait for a run, rerun or cancel a run, or dispatch a workflow. Discover workflows, commands, repository, and branch from the current project instead of assuming a package manager or repository layout.
---

# GitHub Actions

## Orient from the repository

1. Read the repository's agent instructions and identify its root with
   `git rev-parse --show-toplevel`.
2. Prefer the repository's own CI skill when it has one. A project that
   documents its workflows, job layout, and helper commands in its own skill
   knows things this one cannot; follow it for what to run and where. This skill
   still owns the safety rules below.
3. Confirm the provider from local configuration: `.github/workflows/*.yml` or
   `*.yaml`. A repository may run a different provider instead or as well.
4. Read the relevant workflow before acting. Copy its command, working directory,
   runtime, service, and environment assumptions exactly. Discover the project's
   package/build tool from its lockfiles, manifests, and scripts; never assume one.
5. Resolve the remote deliberately. The helper prefers `upstream` when it exists,
   then `origin`; override with `--remote`/`CI_REMOTE` or `--repo`/`CI_REPO`.

## Reproduce before spending CI

Run the narrow failing command locally first, then the widest relevant local group
when shared code or test helpers changed. Match the workflow command and
environment as closely as practical. Before any dispatch or rerun, state:

- what evidence the run should produce;
- why local verification is insufficient; and
- what each likely outcome changes next.

Do not use CI as an exploratory loop. Keep diagnostic instrumentation separate
from the production fix when it could prevent the fix from building.

Live commands use network credentials and may need the harness's approved
out-of-sandbox execution path. Do not work around sandbox policy. Run `--dry-run`
locally first. Dispatching, rerunning, and cancelling require an explicit `--yes`;
use them only when the user authorized the outward action.

## Helper

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
`--ref` or `CI_BRANCH`, so a fork-only current branch cannot be inferred against
the upstream repository.

Read-only commands: `list`, `await`, `watch`, `view`. Gated commands: `dispatch`,
`rerun`, `cancel`. Authentication comes from `gh`; do not store GitHub tokens here.

## Triage sequence

1. Identify the exact run, commit, workflow, and failing job.
2. Read the first causal failure, not only the final cascade.
3. Reproduce the workflow step locally.
4. Change the smallest relevant surface and rerun local verification.
5. Use a single well-instrumented remote run only when it adds evidence local
   execution cannot provide.
