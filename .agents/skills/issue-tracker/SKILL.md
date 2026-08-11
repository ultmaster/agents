---
name: issue-tracker
description: Use to track OctoStaff work through GitHub Issues — bug fixes, feature planning, architecture refactors, and the like. List issues in any repo (umbrella default; reef, claude-scuba, bubble, starfish, sdk, etc.), read one issue with its body, every comment, and its image attachments cached locally so they can be viewed, post progress comments with optional uploaded images (link commits), tag an issue's status with a label (investigating, resolved, …), and tag which module(s) it concerns (bubble, reef, starfish, …). Drive everything through `pnpm issue-tracker`.
---

# Issue Tracker

GitHub Issues is the centralized place for tracking OctoStaff work — bug fixes,
feature planning, architecture refactors, and anything else worth a durable
shared record. Canonical code lives in the
`octostaff/umbrella` monorepo, but each package still has its own standalone
`octostaff/<repo>` (now a downstream mirror) with its own issue tracker. This
skill makes the tracker readable and writable from the CLI: list, read (with
attached images), create new issues, comment (including image uploads), tag
status, and tag which module(s) an issue concerns.

Drive everything through the **`pnpm issue-tracker`** shortcut (defined in the
root `package.json`). It wraps `gh` with repo-alias resolution, image
download/upload, `--dry-run`, and `--yes` gating, and forwards every argument
straight to the helper script:

```bash
pnpm issue-tracker <command> [options]            # run from the umbrella root
```

Always invoke it this way. In Codex, run **every** `pnpm issue-tracker`
invocation outside the sandbox (request escalated execution up front), including
read-only commands: the wrapper invokes `gh`, and the sandbox cannot access the
host's GitHub authentication or network. An approved command prefix does not
change that requirement. Do not call `issue-tracker.sh` directly. The script's
own `--yes` flag remains the gate on every write.

## Repo selection

`--repo <alias|owner/repo>` on any command. **Default: `umbrella`.**

| Alias                                                              | Repo                          |
| ----------------------------------------------------------------- | ----------------------------- |
| `umbrella` *(default)*                                             | `octostaff/umbrella`          |
| `reef` `claude-scuba` `codex-scuba` `bubble` `starfish` `octopus` `sponge` `office` `tui` | `octostaff/<alias>` |
| `sdk`                                                              | `octostaff/sdk-typescript`    |
| `devkit`                                                           | `octostaff/devkit-typescript` |

Any other bare value resolves to `octostaff/<value>`; a value containing `/` is
used verbatim as `owner/repo`. `pnpm issue-tracker repos` prints this table.

## Commands

### Read-only

```bash
pnpm issue-tracker list                                  # open umbrella issues
pnpm issue-tracker list --repo reef --state all          # state: open|closed|all (default open)
pnpm issue-tracker list --label bug --search "scuba" --assignee @me --limit 50
pnpm issue-tracker view 8                                # #8: body + comments + images
pnpm issue-tracker view 12 --repo starfish --dir /tmp/iss   # cache to a chosen dir
pnpm issue-tracker view 8 --no-images                    # skip the download
pnpm issue-tracker labels --repo reef                    # list a repo's labels
```

`view` renders the issue title, state, author, assignees, labels, milestone,
URL, full body, and every comment. It then scrapes image URLs from the body and
all comments (`user-attachments/assets/…`, `user-images.githubusercontent.com`,
and `.png/.jpg/.gif/.webp/.svg` links), downloads each with the `gh` token
(private-repo attachments work — curl drops the auth header on the cross-host
CDN redirect), names them by content-type, and prints the local paths. **Read
those files to actually see the screenshots.**

Everything is cached under **`<skill-root>/issue-tracker/cache/<issue>/`** (the
`cache/` dir is gitignored): `issue.json` (raw), `issue.md` (the rendered text),
and `issue-<n>-NN.<ext>` images. `view` always re-fetches and overwrites the
cache, so it reflects the issue's current state; stale attachments from a prior
view are cleared first. Pass `--dir` to cache somewhere else. Note the cache is
keyed by issue number only — viewing the same number in two repos overwrites,
and the latest `view` wins.

### Writes (require `--yes`; `--dry-run` previews the exact `gh` calls)

