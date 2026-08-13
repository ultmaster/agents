#!/usr/bin/env python3

"""Validate the paired subagent definitions and their repository catalog."""

from __future__ import annotations

import re
import sys
import tomllib
from pathlib import Path

from strictyaml import YAMLError, load


REPO_ROOT = Path(__file__).resolve().parents[1]
SUBAGENTS_ROOT = REPO_ROOT / "subagents"
NAME_PATTERN = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
FRONTMATTER_PATTERN = re.compile(r"\A---\n(.*?)\n---\n(.*)\Z", re.DOTALL)


def fail(message: str) -> None:
    print(f"validate-subagents: {message}", file=sys.stderr)
    raise SystemExit(1)


def subagent_catalog() -> set[str]:
    catalog: set[str] = set()
    in_subagents = False
    for line in (REPO_ROOT / "README.md").read_text(encoding="utf-8").splitlines():
        if line == "## Subagents":
            in_subagents = True
            continue
        if in_subagents and line.startswith("## "):
            break
        if in_subagents and (match := re.match(r"^\| `([^`]+)` \|", line)):
            catalog.add(match.group(1))
    return catalog


def read_claude_definition(path: Path, name: str) -> tuple[list[str], str | None]:
    """Return the Claude definition's errors and its system prompt body."""

    text = path.read_text(encoding="utf-8")
    match = FRONTMATTER_PATTERN.match(text)
    if match is None:
        return [f"{path.name} must open with a YAML frontmatter block"], None

    try:
        frontmatter = load(match.group(1)).data
    except YAMLError as error:
        return [f"{path.name} frontmatter is invalid: {error}"], None
    if not isinstance(frontmatter, dict):
        return [f"{path.name} frontmatter must be a mapping"], None

    errors: list[str] = []
    if frontmatter.get("name") != name:
        errors.append(f"{path.name} frontmatter name must be {name!r}")
    description = frontmatter.get("description")
    if not isinstance(description, str) or not description.strip():
        errors.append(f"{path.name} must define a nonempty description")

    body = match.group(2).strip()
    if not body:
        errors.append(f"{path.name} must define a system prompt body")
    return errors, body


def read_codex_definition(path: Path, name: str) -> tuple[list[str], str | None]:
    """Return the Codex definition's errors and its developer instructions."""

    try:
        definition = tomllib.loads(path.read_text(encoding="utf-8"))
    except tomllib.TOMLDecodeError as error:
        return [f"{path.name} is invalid TOML: {error}"], None

    errors: list[str] = []
    if definition.get("name") != name:
        errors.append(f"{path.name} name must be {name!r}")
    description = definition.get("description")
    if not isinstance(description, str) or not description.strip():
        errors.append(f"{path.name} must define a nonempty description")

    instructions = definition.get("developer_instructions")
    if not isinstance(instructions, str) or not instructions.strip():
        errors.append(f"{path.name} must define nonempty developer_instructions")
        return errors, None
    return errors, instructions.strip()


def validate_subagent(subagent_dir: Path) -> list[str]:
    name = subagent_dir.name
    if not NAME_PATTERN.match(name):
        return ["directory name must be lowercase words joined by hyphens"]

    expected = {f"{name}.md", f"{name}.toml"}
    present = {entry.name for entry in subagent_dir.iterdir()}
    errors = [f"{missing} is missing" for missing in sorted(expected - present)]
    errors.extend(
        f"{unexpected} is not part of a subagent definition"
        for unexpected in sorted(present - expected)
    )
    if errors:
        return errors

    claude_errors, claude_body = read_claude_definition(subagent_dir / f"{name}.md", name)
    codex_errors, codex_body = read_codex_definition(subagent_dir / f"{name}.toml", name)
    errors = claude_errors + codex_errors
    # Each harness keeps its native format, so the shared instructions exist
    # twice. Requiring them to stay identical is what keeps that safe.
    if claude_body is not None and codex_body is not None and claude_body != codex_body:
        errors.append(
            f"{name}.md body and {name}.toml developer_instructions must match"
        )
    return errors


def main() -> None:
    if not SUBAGENTS_ROOT.is_dir():
        fail(f"missing source directory: {SUBAGENTS_ROOT}")
    subagent_dirs = sorted(path for path in SUBAGENTS_ROOT.iterdir() if path.is_dir())
    if not subagent_dirs:
        fail("no subagent directories found")

    failures: list[str] = []
    for entry in sorted(SUBAGENTS_ROOT.iterdir()):
        if not entry.is_dir():
            failures.append(f"{entry.name}: subagents/ must contain only directories")
    for subagent_dir in subagent_dirs:
        failures.extend(
            f"{subagent_dir.name}: {error}" for error in validate_subagent(subagent_dir)
        )

    catalog = subagent_catalog()
    directory_names = {path.name for path in subagent_dirs}
    if catalog != directory_names:
        missing = sorted(directory_names - catalog)
        extra = sorted(catalog - directory_names)
        if missing:
            failures.append(f"README subagent catalog is missing: {', '.join(missing)}")
        if extra:
            failures.append(
                f"README subagent catalog has unknown entries: {', '.join(extra)}"
            )

    if failures:
        for failure in failures:
            print(f"validate-subagents: {failure}", file=sys.stderr)
        raise SystemExit(1)
    print(f"validated {len(subagent_dirs)} subagents")


if __name__ == "__main__":
    main()
