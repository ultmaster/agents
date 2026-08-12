---
name: windows-dev
description: Diagnose and run repository development workflows on Windows or WSL. Use for any Windows-specific development problem - shells and lifecycle scripts interpreted differently by cmd.exe, PowerShell, Git Bash, or WSL; paths, quoting, case sensitivity, long paths, line endings, executable bits, or symlinks; environment-variable and PATH syntax; native toolchain and build failures; locked files, ports, and process control; WSL, container, and network boundaries; and Windows-only memory or performance limits. Discover the contract from project files, choose the intended shell and toolchain explicitly, and distinguish platform failures from pre-existing project failures.
---

# Windows Development

Inspect the repository's manifests, scripts, CI configuration, and local
instructions before choosing a shell or toolchain. Do not assume every Windows
project wants Git Bash, WSL, or a native build: use what the project targets.

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
- Translate environment-variable syntax for the active shell (`VAR=value`,
  `$env:VAR=...`, or `set VAR=...`) or use a cross-platform launcher already in
  the project. `PATH` entries are separated by `;`, not `:`.

## Paths and the filesystem

- Quote paths containing spaces and normalize path ownership at tool
  boundaries. Windows, Git Bash, WSL, and containers each want a different form
  (`C:\dir`, `/c/dir`, `/mnt/c/dir`, container-internal); convert at the
  boundary with the platform's own tool rather than string-editing a path.
- Windows paths are case-insensitive while Git and Linux CI are not. A file
  referenced with different casing works locally and fails elsewhere; rename
  case-only changes through Git so the index records them.
- Long paths fail around the legacy 260-character limit, usually in deep
  dependency or build trees. Enable long-path support in Git and Windows rather
  than relocating or shortening directories the project expects.
- Reserved device names and characters (`CON`, `NUL`, `COM1`, `:`, `*`, `?`,
  `"`, `<`, `>`, `|`) cannot exist as filenames, so a checkout containing one
  fails on Windows only. Report it; do not silently rename repository content.

## Text, permissions, and links

- Preserve LF endings and Git executable bits for shell scripts. Check
  `.gitattributes`, `core.autocrlf`, and the Git index before rewriting files.
  A CRLF shebang surfaces as a "bad interpreter" or "command not found" error
  on a script that looks correct.
- Treat symlink failures as a capability/configuration issue - Developer Mode,
  administrator rights, or `core.symlinks` - and do not replace a link with a
  stale copied directory unless the repository explicitly permits it.

## Processes, ports, and locked files

- Windows locks files that a process still has open, so installs, cleans, and
  rebuilds fail with EBUSY, EPERM, or EACCES. Identify and stop the holding
  process instead of retrying, force-deleting, or disabling the step.
- POSIX signal semantics do not apply. A shutdown path that relies on SIGTERM
  will not run under a hard kill; prefer the project's documented stop command,
  and confirm the process actually exited before restarting it.
- Resolve port conflicts by finding the owning process with Windows' own
  tooling before killing anything, and never kill a process you did not start
  without saying so first.

## Toolchains and builds

- Native modules need the C/C++ build tools, Windows SDK, and interpreter
  versions the project documents. Install the documented toolchain; do not swap
  package managers, compilers, or Node versions to route around a build error.
- Prefer prebuilt binaries the project already offers over compiling locally.
- Real-time antivirus scanning dominates file-heavy installs, watchers, and
  test runs. Exclusions are the user's decision: report the cost, do not change
  security settings.
- If a build worker exhausts memory, confirm the failing process first, then set
  an appropriately scoped runtime heap option (for Node, `NODE_OPTIONS`) and
  report the required value. Do not hide a leak behind a global permanent setting.

## WSL and container boundaries

- Keep the working tree on the same filesystem as the tools that operate on it.
  Crossing the boundary (`/mnt/c`, `\\wsl$`, bind mounts) is slow and loses
  metadata such as executable bits.
- File watchers usually do not receive change events across that boundary, so a
  dev server can appear to ignore edits made from the other side.
- A service bound to the loopback address inside WSL or a container may be
  unreachable from Windows. Bind the interface the project documents rather
  than disabling firewall or isolation settings.

## Verification

Run the same scoped and aggregate checks required on other platforms. When a
command fails, reproduce the equivalent command in the repository's primary
environment before calling it Windows-specific. Report pre-existing or
unsupported-package failures separately rather than expanding the task to fix
them.
