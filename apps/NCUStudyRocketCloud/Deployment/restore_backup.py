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


def attachment_path(name: str) -> bool:
    parts = PurePosixPath(name).parts
    if len(parts) != 3 or parts[0] != "attachments":
        return False
    if parts[1] == "objects":
        return bool(HASH.fullmatch(parts[2]))
    if parts[1] == "records" and parts[2].endswith(".json"):
        try:
            return str(uuid.UUID(parts[2][:-5])).lower() == parts[2][:-5].lower()
        except ValueError:
            return False
    return False


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


def validate_attachment_record(ident, body):
    """Validate SQLite authority before any path may be derived from its fields.

    Checksums establish byte identity, not that those bytes are safe metadata.
    Keep this boundary aligned with CloudStore's attachment admission contract.
    """
    if (not isinstance(ident, str) or len(ident) != 36
            or str(uuid.UUID(ident)).lower() != ident.lower()
            or not isinstance(body, str) or len(body.encode("utf-8")) > 65536):
        raise ValueError("Invalid attachment record identity or size")
    def unique_object(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("Duplicate attachment metadata key")
            result[key] = value
        return result
    record = json.loads(body, object_pairs_hook=unique_object)
    if not isinstance(record, dict) or not isinstance(record.get("attachment"), dict):
        raise ValueError("Invalid attachment record")
    attachment = record["attachment"]
    filename, mime = attachment.get("filename"), attachment.get("mimeType")
    size, uploaded = attachment.get("byteCount"), attachment.get("uploadedBytes")
    if (attachment.get("id") != ident
            or not isinstance(attachment.get("sha256"), str)
            or not HASH.fullmatch(attachment["sha256"])
            or not isinstance(record.get("createHash"), str)
            or not HASH.fullmatch(record["createHash"])
            or not isinstance(filename, str) or not filename or len(filename.encode("utf-8")) > 255
            or "/" in filename or "\\" in filename or any(ord(c) < 32 for c in filename)
            or not isinstance(mime, str) or not re.fullmatch(r"[A-Za-z0-9/.+\-]{1,150}", mime)
            or type(size) is not int or size <= 0
            or type(uploaded) is not int or not 0 <= uploaded <= size
            or attachment.get("state") not in {"uploading", "processing", "ready", "unknown", "failed", "removed", "expired"}
            or type(record.get("uploadStarted")) is not bool):
        raise ValueError("Invalid attachment metadata")
    extension = filename.rsplit(".", 1)[-1].lower() if "." in filename else ""
    images = {"jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "gif": "image/gif", "webp": "image/webp"}
    documents = {"pdf": "application/pdf", "doc": "application/msword",
                 "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                 "ppt": "application/vnd.ms-powerpoint",
                 "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation"}
    texts = {"txt", "md", "csv", "json", "tsv", "xlsx", "xls", "epub", "mobi"}
    purpose, limit = "user_data", 32 * 1024 * 1024
    if extension in images:
        if mime != images[extension]:
            raise ValueError("Attachment image MIME mismatch")
        limit = 20 * 1024 * 1024
    elif extension in documents:
        if mime != documents[extension]:
            raise ValueError("Attachment document MIME mismatch")
        purpose, limit = "rich_layout_recognition", 100 * 1024 * 1024
    elif extension not in texts:
        raise ValueError("Unsupported attachment format")
    if (size > limit or record.get("purpose") != purpose
            or record.get("providerFilename") != ident + "." + extension):
        raise ValueError("Invalid attachment purpose, provider filename or byte limit")
    dates = [attachment.get("expiresAt")]
    dates.extend(record[name] for name in ("providerExpiresAt", "sentAt") if record.get(name) is not None)
    def finite_date(value):
        try:
            return type(value) in (int, float) and math.isfinite(value)
        except OverflowError:
            return False
    if not all(finite_date(value) for value in dates):
        raise ValueError("Invalid attachment date")
    now = dt.datetime.now(dt.timezone.utc).timestamp() - 978307200
    expiry, sent, provider_expiry = attachment["expiresAt"], record.get("sentAt"), record.get("providerExpiresAt")
    if (expiry > now + 30 * 86400 + 300
            or sent is not None and (sent > now + 300 or expiry > sent + 30 * 86400)
            or provider_expiry is not None and (provider_expiry > now + 30 * 86400 + 300 or expiry > provider_expiry)):
        raise ValueError("Invalid attachment retention boundary")
    # Provider-side conversion (for example XLSX to Markdown) can change the
    # size. It must never redefine the immutable original byteCount/hash.
    provider_size = record.get("providerByteCount")
    if provider_size is not None and (type(provider_size) is not int or not 0 <= provider_size <= 9_007_199_254_740_991):
        raise ValueError("Invalid attachment provider byte count")
    provider = record.get("providerFileID")
    if provider is not None and (not isinstance(provider, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,200}", provider)):
        raise ValueError("Invalid attachment provider identity")
    if attachment.get("issue") is not None and (not isinstance(attachment["issue"], str) or len(attachment["issue"].encode("utf-8")) > 4000):
        raise ValueError("Invalid attachment issue")
    if attachment["state"] == "ready" and (provider is None or provider_expiry is None or not record["uploadStarted"] or uploaded != size):
        raise ValueError("Incomplete ready attachment")
    return record


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
        if database.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='attachments'").fetchone():
            # Validate every row, including expired/removed rows whose originals
            # are intentionally absent from the snapshot inventory.
            if database.execute("SELECT 1 FROM attachments WHERE typeof(body)!='text' OR length(CAST(body AS BLOB))>65536 LIMIT 1").fetchone():
                raise ValueError("Invalid attachment record size")
            for ident, body in database.execute("SELECT id,body FROM attachments"):
                validate_attachment_record(ident, body)
                mirror = path.parent / "attachments" / "records" / (ident + ".json")
                if mirror.exists():
                    no_symlinks(mirror)
                    if mirror.read_bytes() != body.encode("utf-8"):
                        raise ValueError("Attachment database and metadata mirror disagree")


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
        raw_entries = receipt["files"]
        entries = file_entries(raw_entries)
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
        raw_entries = [{"path": item["path"], "bytes": item["byteCount"],
                                 "sha256": item["sha256"],
                                 **({"expiresAt": item["expiresAt"] + 978307200} if item.get("expiresAt") is not None else {})} for item in files]
        entries = file_entries(raw_entries)
    now = dt.datetime.now(dt.timezone.utc).timestamp()
    expired = set()
    for item in raw_entries:
        name = item["path"]
        expiry = item.get("expiresAt")
        if attachment_path(name):
            if type(expiry) not in (int, float) or not math.isfinite(expiry):
                raise ValueError("Missing attachment expiration")
            if expiry <= now:
                expired.add(name)
        elif expiry is not None:
            raise ValueError("Unexpected file expiry")
    if set(entries) - expired != actual - {marker} - expired:
        raise ValueError("Receipt inventory differs from backup files")
    if not {"manifest.json", "cloud.sqlite"}.issubset(entries):
        raise ValueError("Backup lacks its manifest or SQLite snapshot")
    entries = {name: value for name, value in entries.items() if name not in expired}
    for name, expected in entries.items():
        if name not in {"manifest.json", "cloud.sqlite"}:
            if not attachment_path(name) and (not name.startswith("repository/") or not academic_path(name[len("repository/"):])):
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
    attachment_entries = manifest.get("attachmentFiles", [])
    declared = {}
    for item in attachment_entries:
        name = relative_name(item["path"])
        if not attachment_path(name) or name in declared or type(item.get("expiresAt")) not in (int, float) or not math.isfinite(item["expiresAt"]):
            raise ValueError("Invalid attachment snapshot inventory")
        if item["expiresAt"] > now:
            declared[name] = (item["bytes"], item["sha256"])
    # Mac receipts intentionally omit already-expired attachment objects.
    if declared != {name: value for name, value in entries.items() if attachment_path(name)}:
        raise ValueError("Attachment manifest differs from verification receipt")
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
        target_name = "state/" + name if name == "cloud.sqlite" or attachment_path(name) else name
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
    # An attachment restored after its deadline must never be revived by the
    # service rebuilding its records mirror from the SQLite authority.
    database_path = destination / "state/cloud.sqlite"
    with sqlite3.connect(database_path) as database:
        has_attachments = database.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='attachments'").fetchone()
        if has_attachments:
            now = dt.datetime.now(dt.timezone.utc).timestamp()
            for ident, body in database.execute("SELECT id,body FROM attachments").fetchall():
                record = validate_attachment_record(ident, body)
                attachment = record["attachment"]
                expiry = attachment["expiresAt"] + 978307200
                record_path = destination / "state/attachments/records" / (str(uuid.UUID(ident)) + ".json")
                # UUID casing is preserved by Swift on disk.
                record_path = record_path.with_name(ident + ".json")
                if expiry <= now or not record_path.is_file():
                    attachment["state"] = "expired"
                    record["providerFileID"] = None
                    record["uploadStarted"] = False
                    database.execute("UPDATE attachments SET body=? WHERE id=?", (json.dumps(record, separators=(",", ":")), ident))
            database.commit()
    length, digest = fingerprint(database_path)
    mappings["state/cloud.sqlite"] = {"bytes": length, "sha256": digest}
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
