---
name: test
description: Use when writing, running, or debugging OctoStaff tests — the testing philosophy (real-dependency-first, fake only outside the boundary), the cross-package integration suites under integration-tests/ (claude-scuba, codex-scuba, bubble, starfish, reef, playwright, query-cost groups), the bubble Postgres schema upgrade/fingerprint guard, UI verification (bubble fixtures → starfish), Git-LFS visual baselines, and the sandbox guardrails for verification.
---

# Testing

Test files mirror the source file structure. For every test, keep the behavior
under test real; fake only dependencies outside the test boundary. Tests validate
our code, not the uptime, latency, or behavior of external systems.

## Rule of Thumb

Use the real dependency when its behavior is part of what the test is proving.
Otherwise replace it with a fake/stub/mock. Prefer integration tests over mock
tests — mocking the database hides constraint violations, transaction semantics,
and race conditions.

- **Frontend** (`vitest` + RTL, `starfish`): real UI, fake backend/network.
- **Backend** (`vitest`, `octopus` API routes): real route + service logic, fake third-party services; use `testcontainers` whenever possible.
- **End-to-end** (`Playwright`): real frontend ↔ backend flow, fake third-party services only where necessary for stability.

## External Dependencies

- **Postgres**: real, via `testcontainers` in `octopus` and the `bubble` integration group when persistence behavior matters.
- **Valkey / Redis / BullMQ**: real local services via `docker compose`. Tests should skip gracefully when unavailable.
- **OpenAI / model APIs**: always `MockLanguageModelV3` (or equivalent) in automated tests.
- **Live agent SDKs**: see the integration-tests `itLive` rule below.

## Running Tests

Verify related `vitest` and `playwright` tests pass before concluding the task.
Some tests require infrastructure (testcontainers, Docker) that may not be
permitted in your sandbox — in that case, ask for approval to run outside the
sandbox rather than skipping.

Aggregate runners from the umbrella root:

- `pnpm test` — `pnpm --filter './packages/*' -r --if-present test` (excludes `integration-tests`).
- `pnpm vitest` — `pnpm --filter './packages/*' --filter '!@octostaff/devkit' -r exec vitest run`.
- `pnpm test:integration` — `pnpm --filter @octostaff/integration-tests test` (the 6 gating integration groups, sequentially; `query-cost` profiles rather than gates and is excluded).

Prefer scoped commands while iterating (e.g. `pnpm --filter @octostaff/sdk test`);
keep aggregates for pre-CI checks.

## Integration Tests (`integration-tests/`)

The root-level `integration-tests/` package is **not** under `packages/*` and is
excluded from `pnpm test`; run via `pnpm test:integration`. It's where
cross-package, real-dependency suites live — e.g. the claude-scuba bridge
emitting a wire shape that the sdk assembler folds and starfish renders.

It's split into **seven independent vitest/playwright projects**, each runnable on
its own. Six gate CI; `query-cost` is an on-demand profile:

| Group          | Command                                                        | What it covers                                                                                                                                              |
| -------------- | -------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `claude-scuba` | `pnpm --filter @octostaff/integration-tests test:claude-scuba` | Live + fake Claude Agent SDK round-trips (flaky → `--retry=1`).                                                                                             |
| `codex-scuba`  | `pnpm --filter @octostaff/integration-tests test:codex-scuba`  | Live + scripted-fake Codex CLI round-trips. Live cases run unconditionally and use the CLI's ambient authentication.                                        |
| `bubble`       | `pnpm --filter @octostaff/integration-tests test:bubble`       | Bubble server + sdk-client; Postgres schema upgrade/drift guard; boots Postgres via testcontainers.                                                         |
| `starfish`     | `pnpm --filter @octostaff/integration-tests test:starfish`     | Fixture events → assembler → starfish DOM, in-process (no browser).                                                                                         |
| `reef`         | `pnpm --filter @octostaff/integration-tests test:reef`         | reef ↔ real bubble ↔ A2A agent: deterministic JSON-RPC fake + live `docker agent serve a2a` (`itLive`).                                                     |
| `playwright`   | `pnpm --filter @octostaff/integration-tests test:playwright`   | Browser-driven visual + interaction regression against real servers.                                                                                        |
| `query-cost`   | `pnpm --filter @octostaff/integration-tests test:query-cost`   | **Reports, does not gate.** Profiles every Bubble API's store round trips / authz decisions / SQL statements at three scale factors on both store backends. |

