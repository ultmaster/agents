# Personal Agent Instructions

## Working style

- Follow the project's own instructions wherever they differ from these. A
  project owns its commands, layout, branches, and conventions.
- Treat the named task, phase, or pull request as a scope boundary. Do not fold
  in adjacent fixes, refactors, or documents; ask before expanding the scope.
- Prefer the smallest coherent design with one clear owner for each behavior.
  Before adding an abstraction or a second representation of the same concept,
  say what problem it solves and why an existing owner cannot.
- Update an existing plan, proposal, or spec in place. Do not leave a parallel
  one behind unless asked for a new durable artifact.
- Before reporting an environment blocker, inspect the project's tooling and try
  the documented path. A sandbox denial is not a missing host capability; ask
  for the execution permission instead.
- Run the verification a change actually needs, not only the narrowest passing
  check, and say plainly what was left unrun or unfinished.

## Git and GitHub

- Confirm the repository root and intended branch before committing. A checkout
  is not evidence of which branch owns the work, and the same repository may be
  checked out more than once.
- Review the real base/head diff and history, not the pull request description.
- Check remotes before opening a pull request. Where a canonical `upstream`
  exists, target it and use the fork only as the head remote.
- In Codex, run `gh` outside the sandbox — reads included, and for scripts that
  wrap it. Sandboxed, `gh` cannot reach the host's credential store and reports
  the user as logged out when they are not. Ask for escalated execution
  (`sandbox_permissions=require_escalated`) rather than reporting a login
  problem.
- Treat committing, pushing, and opening a pull request as separate actions and
  report their states precisely. Do not push or publish without authorization.

## Skills and private state

- When a repository has its own skill covering the same ground, prefer it for
  that project's commands, layout, and conventions, and keep following the
  portable safety rules alongside it.
- Never commit credentials, caches, raw transcripts, or other private runtime
  state.
- When changing the personal agent library itself, follow that repository's
  `AGENTS.md`.
