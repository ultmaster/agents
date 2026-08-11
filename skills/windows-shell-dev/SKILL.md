---
name: windows-shell-dev
description: Diagnose and run repository development workflows on Windows or WSL. Use when scripts fail because cmd.exe, PowerShell, Git Bash, or WSL interprets them differently; package-manager lifecycle scripts cannot find Bash; paths, quoting, line endings, executable bits, symlinks, or environment-variable syntax break; or a Windows-only build exhausts memory. Discover the shell contract from project files, choose the intended shell explicitly, and distinguish platform failures from pre-existing project failures.
---

# Windows Shell Development

Inspect the repository's manifests, scripts, and local instructions before
choosing a shell. Do not assume every Windows project wants Git Bash: use the
shell the project actually targets.

## Shell selection

- Run POSIX shell scripts from Git Bash or WSL and invoke them explicitly with
  `bash path/to/script.sh` when a package manager would otherwise use `cmd.exe`.
- Run PowerShell scripts with the repository's documented PowerShell edition
  and execution policy. Do not translate them into Bash ad hoc.
- For pnpm/npm lifecycle scripts containing POSIX syntax, configure the package
  manager's script shell explicitly when needed. A common pnpm form is:

  ```text
  pnpm --config.scriptShell="C:/Program Files/Git/bin/bash.exe" <command>
  ```

  Prefer the path discovered on the machine; do not bake this example into
  project configuration without checking it.

## Common failure classes

- Translate environment-variable syntax for the active shell (`VAR=value`,
  `$env:VAR=...`, or `set VAR=...`) or use a cross-platform launcher already in
  the project.
- Quote paths containing spaces and normalize path ownership at tool boundaries.
  Windows, WSL, Docker, and Git Bash may each require a different path form.
- Preserve LF endings and Git executable bits for shell scripts. Check
  `.gitattributes`, `core.autocrlf`, and the Git index before rewriting files.
- Treat symlink failures as a capability/configuration issue; do not replace a
  link with a stale copied directory unless the repository explicitly permits it.
- If a build worker exhausts memory, confirm the failing process first, then set
  an appropriately scoped runtime heap option (for Node, `NODE_OPTIONS`) and
  report the required value. Do not hide a leak behind a global permanent setting.

## Verification

Run the same scoped and aggregate checks required on other platforms. When a
command fails, reproduce the equivalent command in the repository's primary
environment before calling it Windows-specific. Report pre-existing or
unsupported-package failures separately rather than expanding the task to fix
them.
