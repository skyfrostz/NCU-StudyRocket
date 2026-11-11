#!/usr/bin/env python3
"""Verify a completed backup and restore only into a new, isolated directory.

Never stops a service, changes a live path, replaces an existing directory or
enables writes. A failed copy leaves an explicit INCOMPLETE marker for inspection.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import sqlite3
import stat
import sys
import uuid

ROOTS = {"工作台", "保研", "规划", "答疑", "英语", "笔记", "专业"}
SKILLS = {"daily-checkin", "knowledge-ingest", "ncu-planner", "node-countdown",
          "retro-monthly", "retro-weekly", "term-roadmap", "weekly-reslot"}
HASH = re.compile(r"[0-9a-f]{64}\Z")


def no_symlinks(path: Path) -> Path:
    path = Path(os.path.abspath(path))
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        if current.is_symlink():
            raise ValueError(f"Symbolic link is not allowed: {current}")
    return path


def relative_name(value) -> str:
    if not isinstance(value, str) or not value or "\\" in value or any(ord(c) < 32 for c in value):
        raise ValueError("Invalid backup path")
    path = PurePosixPath(value)
    if path.is_absolute() or any(p in ("", ".", "..") for p in value.split("/")) or path.as_posix() != value:
        raise ValueError("Invalid backup path")
    return value


def academic_path(name: str) -> bool:
    parts = PurePosixPath(name).parts
    if not name.endswith(".md"):
        return False
    return (name in {"PROFILE.md", "AGENTS.md", "校历与重要日期.md"}
            or len(parts) > 1 and parts[0] in ROOTS
            or len(parts) > 2 and parts[:2] == ("智库", "学校文件")
            or len(parts) >= 4 and parts[:2] == (".agents", "skills") and parts[2] in SKILLS)


def inventory(root: Path) -> set[str]:
    result = set()
    for directory, directories, files in os.walk(root, followlinks=False):
        for name in directories + files:
            path = Path(directory) / name
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode) or not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)):
                raise ValueError(f"Non-regular backup entry: {path.relative_to(root)}")
            if stat.S_ISREG(mode):
                result.add(path.relative_to(root).as_posix())
    return result


def fingerprint(path: Path) -> tuple[int, str]:
    no_symlinks(path)
    digest, count = hashlib.sha256(), 0
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            count += len(block)
            digest.update(block)
    return count, digest.hexdigest()


def read_json(path: Path):
    no_symlinks(path)
    if not path.is_file() or path.stat().st_size > 4 * 1024 * 1024:
        raise ValueError("Missing or oversized backup metadata")
    return json.loads(path.read_text(encoding="utf-8"))


def file_entries(value) -> dict[str, tuple[int, str]]:
    if not isinstance(value, list) or not value:
        raise ValueError("Backup has no file inventory")
    result = {}
    for entry in value:
        name = relative_name(entry["path"])
        length, digest = entry["bytes"], entry["sha256"]
        if name in result or type(length) is not int or length < 0 or not isinstance(digest, str) or not HASH.fullmatch(digest):
            raise ValueError("Invalid or duplicate checksum entry")
        result[name] = (length, digest)
    return result


def verify_database(path: Path, repository_id: str):
    no_symlinks(path)
    # immutable=1 prevents SQLite from creating journal/WAL sidecars in the backup.
    with sqlite3.connect(path.as_uri() + "?mode=ro&immutable=1", uri=True) as database:
        if database.execute("PRAGMA quick_check").fetchall() != [("ok",)]:
            raise ValueError("SQLite quick_check failed")
        identity = database.execute("SELECT value FROM kv WHERE key='repositoryID'").fetchone()
        if identity != (repository_id,):
            raise ValueError("SQLite repository identity differs from the manifest")
        if database.execute("SELECT 1 FROM operations WHERE state='prepared' LIMIT 1").fetchone():
            raise ValueError("Backup contains an unrecovered file transaction")


def verify_backup(root: Path, expected_id: str | None = None):
    root = no_symlinks(root)
    if not root.is_dir():
        raise ValueError("Backup directory does not exist")
    actual = inventory(root)
    markers = actual & {"verified-backup.json", "_download-receipt.json"}
    if len(markers) != 1:
        raise ValueError("Expected exactly one server or Mac download receipt")
    marker = next(iter(markers))
    receipt = read_json(root / marker)
    if marker == "verified-backup.json":
        if receipt.get("version") != 1:
            raise ValueError("Unsupported verification receipt")
        dt.datetime.fromisoformat(receipt["createdAt"].replace("Z", "+00:00"))
        entries = file_entries(receipt["files"])
    else:
        # Desktop stores the authenticated CloudBackupManifest after hashing all
        # downloaded bytes. Its Date follows v1's seconds since 2001, not ISO8601.
        stamp = receipt.get("createdAt")
        ident = receipt.get("id")
        if (type(stamp) not in (int, float) or not math.isfinite(stamp)
                or not isinstance(ident, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,100}", ident)):
            raise ValueError("Invalid Mac download receipt")
        dt.datetime.fromtimestamp(stamp + 978307200, tz=dt.timezone.utc)
        files = receipt.get("files")
        if not isinstance(files, list):
            raise ValueError("Invalid Mac download inventory")
        entries = file_entries([{"path": item["path"], "bytes": item["byteCount"],
                                 "sha256": item["sha256"]} for item in files])
    if set(entries) != actual - {marker}:
        raise ValueError("Receipt inventory differs from backup files")
    if not {"manifest.json", "cloud.sqlite"}.issubset(entries):
        raise ValueError("Backup lacks its manifest or SQLite snapshot")
    for name, expected in entries.items():
        if name not in {"manifest.json", "cloud.sqlite"}:
            if not name.startswith("repository/") or not academic_path(name[len("repository/"):]):
                raise ValueError(f"File outside the backup allowlist: {name}")
        if fingerprint(root / name) != expected:
            raise ValueError(f"Receipt checksum mismatch: {name}")
    manifest = read_json(root / "manifest.json")
    repository_id = manifest["repositoryID"]
    if manifest.get("version") != 1 or str(uuid.UUID(repository_id)).lower() != repository_id.lower():
        raise ValueError("Invalid snapshot manifest")
    if expected_id is not None and uuid.UUID(expected_id) != uuid.UUID(repository_id):
        raise ValueError("Backup belongs to a different repository")
    academic = file_entries(manifest["files"])
    expected_files = {"repository/" + name: value for name, value in academic.items()}
    if expected_files != {name: value for name, value in entries.items() if name.startswith("repository/")}:
        raise ValueError("Snapshot manifest differs from verification receipt")
    verify_database(root / "cloud.sqlite", repository_id)
    return root, repository_id, entries


def sync_directory(path: Path):
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def write_new(path: Path, data: bytes):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as target:
        target.write(data)
        target.flush()
        os.fsync(target.fileno())


def restore(backup: Path, destination: Path, expected_id: str | None = None):
    destination = no_symlinks(destination)
    if os.path.lexists(destination):
        raise ValueError("Destination already exists; choose a new isolated directory")
    if not destination.parent.is_dir():
        raise ValueError("Destination parent must already exist")
    backup, repository_id, entries = verify_backup(backup, expected_id)
    if backup == destination or backup in destination.parents:
        raise ValueError("Destination must be outside the backup")
    # Exclusive mkdir reserves a fresh destination; an existing target is never replaced.
    destination.mkdir(mode=0o700)
    incomplete = destination / "RESTORE_INCOMPLETE"
    write_new(incomplete, b"Restore is incomplete. Do not start a service from this directory.\n")
    mappings = {}
    for name, expected in sorted(entries.items()):
        target_name = "state/cloud.sqlite" if name == "cloud.sqlite" else name
        target = destination / target_name
        target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        source = no_symlinks(backup / name)
        descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with source.open("rb") as before, os.fdopen(descriptor, "wb") as after:
            shutil.copyfileobj(before, after, length=1024 * 1024)
            after.flush()
            os.fsync(after.fileno())
        if fingerprint(target) != expected:
            raise ValueError(f"Copied bytes differ from receipt: {name}; incomplete destination retained")
        mappings[target_name] = {"bytes": expected[0], "sha256": expected[1]}
    verify_database(destination / "state/cloud.sqlite", repository_id)
    # Validate again to detect a backup changing during the copy.
    _, final_id, final_entries = verify_backup(backup, expected_id)
    if final_id != repository_id or final_entries != entries:
        raise ValueError("Backup changed during restore; incomplete destination retained")
    receipt = {"version": 1, "repositoryID": repository_id,
               "restoredAt": dt.datetime.now(dt.timezone.utc).isoformat(), "files": mappings,
               "liveSwitchPerformed": False}
    write_new(destination / "restore-receipt.json", (json.dumps(receipt, ensure_ascii=False, indent=2) + "\n").encode())
    for directory, _, _ in os.walk(destination, topdown=False):
        sync_directory(Path(directory))
    incomplete.unlink()
    sync_directory(destination)
    sync_directory(destination.parent)
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backup", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--expected-repository-id")
    args = parser.parse_args()
    result = restore(args.backup, args.destination, args.expected_repository_id)
    print(json.dumps({"restored": True, "repositoryID": result["repositoryID"],
                      "fileCount": len(result["files"]), "liveSwitchPerformed": False}))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, AttributeError, sqlite3.DatabaseError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
