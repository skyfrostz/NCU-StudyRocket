#!/usr/bin/env python3
"""Make a verified, uniquely named backup and retain 30 days of successful ones."""
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import uuid

BASE = Path("/var/lib/studyrocket/cloud")
BINARY = "/opt/studyrocket/cloud/current/StudyRocketCloud"


def verify_snapshot(output: Path):
    output = output.resolve(strict=True)
    manifest = json.loads((output / "manifest.json").read_text())
    if manifest.get("version") != 1 or not manifest.get("repositoryID"):
        raise RuntimeError("Invalid snapshot manifest")
    names = set()
    for item in manifest["files"]:
        path = Path(item["path"])
        if path.is_absolute() or ".." in path.parts or "\\" in str(path) or str(path) in names:
            raise RuntimeError("Invalid snapshot path")
        names.add(path.as_posix())
        target = output / "repository" / path
        if any(p.is_symlink() for p in [target, *target.parents]):
            raise RuntimeError("Symbolic link in snapshot")
        data = target.read_bytes()
        if len(data) != item["bytes"] or hashlib.sha256(data).hexdigest() != item["sha256"]:
            raise RuntimeError("Snapshot file differs from source manifest")
    actual = {p.relative_to(output / "repository").as_posix()
              for p in (output / "repository").rglob("*") if p.is_file()}
    if actual != names:
        raise RuntimeError("Unexpected snapshot file")
    with sqlite3.connect((output / "cloud.sqlite").resolve().as_uri() + "?mode=ro", uri=True) as db:
        if db.execute("PRAGMA quick_check").fetchall() != [("ok",)]:
            raise RuntimeError("Snapshot database integrity check failed")


def main():
    now = dt.datetime.now(dt.timezone.utc)
    parent = BASE / "backups"
    parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    output = parent / (now.strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8])
    subprocess.run([BINARY, "backup", "--repository", str(BASE / "repository"),
                    "--state", str(BASE / "state"), "--output", str(output)], check=True)
    verify_snapshot(output)
    entries = []
    for path in sorted(output.rglob("*")):
        if path.is_symlink():
            raise RuntimeError("Unexpected symbolic link in backup")
        if path.is_file():
            h = hashlib.sha256()
            with path.open("rb") as source:
                for chunk in iter(lambda: source.read(1024 * 1024), b""):
                    h.update(chunk)
            entries.append({"path": path.relative_to(output).as_posix(), "sha256": h.hexdigest(), "bytes": path.stat().st_size})
    if not entries:
        raise RuntimeError("Empty backup")
    receipt = {"version": 1, "createdAt": now.isoformat(), "files": entries}
    target = output / "verified-backup.json"
    with target.open("x") as f:
        json.dump(receipt, f, ensure_ascii=False)
        f.flush()
        os.fsync(f.fileno())
    cutoff = now - dt.timedelta(days=30)
    for candidate in parent.iterdir():
        if candidate == output or candidate.is_symlink() or not candidate.is_dir():
            continue
        marker = candidate / "verified-backup.json"
        try:
            meta = json.loads(marker.read_text())
            created = dt.datetime.fromisoformat(meta["createdAt"])
            if meta.get("version") == 1 and created < cutoff:
                shutil.rmtree(candidate)
        except (OSError, ValueError, KeyError, TypeError):
            # Never prune an incomplete or unrecognized directory automatically.
            continue
    print(json.dumps({"backup": output.name, "files": len(entries), "verified": True}))


if __name__ == "__main__":
    main()
