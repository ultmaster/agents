# Personal Agent Instructions

## Working style

- Follow the project's own instructions wherever they differ from these. A
  project owns its commands, layout, branches, and conventions.
- Treat the named task, phase, or pull request as a scope boundary. Do not fold
  in adjacent fixes, refactors, or documents; ask before expanding the scope.
- Prefer the smallest coherent design with one clear owner for each behavior.
  Before adding an abstraction or a second representation of the same concept,
  say what problem it solves and why an existing owner cannot.
- When reviewing architecture, also check for overengineering, unjustified
  asymmetry, duplicated components or implementations, and confusing interfaces
  or names alongside the usual review criteria.
- Make interfaces, types, API contracts, database tables, and similar shared
  definitions self-explanatory for human review. Add detailed comments explaining
  their purpose and field meanings, including units, invariants, optionality,
  and non-obvious behavior where applicable. Keep comments consistent with the
  implementation.
- Update an existing plan, proposal, or spec in place. Do not leave a parallel
  one behind unless asked for a new durable artifact.
- Before reporting an environment blocker, inspect the project's tooling and try
  the documented path. A sandbox denial is not a missing host capability; ask
  for the execution permission instead.
- Run the verification a change actually needs, not only the narrowest passing
  check, and say plainly what was left unrun or unfinished.

## Git and GitHub

- Work and commit directly on the project's mainline branch by default;
  identify it from project instructions and Git metadata rather than assuming
  it is named `main`. Create a new branch only when the user explicitly asks
  for one or requests a pull request. Continue user-directed branch or pull
  request work on that task's intended branch.
- Confirm the repository root and intended branch before committing. A checkout
  is not evidence of which branch owns the work, and the same repository may be
  checked out more than once.
- Commit completed, verified task changes by default unless the user asks to
  leave them uncommitted. Keep unrelated changes out of those commits. Split
  large changes into several coherent, focused commits so each part is clear
  to review.
- Review the real base/head diff and history, not the pull request description.
- When asked to review work that is already in a pull request, always post a PR
  comment recording the reviewed head commit, scope, findings, and verification
  limits, even when there are no findings. Include the comment link in the final
  response so the review is easy to track.
- Check remotes before opening a pull request. Where a canonical `upstream`
  exists, target it and use the fork only as the head remote.
- In Codex, run `gh` outside the sandbox — reads included, and for scripts that
  wrap it. Sandboxed, `gh` cannot reach the host's credential store and reports
  the user as logged out when they are not. Ask for escalated execution
  (`sandbox_permissions=require_escalated`) rather than reporting a login
  problem.
- Treat committing, pushing, and opening a pull request as separate actions and
  report their states precisely.
- Unless the user gives different push instructions, push completed commits
  when the repository has had fewer than three pushes in the preceding 24
  hours. Check push activity rather than commit counts. At three or more pushes,
  keep the commits local and wait for a batch or an explicit push request. If
  push activity cannot be established, keep the commits local and say so. This
  default authorizes Git pushes only; other publication still needs
  authorization.

## Skills and private state

- When a repository has its own skill covering the same ground, prefer it for
  that project's commands, layout, and conventions, and keep following the
  portable safety rules alongside it.
- Never commit credentials, caches, raw transcripts, or other private runtime
  state.
- When changing the personal agent library itself, follow that repository's
  `AGENTS.md`.
