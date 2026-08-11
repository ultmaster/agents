---
name: issue-tracker
description: Track work in GitHub Issues across arbitrary repositories. Use whenever an agent needs to list or read issues, inspect a complete issue thread and its attached images, create an issue, post signed diagnostic/progress/proof comments, manage status or area labels, or resume work from an issue. Uses upstream-first repository discovery with an explicit --repo override, local attachment caching, dry-run previews, and --yes-gated writes.
---

# Issue Tracker

Use the bundled helper instead of assembling ad hoc `gh` commands. Resolve its
absolute path from this skill directory once per shell:

```bash
TRACKER="<skill-root>/scripts/issue-tracker.sh"
"$TRACKER" <command> [options]
```

In a sandboxed agent harness, request outside-sandbox/host execution before
every non-dry-run helper call, including reads: the helper needs the host's
`gh` authentication and network access. `help` and `--dry-run` stay local.
Escalation only provides access; writes still require user intent and `--yes`.

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
override deliberately.

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
and downloaded attachments under `cache/<repo>/<issue>/` unless `--dir` is
given. Open every cached image needed to understand the report; printing the
paths is not equivalent to inspecting them.

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
```

`create` and `comment` require attribution. Pass `--sign` or configure
`ISSUE_TRACKER_SIGNATURE` in the skill's gitignored `.env`; identify the actual
agent and never impersonate a human. Comments receive an attribution footer.

Areas default to labels such as `area:api`. Configure the prefix, color, and
bare-label vocabulary in `.env` for repositories with an established label
scheme. Status uses one managed status at a time; areas are additive. Missing
labels are created without overwriting existing label metadata.

For image uploads, install `drogers0/gh-image` if the helper requests it. Images
referenced in a body by the same path or basename passed to `--image` are
rewritten inline; unreferenced uploads are appended. Browser-session extraction
is preferred, with `GH_SESSION_TOKEN` in `.env` only as a fallback. Never put a
session token in arguments, bodies, logs, or commits.

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
   UI behavior.
6. Post final proof and set `resolved`. Agents never close or reopen issues; a
   human verifies the evidence and changes issue state.

Keep issue prose readable on GitHub: do not hard-wrap paragraphs, but retain
semantic breaks between paragraphs, list items, tables, and fenced code.