```bash
# Open a new issue. --module / --status tag it in the same shot (labels created
# if missing); --label attaches arbitrary labels; --image uploads screenshots.
# Like comment, the issue body is SIGNED with who filed it (required).
pnpm issue-tracker create --title "Bug: thread title flickers" --body-file report.md \
  --module starfish --status triage --sign "Claude Code Opus 4.8" --yes
pnpm issue-tracker create --repo bubble --title "Feature: presence TTL" \
  --body "…" --label enhancement --assignee @me --yes   # signature from ISSUE_TRACKER_SIGNATURE
pnpm issue-tracker create --title "Crash on reconnect" --body-file repro.md --image stack.png --yes

# Post a progress comment — link the commit that addresses the issue.
# Every comment is SIGNED with who posted it (required): pass --sign, or set
# ISSUE_TRACKER_SIGNATURE in the environment / the skill's .env.
pnpm issue-tracker comment 8 --body "Fixed in octostaff/bubble@abc1234; deploying." --sign "Claude Code Opus 4.8" --yes
pnpm issue-tracker comment 8 --body-file notes.md --repo bubble --yes      # signature from ISSUE_TRACKER_SIGNATURE
pnpm issue-tracker comment 8 --body-file proof.md --image screenshot.png --yes
pnpm issue-tracker comment 8 --image before.png --image after.png --yes

# Tag status. Replaces any existing canonical status label with the new one,
# creating the label (with a sensible color) if missing.
pnpm issue-tracker status 8 --set investigating --yes
pnpm issue-tracker status 8 --set resolved --yes              # agents: suggest "fixed" — humans close
pnpm issue-tracker status 8 --set resolved --close --yes      # --close is human-only (don't use as an agent)
pnpm issue-tracker status 8 --set in-progress --reopen --yes  # --reopen is human-only too

# Tag which module(s) the issue concerns (additive — an issue may span several).
pnpm issue-tracker module 8 --set bubble,starfish --yes   # replace the module set
pnpm issue-tracker module 8 --add reef --yes              # add one
pnpm issue-tracker module 8 --remove office --yes         # drop one
```

#### Image uploads

GitHub's public issue-comment APIs create markdown comments; they do not expose a
normal binary attachment upload endpoint. For screenshots/proof images, the
helper uses the `gh-image` GitHub CLI extension, which mirrors GitHub's web
attachment upload flow and returns markdown like
`![name](https://github.com/user-attachments/assets/...)`.

Install it once:

```bash
gh extension install drogers0/gh-image
```

Then pass one or more repeatable `--image <file>` flags to `comment`. The helper
uploads every image first, then posts one combined issue comment. Image-only
comments are allowed. If an upload fails, the comment is not posted.

**Placing images inline.** Reference an image in the body with the **same path you
pass to `--image`** (or just its basename) and the helper rewrites that reference
to the uploaded URL *in place* — so the screenshot lands exactly where you wrote
it, not dumped at the end. Any `--image` you *don't* reference inline is appended
after the body (the plain "just attach these" flow). Don't hand-write
`user-attachments/assets/...` URLs — you can't know them until the upload runs;
point at the local file and let the helper wire it up.

```bash
# Inline: the ![...](/tmp/*.png) refs resolve to the uploaded URLs in place.
cat > /tmp/proof.md <<'EOF'
Before: ![before](/tmp/before.png)
After:  ![after](/tmp/after.png)
EOF
pnpm issue-tracker comment 8 --body-file /tmp/proof.md \
  --image /tmp/before.png --image /tmp/after.png --sign "Claude Code Opus 4.8" --yes

# Appended: no inline refs, so both images are added after the body.
pnpm issue-tracker comment 8 --body "Proof after octostaff/umbrella@abc1234." --image /tmp/proof.png --yes
```

