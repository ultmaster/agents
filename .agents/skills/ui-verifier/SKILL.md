---
name: ui-verifier
description: >-
  Use to verify an OctoStaff UI change end-to-end — first run the affected
  package's vitest/contract tests, then drive the real starfish UI against a
  bubble fixtures server with the Chrome DevTools MCP plugin to observe,
  screenshot, and prove the change. The stack lifecycle is scripted
  (scripts/launch.sh, teardown.sh, chrome-recover.sh, login-js.sh): your own
  isolated stack on ports 3100/3101 with a separate Next build dir (never the
  user's 3000/3001), master-key login by seeding localStorage, Chrome stale-lock
  recovery, exact-PID teardown, a Figma visual-parity check that reads the
  change's ui-design sketch frame against the runtime screenshot, and uploading
  screenshot proof to the issue tracker.
---

# UI Verifier

Verification is **runtime observation**: build it, run it, drive the UI to where
the changed code executes, capture what you see. A green test suite, a screenshot of
the feature working, and that screenshot matching the intended design are three
different claims — tests prove the logic, the screenshot proves the UI runs, and parity
with the sketch proves it's the *right* UI. This skill does all three, in order.

Use it when a change touches the starfish UI (or a bubble API the UI renders) and
the task asks you to verify a fix, confirm a feature, or attach UI proof to an
issue. For pure logic/test-only changes, the **`test`** skill is enough.

Pairs with **`test`** (testing philosophy + the automated UI layers — in-process
assembler tests and the Playwright visual/interaction suites) and
**`issue-tracker`** (uploading the screenshot as proof). It's the verify half of the
**[design]** loop — its parity step (§5) compares the built UI against the sketch that
skill produced. This skill is the manual, Chrome-DevTools-driven half.

The browser-stack lifecycle is **scripted** — run the scripts rather than
hand-rolling the bash, because every flag in them is a failure someone hit by
hand (the Next dev-lock collision, killing the user's server, a chunky teardown
that left orphans). They live in `scripts/` next to this file:

| Script | Does |
| --- | --- |
| `scripts/launch.sh [--foreground] [bubble-script]` | Launch an isolated bubble+starfish fixtures stack, wait until both answer, and record state for teardown. Use `--foreground` to remain attached. |
| `scripts/teardown.sh` | Kill exactly the stack `launch.sh` recorded (and nothing else), re-probe until the ports are free. |
| `scripts/chrome-recover.sh` | Clear a stale Chrome holding the DevTools-MCP profile lock. |
| `scripts/login-js.sh <principalId> [token]` | Print the master-key `localStorage` snippet to paste into `evaluate_script`. |

## Codex execution

Run all host-dependent verifier operations outside the sandbox with escalated
execution. Start `scripts/launch.sh --foreground` in a long-lived command
session; continue once it prints `stack ready`, and let `teardown.sh` release the
session. Also run `teardown.sh`, `chrome-recover.sh`, and direct `ss` or localhost
`curl` probes outside the sandbox. Sandboxed runs can fail with `listen EPERM`,
cannot inspect the host netlink socket, and cannot manage the automation browser.
These rules apply to every corresponding command later in this skill.

## Run the automated tests first

Scoped, before touching the browser — fast, and catches the regression at the
layer it lives in.

- bubble change: `pnpm --filter @octostaff/bubble exec vitest run` (boots a real
  Postgres testcontainer for the store-contract suite when Docker is up — the
  strongest layer; real SQL, not just the in-memory store).
- starfish change: `pnpm --filter @octostaff/starfish exec vitest run` (RTL).
- Add a regression test in the same change. For store/route behavior, prefer the
  shared store-contract (`packages/bubble/src/store/store-contract.ts`, runs
  against memory **and** Postgres) plus a server-route test over `app.inject`.

Then `pnpm --filter <pkg> lint` and `pnpm --filter <pkg> exec tsc --noEmit` (what
CI runs). Only after that is green do you drive the UI — and tests passing is
**not** a substitute for the screenshot a UI issue asks for.

For the automated UI layers (in-process assembler tests, the Playwright visual +
interaction suites, and how to re-baseline LFS snapshots), see [the `test`
skill][test].

## Drive and screenshot the real UI

### 1. Launch your own stack

```bash
.agents/skills/ui-verifier/scripts/launch.sh
```

It launches **bubble → `127.0.0.1:3100`** and **starfish → `127.0.0.1:3101`**
against the fixtures config, blocks until both answer, and writes a state file
for teardown. It is safe to run **while the user's own `pnpm dev:app` is up** —
that is the normal case, and the reason the script (not a bare `pnpm dev:app`)
exists. Three things it gets right that a hand-rolled launch does not:

- **Isolated Next build dir (`NEXT_DIST_DIR=.next-verify`).** The Next dev lock
  lives at `packages/starfish/.next/dev/lock` and is shared by *every* `next dev`
  against that build dir — **per-project, not per-port**. So a developer's
  `next dev` on 3001 makes a naive `:3101` start fail with `Unable to acquire
  lock` even though 3100/3101 were free. A separate build dir
  (`.next-verify`, git- and eslint-ignored) gives our stack its own lock. The
  script fails fast and prints the log if a lock collision ever still happens.
- **Never 3000/3001.** Those are the user's. Defaults are 3100/3101; if that pair
  is taken by something it can't claim, it advances (3200/3201, …). Override with
  `BUBBLE_PORT=… STARFISH_PORT=… launch.sh` (explicit ports are honoured or it
  errors — no silent drift). It refuses 3000/3001 outright.
- **Records the launcher PID + ports** so `teardown.sh` kills exactly this stack
  — never a `ps | grep fixtures` match that could be the user's identical command.

**Why fixtures, not the default `dev`:** the fixtures config
(`packages/bubble/bubble.config.fixtures.json`) enables the **master-key** auth
driver (`masterKey: "dev"`), so you can log in as any principal and act as `root`
non-interactively. The default `dev` config is `local-token` + **auth0** — no
master key, no non-interactive login. Always verify against fixtures. (Pass a
different bubble script as `launch.sh`'s first arg if you ever need one.)

### 2. Set up test state — **additively edit `bubble.config.fixtures.json`** (default)

The default way to give a verification the threads/principals/grants it needs is
to **append** them to the seed in `packages/bubble/bubble.config.fixtures.json`,
then re-run `launch.sh` (after `teardown.sh`) so the in-memory store re-seeds. The
seed is the canonical fixture corpus — extending it is how UI coverage grows
([the `test` skill][test] treats fixtures as the layer you always extend).

The three seed lists and the fields each accepts:

| `seed.` list | Shape (one entry) | Notes |
| --- | --- | --- |
| `principals[]` | `{ principalId, kind: "user"\|"bot"\|"system", displayName?, email?, avatarUrl?, discoverable?, openToInvites?, initialToken? }` | bot default is `discoverable:false` + `openToInvites:false`; set **`discoverable: true`** to make a bot appear in everyone's principal search. `initialToken` is bots-only. |
| `authz[]` (grants) | `{ target, principalId, role }` | `target` is `{type:"system"}` \| `{type:"thread",threadId}` \| `{type:"principal",principalId}`. `role` ∈ `owner` `member` `commenter` `approver` `tool_runner`. This is the only way to bootstrap who-can-see-what. |
| `threads[]` | `{ threadId, parentThreadId?, title?, events[] }` | `events[]` is the raw bubble event log (a thread's participants come from its `authz` grants, not a field here). Copy an existing thread's event shape. |

**Append, don't mutate.** Adding to the seed grows the sidebar and the
settings/principals & settings/bots lists, so those visual baselines
(`sidebar.visual.spec.ts`, `surfaces.visual.spec.ts`) and the hardcoded matrices
(`fixtures-permissions-matrix.test.ts`'s `EXPECTED_MEMBERSHIP`,
`interactions.spec.ts`'s participant counts) may need a **deliberate
re-baseline** — see [the `test` skill][test] for the mechanics. Per-thread page
snapshots are height-clamped, so a *new* thread adds a new baseline without
churning existing ones. If the addition is meant to stay, run
`pnpm --filter @octostaff/bubble exec prettier --write bubble.config.fixtures.json`
before committing; if it was a one-off, revert the edit when you're done.

### 3. Talk to the bubble server directly — for probing or complex scenarios

Prefer editing the seed (§2). But the master-key API is there when you need to
**probe** what's actually seeded, or to set up state the JSON can't express — a
runtime-only field (a bot's `disabledAt`), or a live **before/after** where one
variable flips between two screenshots. Authenticate as any seeded principal with
two headers: the master-key bearer, plus `x-bubble-principal-id` for who you're
acting as (use `root` to mutate anything, or a real user to see what the UI sees).

```bash
# probe: what does user-ada's principal search return? `agent-octo` is
# discoverable:false, so searching it as a normal user yields [] — the probe
# proves the discoverability rule, not just the happy path.
curl -s 'http://127.0.0.1:3100/v1/principals?q=octo' \
  -H 'Authorization: Bearer dev' -H 'x-bubble-principal-id: user-ada'

# verify a thread's participants + roles after a UI action (e.g. an invite) —
# GET /v1/threads/<id> returns participants[], each with role. Prefer this over
# GET /v1/grants, which 400s unless you pass exactly one of
# targetType(+targetId) / principalId / all=true.
curl -s 'http://127.0.0.1:3100/v1/threads/thread-roles' \
  -H 'Authorization: Bearer dev' -H 'x-bubble-principal-id: root'

# mutate (act as root): disable a bot — runtime-only, no disabledAt in the seed
curl -s -X PATCH http://127.0.0.1:3100/v1/principals/agent-octo \
  -H 'Authorization: Bearer dev' -H 'x-bubble-principal-id: root' \
  -H 'content-type: application/json' -d '{"disabledAt":"2026-01-01T00:00:00.000Z"}'
```

Runtime writes live only in the in-memory store and vanish when bubble stops —
nothing to clean up server-side, and they never touch committed fixtures or
baselines. (The same `Bearer dev` + principal-header pair is what §4 seeds into
`localStorage` to log the browser in.)

### 4. Drive the browser with the Chrome DevTools MCP plugin

Log in by seeding the master-key session into `localStorage`, then reload.
`scripts/login-js.sh <principalId>` prints the exact snippet (it matches
`saveBubbleAuthSession` in `packages/starfish/src/lib/auth/session.ts`):

```
mcp …__new_page        url=http://localhost:3101
mcp …__evaluate_script function=<paste output of `scripts/login-js.sh user-ada`>
mcp …__navigate_page   type=reload          # apply the seeded session
mcp …__take_snapshot                         # a11y tree → element uids
```

Then drive to the change and capture:

- `take_snapshot` (a11y tree, gives `uid`s) — prefer over screenshots for
  *finding* elements; it tells you the button/dialog labels to act on.
- `click` / `fill` / `fill_form` by `uid`. Re-trigger a debounced search by
  **changing** the field value (fill `claud` then `claude`) — re-filling the same
  value may not fire the input handler.
- `wait_for` — **`text` must be an ARRAY**: `text=["Claude Code Local"]`, not a
  bare string (a string is a validation error). Resolves when any listed text appears.
- `take_screenshot filePath=/tmp/iss<N>-<state>.png` — then **`Read` the PNG**. A
  saved screenshot proves nothing until you've looked at it.

If a Chrome MCP call fails with **"browser is already running … chrome-profile"**,
a stale automation Chrome holds the profile lock — run
`scripts/chrome-recover.sh` (it kills only the MCP profile, never the user's
browser), then retry the call.

### 5. Compare against the Figma design (visual parity)

The runtime screenshot proves the UI *runs*; comparing it to the design proves it's the
*right* UI. If the change went through the **[design]** skill it has a sketch frame on
the **UI Design** page of the Starfish Product Design file (`X7EUKdvekmvAlHjOJ4foFV`,
page `250:10`,
`https://www.figma.com/design/X7EUKdvekmvAlHjOJ4foFV/Starfish-Product-Design?node-id=250-10`).
Pull that frame and read it against your `/tmp/iss<N>-*.png`:

```
mcp …figma__get_screenshot   fileKey=X7EUKdvekmvAlHjOJ4foFV nodeId=<sketch frame id>
# → Read both PNGs; compare deliberately
```

Compare, don't glance — check what a design actually encodes: component choice, layout
and alignment, spacing rhythm, type hierarchy, color **tokens** (light *and* dark if the
change touches theming), and every state the sketch shows. Call out divergences
explicitly; an implementation that drifts from the approved design is a real finding,
not a rounding error. If the build and the sketch genuinely disagree because the design
got something wrong, say so and reconcile with the user — don't silently follow either.

**No sketch?** A change small enough to have skipped design's sketch step still has a
reference: compare against the component's **Component Families** entry or the relevant
**As-built** frame in the same file, to confirm you matched the established pattern.
Start from the file-local **Component Families** page (`10:5`) with Figma metadata,
locate the component node, then capture that node. Design-system search may return no
results for components that exist only in this file and are not published to a library.
If there is truly no Figma reference (a brand-new throwaway surface), note that and lean
on the runtime screenshot alone.

### 6. Upload the proof to the issue

Via the **`issue-tracker`** skill; a screenshot is mandatory for any UI issue:

```bash
pnpm issue-tracker comment <N> --body-file proof.md \
  --image /tmp/iss<N>-before.png --image /tmp/iss<N>-after.png \
  --sign "Claude Code Opus 4.8" --yes
pnpm issue-tracker status <N> --set resolved --yes     # suggest; humans close
```

### 7. Tear down what you started

**As soon as the screenshots are captured** — a stack left running is the orphan
that squats on the ports and costs the *next* run a detour. Don't defer it behind
follow-up work.

```bash
.agents/skills/ui-verifier/scripts/teardown.sh
```

It reads the state file from `launch.sh`, kills the recorded launcher tree **and**
whatever now listens on the recorded ports (survivors reparent off the launcher,
so killing the root `pnpm dev:app` alone does **not** cascade), then re-probes
until both ports are free — a `kill` returning 0 is not proof the port is free.
It refuses to act on 3000/3001 no matter what the state file says. If you appended
to `bubble.config.fixtures.json` for a one-off check, revert it now.

If you ever need to tear down by hand (no state file), find the real listeners by
PID — `ss -ltnp | grep -E ':3100|:3101'` — and kill those plus the
`tsup … --watch` supervisor that respawns the bubble cli. **Never** broad-match
(`pkill -f next-server` / `pkill -f starfish` / `pkill -f fixtures`): those match
the user's processes too, and broad pattern kills are denied.

## Gotchas (hard-won)

- **The `fixtures` config name does NOT prove ownership.** The user runs their own
  `pnpm dev:app dev:fixtures`. A real incident: a `node ./dist/cli.js --config
  ./bubble.config.fixtures.json` on `:3000` was assumed stale and killed — it was
  the user's server. Ownership comes from the `launch.sh` state file (recorded
  ports + PID), nothing else. Ports 3000/3001 are always off-limits.
- **`wait_for` `text` is an array**, not a string — a bare string is a validation error.
- **A screenshot isn't proof until you `Read` it.** Looking is the verification;
  saving the PNG is not.
- **Don't claim a UI fix is verified from tests alone.** Tests are necessary; the
  rendered result is the proof a UI issue asks for.
- **Run `pnpm lint` / `tsc` *after* teardown, not during.** A live Next dev server
  starves the checks of CPU, so a normally-60s `eslint .` can crawl for minutes
  and look hung. `.next-verify` is eslint-ignored, so it won't be walked — but if
  a lint inexplicably hangs, check for a stray un-ignored build dir before
  assuming a real problem.

[test]: ../test/SKILL.md
[design]: ../ui-design/SKILL.md
