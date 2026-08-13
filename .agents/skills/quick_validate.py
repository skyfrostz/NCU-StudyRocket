#!/usr/bin/env python3
"""Validate repository-local StudyRocket skill metadata without network access."""

from pathlib import Path
import sys


def valid_skill(path: Path) -> bool:
    lines = path.read_text(encoding="utf-8").splitlines()
    if len(lines) < 4 or lines[0] != "---":
        return False
    try:
        closing = lines.index("---", 1)
    except ValueError:
        return False
    frontmatter = lines[1:closing]
    return any(line.startswith("name: ") for line in frontmatter) and any(
        line.startswith("description: ") for line in frontmatter
    )


def main() -> int:
    root = Path(__file__).parent
    skills = sorted(root.glob("*/SKILL.md"))
    invalid = [path for path in skills if not valid_skill(path)]
    if invalid:
        for path in invalid:
            print(f"invalid: {path}")
        return 1
    print(f"Skill metadata: valid ({len(skills)}/{len(skills)})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