`gh-image` requires write access to the target repo plus a GitHub *web session*
token. By default it extracts that from a local browser session — which works on
a normal desktop. Where browser extraction can't work (notably **WSL**, where
gh-image's keyring backend is kwallet-bound and fails with `kwallet: password
not found`), use the **`.env` fallback**: copy `.env.example` to `.env` in the
skill root and set `GH_SESSION_TOKEN` to your github.com `user_session` cookie
value (step-by-step instructions are in `.env.example`). The helper consults
`.env` only after tokenless extraction fails, so the browser path stays primary
and `.env` is gitignored. Do not pass session tokens as command arguments or
include them in issue comments.

Before relying on uploads, run the built-in setup check:

```bash
pnpm issue-tracker doctor            # verifies gh auth, gh-image, token resolution
pnpm issue-tracker doctor --live --yes   # also does one real throwaway upload
```

`doctor` is read-only by default and reports which token path resolved (browser
session, exported `GH_SESSION_TOKEN`, or the `.env` fallback). `--live` performs
a genuine end-to-end upload — gated behind `--yes` because gh-image has no delete
API, so it leaves a tiny unreferenced image on GitHub's CDN.

#### Signing comments

Every comment posted through `comment` is signed with who posted it, so issue
threads stay attributable to the agent (or person) behind them. A footer like
`_— posted by Claude Code Opus 4.8 (via the issue-tracker skill)_` is appended
automatically. The signature resolves in priority order: the `--sign "<who>"`
flag, then `ISSUE_TRACKER_SIGNATURE` in the environment, then the same variable
in the skill's `.env`. Posting with no signature configured is **refused** — set
`ISSUE_TRACKER_SIGNATURE` once in `.env` (see `.env.example`) to avoid passing
`--sign` every time. As an agent, sign with your own identity (e.g. your model
name); don't impersonate a human.

#### Status vocabulary

`status --set <name>` manages a single status label per issue — the label is the
bare name (e.g. `investigating`, `resolved`), no `status:` prefix. Canonical
names (each gets a fixed color; others are accepted with a default color):

`triage` · `investigating` · `in-progress` · `blocked` · `needs-info` ·
`resolved` · `wontfix` · `duplicate`

A leading `status:` is stripped if you happen to type it. `--close` / `--reopen`
change the issue's open/closed state in the same call (mutually exclusive) — these
are **human-only**; as an agent, set the `resolved` label and leave closing to a
human (see Operating rules). Setting a new status removes whatever *canonical*
status label was there before,
so an issue carries at most one of them at a time. The label is created only if
absent — existing labels (e.g. GitHub's built-in `wontfix`/`duplicate`) keep
their color and description.

#### Module vocabulary

`module` tags which part of the system an issue concerns, with **bare** labels
(no prefix), all sharing one color so they cluster in the label list. Unlike
status, modules are **additive** — an issue may carry several. Canonical names
(any other is accepted too):

`bubble` · `claude-scuba` · `codex-scuba` · `reef` · `starfish` · `sdk` ·
`devkit` · `octopus` · `sponge` · `office` · `tui` · `ci` · `deploy` · `docs` ·
`infra`

- `--set <m,…>` replaces the issue's module set (drops other *canonical* module
  labels, adds the listed ones).
- `--add <m,…>` / `--remove <m,…>` adjust incrementally.
- Values are comma/space lists and the flags repeat: `--add reef --add "sdk, ci"`.
- Labels are created only if absent. `--set` is mutually exclusive with
  `--add`/`--remove`.

## Working an issue — intended workflow

GitHub Issues is the team's durable, shared todo list. Treat an open issue as a
task you drive end-to-end, and keep the tracker as the record of what happened.
The lifecycle, using the commands above:

1. **Pick it up and read it fully.** `view <n>` to get the body, every comment,
   and the cached images — then **open the image files**. A UI bug's repro is
   usually a screenshot, and you can't fix what you haven't actually looked at.

2. **Label it if it isn't already.** Every issue should carry exactly **one
   status** and the **module(s)** it concerns — that's what makes
   `list --label <module>` / `list --label <status>` a usable board. If the issue
   is unlabelled, set both before you start:

   ```bash
   pnpm issue-tracker status 8 --set investigating --yes
   pnpm issue-tracker module 8 --set bubble,starfish --yes
   ```

   Use the helper (not hand-added labels) so the vocabulary stays consistent.

3. **Diagnose and reproduce before you fix.** Don't jump straight to a patch.
   First confirm the issue is real and understand its root cause — reproduce it
   locally (drive the app, run the failing test, follow the repro steps), and
   establish *why* it happens, not just *that* it happens. **Post evidence of that
   diagnostic work** as a comment: the reproduction (command + output, a failing
   test, a screenshot of the broken state), and your root-cause finding. A fix
   landed without a confirmed repro is a guess on the record.

   ```bash
   pnpm issue-tracker comment 8 --body-file repro.md --image broken-state.png --sign "<your-identity>" --yes
   ```

   **If the issue turns out to be a mix of several distinct problems**, stop and
   **ask the user** how to proceed — two options:

   - **Split it.** Create isolated issues to track each problem separately, keep
     *this* issue focused on the core one (retitle it to match that narrowed
     scope), and cross-link the new issues in a comment.
   - **Hunt them all down here.** Keep the single issue and resolve every problem
     in one body of work.

   Don't silently pick one — surface the breakdown and let the user choose.

4. **Discuss complex issues in the open.** For anything non-trivial — unclear root
   cause, several viable fixes, cross-package impact — post your analysis and plan
   as a comment *before or while* you code, so the reasoning is on the record and
   others can weigh in. Bump the status to `in-progress` once you start the fix.

   ```bash
   pnpm issue-tracker comment 8 --body-file analysis.md --sign "<your-identity>" --yes
   pnpm issue-tracker status 8 --set in-progress --yes
   ```

5. **Link the commit on every progress update or resolution.** When you push a fix
   or a meaningful step, comment with the commit reference `owner/repo@sha` — use
   **umbrella** commits, since code is fixed in the monorepo regardless of which
   tracker the issue lives on. Never report progress without the commit id backing it.

   ```bash
   pnpm issue-tracker comment 8 --body "Fixed in octostaff/umbrella@abc1234." --sign "<your-identity>" --yes
   ```

6. **Post proof, then mark `resolved` — but never close.** Attach evidence the fix
   works — test output, logs, or a before/after. **For any UI issue a screenshot is
   mandatory**: drive the real app and capture the rendered result — the
   **`ui-verifier`** skill is the end-to-end path for that (its own fixtures stack,
   master-key login, screenshot) — then put the image in a comment with `--image`.
   **For a non-UI issue (backend logic, API, tooling, infra) a screenshot is not
   required** — the right proof is test output, logs, or a repro transcript; don't
   stand up the UI just to manufacture an image. Match the evidence to where the
   bug lives. Then set the `resolved` label to **suggest** the issue is fixed —
   **do not pass `--close`** (see the closing rule below):

   ```bash
   pnpm issue-tracker comment 8 --body-file proof.md --image screenshot.png --sign "<your-identity>" --yes
   pnpm issue-tracker status 8 --set resolved --yes
   ```

   A human reviews the `resolved` issue and closes it.

## The comment thread is your working memory

For long-running work, the issue's comment thread is where context survives. As you
go, post comments that capture progress — what you tried, what worked, what broke, the
dead ends, and the lessons learned along the way. A task that spans many sessions (or
many agents) outlives any one context window; the comment thread is what's left. Write
to it so the next person — or the next you — can pick up where you left off without
relearning what you already paid for.

Then **use it**: before diving into a long task, `view <n>` and read back through its
comments to recover the context and benefit from the lessons already banked there.

## Operating rules

- **Only humans close issues; agents only *suggest* resolution.** When you believe
  an issue is fixed, set the `resolved` status label (`status <n> --set resolved`)
  and post your proof — that's how an agent signals "done". **Never close (or
  reopen) an issue yourself:** don't pass `--close`/`--reopen`, and don't
  `gh issue close` out of band. A human reads the `resolved` issue, verifies, and
  closes it. The `--close`/`--reopen` flags exist for human operators of this
  helper, not for agents.
- **Issue #1 (`Testing Issue`, umbrella) is the scratch issue for exercising this
  skill.** Use it to dry-run or live-test commands (comment, status, module, view)
  without disturbing real work — e.g. `pnpm issue-tracker comment 1 --body "…" --yes`.
  Clean up test artifacts you leave on it, and never point real work at it.
- **Never hard-wrap issue or comment text.** Write each paragraph as one long
  line and let GitHub wrap it. Manually breaking lines to hit a column width —
  the habit that keeps source files tidy — renders badly on GitHub: the wrapped
  fragments collide with its own wrapping, and inside list items and tables the
  breaks split the markdown outright. This applies to every body you author,
  whether passed with `--body` or written to a `--body-file`. Hard line breaks
  are fine only where they're semantic: between paragraphs, between list items,
  and inside fenced code blocks.
- **Reads are free; writes are outward.** `list`, `view`, `labels`, `repos`, and
  any `--dry-run` never mutate. `comment`, `status`, and `module` require `--yes`
  — and they post to a shared tracker other people read, so confirm intent first.
- **Default repo is `umbrella`.** Pass `--repo` for a package's own (mirror) tracker.
  A bug that spans packages usually belongs on `umbrella` — and since code is fixed
  in the umbrella monorepo, reference umbrella commits regardless of which tracker
  the issue lives on.
- **Diagnose before you fix.** Confirm/reproduce the issue and find its root
  cause before patching, and post the evidence (repro + finding). If the issue is
  really several distinct problems, ask the user whether to split them into
  isolated issues (narrowing this one to the core problem, retitling it) or hunt
  them all in one body of work — don't decide silently.
- **Link commits in comments.** Reference `owner/repo@sha` (or a PR/commit URL)
  so the tracker ties progress to code.
- **One status, many modules.** `status --set` keeps a single status label per
  issue; `module` is additive. Tag both so `list --label <module>` and
  `list --label <status>` slice the backlog. Use the helpers rather than
  hand-adding labels, so the vocabulary stays consistent.
- Auth: the helper requires `gh auth status` for github.com (`repo` scope — read
  for list/view, write for comment/status). For automation, set `GH_TOKEN`.
- `view` caches to `cache/<issue>/` (gitignored). It's a working cache, safe to
  delete anytime; a fresh `view` rebuilds it.
