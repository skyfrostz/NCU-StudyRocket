#!/usr/bin/env python3
"""Export an explicit Markdown allowlist without changing the source checkout."""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import uuid

WRITABLE_ROOTS = ("工作台", "保研", "规划", "答疑", "英语", "笔记", "专业")
READ_ONLY_ROOTS = ("智库/学校文件",)
CORE = ("PROFILE.md", "校历与重要日期.md", "AGENTS.md")
SKILLS = ("daily-checkin", "knowledge-ingest", "ncu-planner", "node-countdown",
          "retro-monthly", "retro-weekly", "term-roadmap", "weekly-reslot")
SECRET = re.compile(
    r"-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----|\b(?:sk-[A-Za-z0-9_-]{20,}|LTAI[A-Za-z0-9]{12,}|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b"
    r"|\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"
    r"|(?i:\b(?:Bearer|Basic)\s+[A-Za-z0-9+/_.=-]{8,})"
    r"|(?i:[\"']?(?:[a-z][a-z0-9_]*_)?(?:api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|secret[_-]?key|password|passwd|authorization|token)[\"']?\s*[:=]\s*[\"']?[^\s\"'`;,}]{4,})"
)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def safe_file(root: Path, path: Path) -> bool:
    relative = path.relative_to(root)
    current = root
    for part in relative.parts:
        current /= part
        if current.is_symlink():
            raise ValueError(f"Refusing symbolic link: {relative}")
    return path.is_file()


def candidates(root: Path):
    result: dict[str, str] = {}
    for name in CORE:
        if safe_file(root, root / name):
            result[name] = "readOnly" if name == "AGENTS.md" else "writable"
    for directory in (*WRITABLE_ROOTS, *READ_ONLY_ROOTS):
        base = root / directory
        if base.is_symlink():
            raise ValueError(f"Refusing symbolic link: {directory}")
        for path in sorted(base.rglob("*.md")) if base.exists() else []:
            if safe_file(root, path):
                relative = path.relative_to(root).as_posix()
                if any(part.startswith(".") for part in Path(relative).parts):
                    continue
                result[relative] = "readOnly" if directory in READ_ONLY_ROOTS else "writable"
    for skill in SKILLS:
        base = root / ".agents" / "skills" / skill
        for path in sorted(base.rglob("*.md")) if base.exists() else []:
            if safe_file(root, path):
                # References are context; only the eight existing SKILL.md files
                # may be proposed through the dedicated skill-update interface.
                result[path.relative_to(root).as_posix()] = "readOnly"
    if "AGENTS.md" not in result or "PROFILE.md" not in result:
        raise ValueError("The source must contain AGENTS.md and PROFILE.md")
    return result


def verify(bundle: Path) -> dict:
    if bundle.is_symlink() or (bundle / "repository").is_symlink() or (bundle / "manifest.json").is_symlink():
        raise ValueError("Refusing symbolic link in bundle structure")
    if (bundle / "INCOMPLETE").exists():
        raise ValueError("Incomplete export; create a new snapshot")
    manifest = json.loads((bundle / "manifest.json").read_text())
    if manifest.get("version") != 1:
        raise ValueError("Unsupported manifest")
    uuid.UUID(manifest["repositoryID"])
    root = bundle / "repository"
    expected_modes = candidates(root)
    names = set()
    for item in manifest["files"]:
        name = item["path"]
        if name in names or name.startswith("/") or ".." in Path(name).parts or "\\" in name:
            raise ValueError("Invalid or duplicate manifest path")
        if item.get("mode") != expected_modes.get(name) or name not in expected_modes:
            raise ValueError("Manifest includes a forbidden path or incorrect mode")
        names.add(name)
        target = root / name
        if not safe_file(root, target):
            raise ValueError(f"Missing file: {name}")
        data = target.read_bytes()
        if digest(data) != item["sha256"] or len(data) != item["bytes"]:
            raise ValueError(f"Manifest mismatch: {name}")
    all_paths = list(root.rglob("*"))
    if any(path.is_symlink() for path in all_paths):
        raise ValueError("Unexpected symbolic link in bundle")
    actual = {p.relative_to(root).as_posix() for p in all_paths if p.is_file()}
    if names != actual or names != set(expected_modes):
        raise ValueError("Unexpected files in bundle")
    return manifest


def export(source: Path, destination: Path, repository_id: str | None):
    source = source.resolve(strict=True)
    destination = destination.resolve()
    if destination == source or source in destination.parents:
        raise ValueError("Export must be outside the source checkout")
    if destination.exists():
        raise ValueError("Destination already exists; use a new export directory")
    repository_id = str(uuid.UUID(repository_id)) if repository_id else str(uuid.uuid4())
    entries = []
    contents = []
    initial_candidates = candidates(source)
    for name, mode in sorted(initial_candidates.items()):
        data = (source / name).read_bytes()
        text = data.decode("utf-8")
        if SECRET.search(text):
            raise ValueError(f"Possible credential in {name}; review locally before exporting")
        entries.append({"path": name, "sha256": digest(data), "bytes": len(data), "mode": mode})
        contents.append((name, data))
    # Catch concurrent edits before creating the bundle. Confirm again after
    # exporting so the caller never mistakes a mixed snapshot for a cutover.
    for name, data in contents:
        if (source / name).read_bytes() != data:
            raise ValueError(f"Source changed during export: {name}")
    if candidates(source) != initial_candidates:
        raise ValueError("Source membership changed during export")
    destination.mkdir(mode=0o700, parents=True)
    incomplete = destination / "INCOMPLETE"
    incomplete.write_text("Export has not passed final consistency checks.\n")
    os.chmod(incomplete, 0o600)
    for name, data in contents:
        target = destination / "repository" / name
        target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as out:
            out.write(data)
            out.flush()
            os.fsync(out.fileno())
    manifest = {"version": 1, "repositoryID": repository_id,
                "legacyRepositoryID": digest(str(source).encode()),
                "createdAt": dt.datetime.now(dt.timezone.utc).isoformat(), "files": entries}
    (destination / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    os.chmod(destination / "manifest.json", 0o600)
    for name, data in contents:
        if (source / name).read_bytes() != data:
            (destination / "INCOMPLETE").write_text("Source changed during export; do not import.\n")
            raise ValueError(f"Source changed during export: {name}")
    if candidates(source) != initial_candidates:
        raise ValueError("Source membership changed during export")
    incomplete.unlink()
    try:
        verify(destination)
    except Exception:
        incomplete.write_text("Export verification failed; do not import.\n")
        raise
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path)
    parser.add_argument("--destination", type=Path)
    parser.add_argument("--repository-id")
    parser.add_argument("--verify", type=Path)
    args = parser.parse_args()
    if args.verify:
        manifest = verify(args.verify)
    elif args.source and args.destination:
        manifest = export(args.source, args.destination, args.repository_id)
    else:
        parser.error("use --source/--destination or --verify")
    print(json.dumps({"verified": True, "repositoryID": manifest["repositoryID"],
                      "fileCount": len(manifest["files"]),
                      "bytes": sum(x["bytes"] for x in manifest["files"])}, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, UnicodeError, KeyError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