The **`query-cost`** group is the odd one out and is deliberately excluded from
the aggregate `test` script, from `run_tests`, and from the release preflight. It
seeds a full bubble (threads, subthreads, grants, events, schedules, artifacts)
at ×1/×2/×4 and drives the whole API at each, twice over — so it is expensive,
and what it produces is a table for a human to read rather than a pass/fail.
Comparing an operation's cost across the three factors is what turns "is this
O(1) or O(n)?" into arithmetic. Its Postgres half is the half worth having: the
in-memory store answers `threads.list()` in one map pass while Postgres issues
`1 + 2N` queries, so a store-contract-level count alone would hide the largest
cost in the API. Reports land in `integration-tests/profile-report/`
(gitignored; stored as a CircleCI artifact). Run it via
`pnpm ci:circleci tests --module query-cost --yes` when query cost is the thing
you are working on.

The `reef` live case launches a real A2A agent with `docker agent serve a2a` and
needs the `docker agent` CLI plugin plus `OPENAI_BASE_URL` / `OPENAI_API_KEY`
(source `integration-tests/.env`; see `integration-tests/.env.example`). Without
them only the deterministic JSON-RPC case runs green; the live `itLive` case fails
loudly by design. CI gate: `run_reef`.

Vitest worker pool is capped at **4 max threads** (matches CI's `machine large`
4-vCPU box). Live-SDK tests on a fatter local box otherwise spawn enough
concurrent Anthropic sessions to push individual round-trips past the helper
deadline.

When adding an integration test:

1. **Resolve from built `dist/`, not source.** These suites import the public entrypoints (`@octostaff/sdk/assembler`, `@octostaff/claude-scuba`, `@octostaff/starfish/...`), which resolve to each package's `dist/`. After changing any consumed package, rebuild it first (`pnpm --filter @octostaff/<pkg> build`) — stale dist is the most common cause of confusing integration-test failures.
2. **Boot real infrastructure in-process.** Reuse the existing helpers under `integration-tests/src/helpers/` (`bubble-server.ts`, `claude-scuba-world.ts`, `store-backends.ts`, `test-db-container.ts`). Fake only what's outside the boundary — model APIs always use `MockLanguageModelV3` or a hand-crafted SDK stream.
3. **Live-SDK tests use `itLive` and must fail loudly.** `itLive` is currently `= it` (no credential gating) — a broken environment surfaces as a failure, not a false pass. Pair every live test with deterministic fake-SDK coverage of the same shape (e.g. `claude-scuba-native-parts.test.ts` alongside `claude-scuba-bot.test.ts`): fake proves the bridge logic, live proves the real SDK still emits that shape.
4. **Pick a trigger the SDK actually produces.** Probe live first; some signals require coaxing (e.g. a backgrounded `Bash` escalates through `canUseTool` — you must approve the gate — and keeps the run open, so poll the event stream rather than waiting for `run_finished`). Encode what the probe taught you in a comment.
5. **Never probe local credential or secret locations** to decide whether a live test can run. Just run the suite; it fails loudly if creds are unreachable.

## Bubble Postgres schema guard (`src/bubble/schema-*.test.ts`)

Bubble has **no migration system**: `PostgresBubbleStore.ensureSchema` only runs
`CREATE TABLE / CREATE INDEX … IF NOT EXISTS` on boot, never `ALTER`. So a new
server version starting against an older database silently auto-creates missing
tables/indexes but does **not** add new columns, change types, drop columns, or
add constraints — the old shape is kept and new code breaks at runtime. Two
suites in the bubble group guard this:

