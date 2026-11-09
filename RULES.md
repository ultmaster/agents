# Personal Agent Instructions

## Working style

- Follow the project's own instructions wherever they differ from these; the project determines its commands, layout, branches, and conventions. Prefer its own skills for project workflows while continuing to follow the applicable safety rules.
- Treat the named task, phase, or pull request as a scope boundary. Ask before adding adjacent fixes, refactors, or documents.
- Prefer the smallest coherent design with one clear owner for each behavior. Before adding an abstraction or a second representation of the same concept, explain what problem it solves and why an existing owner cannot handle it.
- Update existing plans, proposals, and specs in place unless the user asks for a new durable artifact.
- Before reporting an environment blocker, inspect the project's tooling and try the documented path. If the sandbox denies execution, request the execution permission instead of reporting a missing host capability.
- Run the verification the change actually needs, beyond the narrowest passing check. State plainly what remains unrun or unfinished.
- During investigation, review, and verification, run only read-only probes against production. Do not create test records, upload files, run jobs, change configuration, or restart services there. Exercise mutations in an isolated test environment with separate storage and dependencies; a different port or disposable record does not make a production dependency safe to write to. A production change requires explicit user authorization for that change.

## Design and documentation

- Make interfaces, types, API contracts, database tables, and similar shared definitions self-explanatory for human review. Use clear names and detailed comments explaining their purpose and field meanings, including units, invariants, optionality, and non-obvious behavior where applicable. Keep names and comments consistent with the implementation.
- Do not manually wrap Markdown prose or enforce a fixed line width. Keep each paragraph or prose list item on a single source line in instruction files, READMEs, PR descriptions, issues, and other text rendered directly on GitHub. Preserve line breaks needed for Markdown structure or code.

## Reviews

- For pull requests, inspect the real base/head diff and history, and verify claims in the PR description against them.
- When reviewing architecture, also check for overengineering, unjustified asymmetry, duplicated components or implementations, and confusing interfaces or names alongside the usual review criteria.
- When asked to review work that is already in a pull request, always post a PR comment recording the reviewed head commit, scope, findings, and verification limits, even when there are no findings. Include the comment link in the final response so the review is easy to track.

## Git and publishing

- Work and commit directly on the project's mainline branch by default; identify it from project instructions and Git metadata. Create a new branch only when the user explicitly asks for one or requests a pull request. Continue user-directed branch or PR work on that task's intended branch.
- Confirm the repository root and intended branch before committing, including when multiple checkouts exist; the current checkout alone does not establish which branch owns the task.
- Commit completed, verified task changes by default unless the user asks to leave them uncommitted. Keep unrelated changes out of those commits. Split large changes into several coherent, focused commits so each part is clear to review. Never commit credentials, caches, raw transcripts, or other private runtime state.
- Check remotes before opening a pull request. Where a canonical `upstream` exists, target it and use the fork only as the head remote.
- In Codex, run `gh` outside the sandbox, including reads and scripts that wrap it, using `sandbox_permissions=require_escalated`. The sandbox cannot reach the host's credential store, so a sandboxed authentication failure does not establish that the user is logged out.
- Unless the user gives different push instructions, you may push completed commits without a frequency limit to GitHub repositories owned by `microsoft` and to fork branches backing PRs targeting those repositories. For all other pushes, you may push when the repository has had fewer than three pushes in the preceding 24 hours. Check push activity rather than commit counts. At three or more pushes, keep the commits local and wait for batching or explicit human approval to push. If push activity cannot be established, keep the commits local and report that uncertainty. This default authorizes Git pushes only; other publication still needs authorization.
- Treat committing, pushing, and opening a pull request as separate actions and report their states precisely.
