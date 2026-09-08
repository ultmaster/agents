---
name: github-issues
description: Track work in GitHub Issues across arbitrary repositories. Use whenever an agent needs to list or read issues, inspect a complete issue thread and its attached images, create an issue, post signed diagnostic/progress/proof comments, manage status or area labels, archive inactive terminal issues, or resume work from an issue. Uses upstream-first repository discovery with an explicit --repo override, local attachment caching, dry-run previews, and --yes-gated writes.
---

# GitHub Issues

Use the bundled helper instead of assembling ad hoc `gh` commands. Resolve its
absolute path from this skill directory once per shell:

```bash
TRACKER="<skill-root>/scripts/issue-tracker.sh"
"$TRACKER" <command> [options]
```

In a sandboxed agent harness, request outside-sandbox/host execution before
every helper call that reads GitHub: the helper needs the host's `gh`
authentication and network access. Most `--dry-run` calls stay local; `archive
--dry-run` reads issue metadata to produce its candidate list. `help` is always
local. Escalation only provides access; writes still require user intent and
`--yes`.

Prefer the repository's own issue skill when it has one: a project that
documents its label scheme, status vocabulary, or tracker conventions in its own
skill knows things this one cannot.

## Repository selection

Pass `--repo owner/repo` (or `host/owner/repo`) when the tracker is known or is
different from the current checkout. Without it, discovery uses:

1. the local `upstream` remote;
2. the current branch's remote;
3. `origin`;
4. a single unambiguous remaining remote;
5. the current `gh` repository context.

This order prevents a personal fork from silently winning when an upstream
remote exists. Ambiguous or non-GitHub remotes are refused. Run `"$TRACKER"
repo` before a write when repository identity is not obvious; use `--repo` to
override deliberately. Upstream-first discovery is a default, not authorization
to write to that tracker. When multiple repositories could own the issue, verify
the target from the task or issue reference before writing; if it remains
ambiguous, ask. Do not infer an issue target from a pull request target or from
which remote is writable.

## Commands

Read-only commands:

```bash
"$TRACKER" repo
"$TRACKER" list --state open --label bug --limit 50
"$TRACKER" view 42
"$TRACKER" view 42 --repo owner/project --dir /tmp/issue-42
"$TRACKER" labels
```

`view` prints the body and every comment, then caches `issue.json`, `issue.md`,
and downloaded attachments under `cache/<host>/<owner>/<repo>/<issue>/` unless
`--dir` is given. The host is always explicit (`github.com` for ordinary
`owner/repo` inputs), keeping repositories on different GitHub hosts distinct.
Repository path components are lowercased because GitHub identity is
case-insensitive. Open every cached image needed to understand the report;
printing the paths is not equivalent to inspecting them.

Both the cache and `.env` live in the repository's own profile directory when it
has one — the first of `$ISSUE_TRACKER_PROFILE_DIR`,
`<repository-root>/.agents/skills/github-issues`,
`<repository-root>/.claude/skills/github-issues`, then this skill's root — so one
project's credentials and cached attachments never reach another. A repository
that carries a profile owns its settings outright; this skill's `.env` is not
consulted as a fallback there. `$ISSUE_TRACKER_ENV_FILE` overrides the file
directly. The helper never creates a profile directory.

Writes require `--yes`; use `--dry-run` first when the target or effect merits
review:

```bash
"$TRACKER" create --title "Bug: reconnect fails" --body-file report.md \
  --area api --status triage --sign "<your agent identity>" --dry-run
"$TRACKER" comment 42 --body-file diagnosis.md --image broken.png \
  --sign "<your agent identity>" --yes
"$TRACKER" status 42 --set in-progress --yes
"$TRACKER" area 42 --set api,frontend --yes
"$TRACKER" area 42 --add docs --yes
"$TRACKER" archive --inactive-for 90d --dry-run
"$TRACKER" archive --inactive-for 90d --yes
```

`create` and `comment` require attribution. Pass `--sign` or configure
`ISSUE_TRACKER_SIGNATURE` in the skill's gitignored `.env`; identify the actual
agent and never impersonate a human. Comments receive an attribution footer.

Areas default to labels such as `area:api`. Configure the prefix, color, and
bare-label vocabulary in `.env` for repositories with an established label
scheme. Status uses one managed status at a time; areas are additive. Missing
labels are created without overwriting existing label metadata.

`archive` is the only command that closes issues. It considers open issues with
the canonical `resolved` or `tracked-elsewhere` status and compares GitHub's
`updatedAt` timestamp with the required `--inactive-for` age. Accept values such
as `24h`, `30d`, `12w`, `6mo`, or `1y`; months are fixed at 30 days and years at
365 days. Preview the exact candidates first. Resolved issues close as
completed; tracked-elsewhere issues close as not planned. If a label query hits
the default 1000-issue limit, increase `--limit` before the confirmed run.

For image uploads, install `drogers0/gh-image` if the helper requests it. Images
referenced in a body by the same path or basename passed to `--image` are
rewritten inline; unreferenced uploads are appended. Browser-session extraction
is preferred, with `GH_SESSION_TOKEN` in `.env` only as a fallback. Never put a
session token in arguments, bodies, logs, or commits.

## Diagnose image-upload failures

Run `"$TRACKER" doctor --repo owner/repo` on the host first. CLI authentication
and a browser web session are separate checks; a valid `gh` login does not
prove browser-cookie extraction works. Inspect `gh image --version` when
`check-token` reports an empty session or `net/http` warns about invalid cookie
bytes. Those symptoms alone do not prove the browser session expired.

If the installed version ends in `-hbd`, test the official standard build
before requesting a manual cookie or patching the extraction library. The
standard 1.3.0 build (kooky) successfully read an existing Linux browser session
that 1.3.0-hbd could not. Treat this as a backend-specific diagnostic, not a
universal HBD failure. Discover the current release assets for the host OS and
architecture, verify the published checksum, and run the candidate's
`check-token` with `GH_SESSION_TOKEN` unset. This checks the browser path without
printing the cookie. Avoid `extract-token`, which exposes it.

When repairing the installed tool is authorized, retain a rollback copy and
install the verified working binary. Re-run `doctor`, then verify a real upload
using the already-requested, inspected screenshots. `doctor --live --yes`
creates an orphan diagnostic asset; prefer the intended proof upload when one
is pending. Read back the issue to confirm its attachments, and record recovery
in the related child issue. Keep local proof files until upload succeeds.

## Work an issue

1. Run `view`, read the entire body and comment history, and inspect relevant
   cached images. Treat the thread as durable working memory.
2. Reproduce the problem and identify its root cause before patching. Record
   concrete evidence: commands and output, a failing test, logs, or a screenshot.
3. If one report contains distinct problems, show the breakdown and ask whether
   to split it or solve them together. Do not silently choose or create issues.
4. For non-trivial work, post the diagnosis and plan, then mark `in-progress`.
5. Link each meaningful progress update to `owner/repo@sha`, a commit URL, or a
   PR. Match proof to the change: tests/logs for logic, rendered screenshots for
   UI behavior. For UI work, use the `ui-work` skill and attach the inspected
   runtime screenshots to the issue with the route and state they prove.
6. Post final proof and set `resolved`. Do not close or reopen an individual
   issue ad hoc. Use `archive` only as a separately authorized maintenance pass
   after the configured inactivity period.

Keep issue prose readable on GitHub: do not hard-wrap paragraphs, but retain
semantic breaks between paragraphs, list items, tables, and fenced code.
