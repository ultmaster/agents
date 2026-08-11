---
name: windows-dev
description: Use when developing this repo on Windows, or when a script fails with a shell error that smells like cmd.exe (`-e was unexpected`, `'bash' is not recognized`), a pnpm lifecycle script (`prepare`, `install`) fails on Windows, or `pnpm build` runs out of heap in starfish's tsup DTS worker. Covers the Git Bash requirement, forcing pnpm's script shell, the build heap flag, and which failures are pre-existing rather than Windows-specific.
---

# Developing on Windows

The repo's scripts assume a POSIX shell, so **run everything from Git Bash**. Most
commands then just work; a few things to know:

- **Scripts must run under bash, not cmd.exe.** Anything with POSIX syntax (the `dev:*`
  scripts, the `packages/*` `prepare` husky guards, `.agents/skills/**/*.sh`) breaks
  under cmd.exe (`-e was unexpected`). The package scripts already invoke `bash …`; run
  skill scripts the same way.
- **pnpm lifecycle scripts** (`prepare`, etc.) run in pnpm's own cmd.exe child regardless
  of your shell, so pass bash explicitly when one fails:
  `pnpm --config.scriptShell="C:/Program Files/Git/bin/bash.exe" <cmd>`. This is mainly a
  one-time `install` thing — once `prepare` succeeds, pnpm won't re-run it.
- **Build heap.** Export `NODE_OPTIONS=--max-old-space-size=8192` or `pnpm build` OOMs in
  `starfish`'s tsup DTS worker.
- `office` (build) and `tui` (`tsc`) fail regardless — that's the unmaintained-package
  breakage described under "Unmaintained Packages" in `AGENTS.md`, not Windows.
