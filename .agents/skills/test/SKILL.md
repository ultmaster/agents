---
name: test
description: Design, write, run, and debug tests in any repository. Use when adding regression coverage, choosing between unit/integration/end-to-end layers, reproducing a failure, validating database or UI behavior, updating snapshots, or deciding which checks prove a change. Prefer real dependencies inside the behavior boundary, fake only external systems, mirror CI commands exactly, and never hide an unavailable or failing verification step.
---

# Testing

Test the behavior the change claims to provide. Keep dependencies inside that
behavior boundary real; replace dependencies outside it with deterministic
fakes. A mock-heavy test that cannot expose constraints, serialization,
transactions, races, or rendering behavior is at the wrong layer.

## Discover the project contract

Before choosing a command or location, inspect:

- `AGENTS.md`, `CLAUDE.md`, and nested instructions;
- build and package manifests;
- CI workflows and their exact commands;
- nearby source/tests, shared fixtures, and test configuration.

Follow the repository's existing test layout and naming. Co-locate or mirror the
source structure when that is the established convention. Do not invent a new
runner or helper when an existing layer already owns the behavior.

## Choose the smallest truthful layer

| Layer | Use it to prove | Keep real |
| --- | --- | --- |
| Unit | Pure logic and narrow state transitions | The function/module under test |
| Component/service | A component, route, or service contract | That component and its internal collaborators |
| Integration | Boundaries where real semantics matter | Database, filesystem, queue, serializer, process, or package boundary in scope |
| End-to-end | A user-visible or cross-service journey | The application path the user actually exercises |
| Manual runtime | Visual quality, browser/platform behavior, or hardware interaction | The rendered/running system |

Prefer integration coverage when replacing a dependency would hide the failure
class. Use containers or disposable local services when practical. Fake paid,
unstable, rate-limited, or third-party APIs unless the task explicitly requires
a live compatibility probe; pair any live probe with deterministic coverage.

## Workflow

1. Reproduce the failure or state the invariant before changing code. For a bug,
   add a regression test that fails for the right reason when feasible.
2. Run the narrowest relevant test while iterating.
3. Run the owning package/suite after the narrow test passes.
4. Run every repository-required lint, type, build, and test check affected by
   the change. Copy CI commands from the workflow instead of substituting a
   similar local command.
5. Re-run the original reproduction and report exactly what ran.

If a test helper, shared fixture, public contract, generated artifact, or build
output changes, widen verification to every consumer. Rebuild consumed outputs
before integration tests when the project resolves packages from `dist`, build
directories, wheels, binaries, or generated clients.

## Failure discipline

- Read the first meaningful failure and determine whether it is introduced,
  pre-existing, environmental, or flaky. Do not repair unrelated failures
  without authorization.
- Never weaken an assertion, add a retry, skip a test, or refresh a snapshot
  merely to get green. Explain why the new expectation is correct.
- If required infrastructure is unavailable or sandboxed, request the needed
  execution permission or give the exact unrun command. Do not claim the suite
  passed or silently fall back to a weaker layer.
- Preserve logs and seed values needed to reproduce nondeterministic failures.
  Fix the race or isolation problem before reaching for retries.
- Do not inspect secret files to guess whether a live test can run. Invoke the
  documented test path and handle its explicit prerequisite failure.

## Stateful systems and snapshots

For schema or migration work, test both a fresh install and upgrades from every
supported historical shape. Treat committed historical migration fixtures as
immutable; add a new version rather than rewriting the past. Review generated
schema fingerprints and data-preservation assertions deliberately.

For visual or serialized snapshots, inspect the diff as an artifact. Update a
baseline only after confirming the behavior/design change is intended. Follow
the repository's storage convention for large binaries (for example Git LFS)
and never rewrite history without explicit approval.

## UI changes

Automated component and interaction coverage is necessary but does not prove
the rendered result looks right. After tests pass, use the `ui-verifier` skill
to drive the real interface, inspect the screenshot, and compare it with the
approved design when one exists.

## Report

Name the commands and outcomes, any required checks that were not run, and the
reason. Distinguish a verified fix from a best-effort change with environmental
gaps.