- **`schema-upgrade.test.ts`** — for every committed `fixtures/schema/NNN-*.sql` snapshot, seeds a throwaway schema at that old shape (plus legacy rows), boots the **current** server against it (triggering the live `ensureSchema` auto-update), and asserts legacy data survived and the full current surface works — including `consumer_cursors`, a table that exists only from snapshot 002 onward, so the 001 case proves a post-snapshot table is auto-created and functional. This is the guarantee that _any_ committed schema version upgrades cleanly to latest.
- **`schema-fingerprint.test.ts`** — boots the current server, introspects the live schema (columns/types/nullability/defaults/constraints/non-trigram indexes) into a normalized snapshot. **If it goes red, you changed the schema.** Classify the change before refreshing the snapshot: a new table/index auto-applies on old DBs (safe — re-baseline); a new column / type change / dropped column / new constraint does **not** (it breaks online serving — ship a real migration _and_ add a new `fixtures/schema/NNN-*.sql` so the upgrade suite proves old → latest, then re-baseline). Re-baseline with `pnpm exec vitest run --project bubble src/bubble/schema-fingerprint.test.ts -u` from `integration-tests/` (needs Docker, i.e. outside the sandbox). Review the generated `__snapshots__/schema-fingerprint.test.ts.snap` diff deliberately rather than trusting the auto-write.

The historical SQL snapshots are **frozen artifacts** — never edit an existing
`NNN-*.sql`; each schema change adds the next-numbered file. Both suites
`describe.skipIf(!INTEGRATION_TEST_DB_URL)`, so they skip (not fail) when Docker
is unavailable, like the rest of the Postgres-backed bubble cases.

## UI Automated Tests

The **automated** layers below live here. To manually _drive and screenshot_ a UI
change in a real browser — your own stack on 3100/3101, additive fixtures
seeding, master-key login, screenshot proof on the issue — use the
**`ui-verifier`** skill; that's the hand-driven half of this section.

Two complementary automated layers:

- **Automated in-process (default — always extend this):** `integration-tests/src/starfish-bubble-fixtures.test.ts` folds fixture events through the public assembler and asserts on the resulting message/part structure; component coverage with RTL in `starfish` (e.g. `bubble-data-parts.test.tsx`). No browser. When you add a new wire shape or renderer, extend both.
- **Automated browser-driven (Playwright group):** specs under `integration-tests/src/playwright/` run real Chromium against the fixtures bubble server + starfish dev server (booted by `webServer` in `playwright.config.ts`). Includes:
  - `fixture-threads.visual.spec.ts` — per-thread full-page screenshots against LFS-tracked baselines. **Snapshot pages must have a bounded height** (clamp container or scroll-and-stitch sections) — the thread-list sidebar grows with new fixtures and would otherwise invalidate every baseline on each fixtures edit.
  - `surfaces.visual.spec.ts` — settings, principals, preferences, login/logout shells. The thread-list sidebar baseline lives in `sidebar.visual.spec.ts` and is expected to churn on fixture updates — re-baseline deliberately, don't auto-update.
  - `interactions.spec.ts` — click-driven assertions on stable hooks (`[data-bubble-kind]`, `data-event-name`, `data-agent`, `li[data-status]`).

> Adding to `bubble.config.fixtures.json` (the baseline-safe default the
> `ui-verifier` skill now uses for setup) grows the sidebar/settings lists and the
> `interactions.spec.ts` / `fixtures-permissions-matrix.test.ts` matrices — so
> re-baseline `sidebar` / `surfaces` and update those matrices deliberately when
> you extend the fixtures. See **Visual baselines** below for the LFS re-baseline
> mechanics.

## Visual baselines: use Git LFS

Playwright `toHaveScreenshot()` baselines and any other binary test fixtures must
be tracked via **Git LFS**, not raw blobs.

- The umbrella's `integration-tests/.gitattributes` already routes `src/playwright/**/*-snapshots/*.png` through LFS — keep new visual baselines under that path.
- Run `git lfs install` once per clone. CI's playwright job runs `git lfs pull` after checkout; without it the PNGs land as 131-byte pointer files and every visual spec fails with a "size mismatch" diff.
- If baselines were committed as raw blobs by mistake, migrate with `git lfs migrate import --include="<path>"` and only force-push if the user explicitly approves rewriting history.
- Same rule applies to any other binary golden artifact (PDFs, screenshots, video, heap snapshots).

## Sandbox guardrails (do not work around)

- Running a Next dev server from a temp directory, overwriting a file from another worktree, and reading/writing `.env` files are blocked by design.
- When the user already has a dev server running, drive **their** stack (e.g. restart only the backend the fixtures live in) instead of standing up an isolated copy.
- Never `>`-redirect through a path that may be a symlink to a real config or `.env` — copy with `cp` and edit the in-place copy.
- If a guardrail blocks a verification step, stop and hand it to the user with the exact command rather than improvising around it.
