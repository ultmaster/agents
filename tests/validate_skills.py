#!/usr/bin/env python3

"""Validate the portable skill tree and its repository-owned metadata."""

from __future__ import annotations

import re
import sys
from pathlib import Path

from skills_ref import read_properties, validate
from strictyaml import YAMLError, load


REPO_ROOT = Path(__file__).resolve().parents[1]
SKILLS_ROOT = REPO_ROOT / "skills"


def fail(message: str) -> None:
    print(f"validate-skills: {message}", file=sys.stderr)
    raise SystemExit(1)


def skill_catalog() -> set[str]:
    catalog: set[str] = set()
    in_skills = False
    for line in (REPO_ROOT / "README.md").read_text(encoding="utf-8").splitlines():
        if line == "## Skills":
            in_skills = True
            continue
        if in_skills and line.startswith("## "):
            break
        if in_skills and (match := re.match(r"^\| `([^`]+)` \|", line)):
            catalog.add(match.group(1))
    return catalog


def validate_openai_metadata(skill_dir: Path, skill_name: str) -> list[str]:
    metadata_path = skill_dir / "agents" / "openai.yaml"
    if not metadata_path.is_file():
        return ["agents/openai.yaml is missing"]

    try:
        metadata = load(metadata_path.read_text(encoding="utf-8")).data
    except YAMLError as error:
        return [f"agents/openai.yaml is invalid: {error}"]

    interface = metadata.get("interface") if isinstance(metadata, dict) else None
    if not isinstance(interface, dict):
        return ["agents/openai.yaml must contain an interface mapping"]

    errors: list[str] = []
    for key in ("display_name", "short_description", "default_prompt"):
        value = interface.get(key)
        if not isinstance(value, str) or not value.strip():
            errors.append(f"interface.{key} must be a nonempty string")

    short_description = interface.get("short_description", "")
    if isinstance(short_description, str) and not 25 <= len(short_description) <= 64:
        errors.append("interface.short_description must contain 25-64 characters")

    default_prompt = interface.get("default_prompt", "")
    if isinstance(default_prompt, str) and f"${skill_name}" not in default_prompt:
        errors.append(f"interface.default_prompt must mention ${skill_name}")
    return errors


def main() -> None:
    skill_dirs = sorted(path for path in SKILLS_ROOT.iterdir() if path.is_dir())
    if not skill_dirs:
        fail("no skill directories found")

    failures: list[str] = []
    names: set[str] = set()
    for skill_dir in skill_dirs:
        if not (skill_dir / "SKILL.md").is_file():
            failures.append(f"{skill_dir.name}: SKILL.md is missing")
            continue
        validation_errors = validate(skill_dir)
        for error in validation_errors:
            failures.append(f"{skill_dir.name}: {error}")
        if validation_errors:
            continue

        properties = read_properties(skill_dir)
        if properties.name != skill_dir.name:
            failures.append(
                f"{skill_dir.name}: frontmatter name is {properties.name!r}"
            )
        if properties.name in names:
            failures.append(f"{skill_dir.name}: duplicate skill name {properties.name!r}")
        names.add(properties.name)
        failures.extend(
            f"{skill_dir.name}: {error}"
            for error in validate_openai_metadata(skill_dir, properties.name)
        )

    catalog = skill_catalog()
    directory_names = {path.name for path in skill_dirs}
    if catalog != directory_names:
        missing = sorted(directory_names - catalog)
        extra = sorted(catalog - directory_names)
        if missing:
            failures.append(f"README skill catalog is missing: {', '.join(missing)}")
        if extra:
            failures.append(f"README skill catalog has unknown entries: {', '.join(extra)}")

    if failures:
        for failure in failures:
            print(f"validate-skills: {failure}", file=sys.stderr)
        raise SystemExit(1)
    print(f"validated {len(skill_dirs)} skills")


if __name__ == "__main__":
    main()
