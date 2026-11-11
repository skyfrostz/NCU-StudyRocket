#!/usr/bin/env python3
"""Export visible, source-tagged academic messages; never copy raw rollouts."""
from __future__ import annotations

import argparse
import collections
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess

SWIFT_EPOCH = 978307200
REDACTIONS = [
    re.compile(r"-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----.*?-----END (?:[A-Z ]+ )?PRIVATE KEY-----", re.S),
    re.compile(r"\b(?:sk-[A-Za-z0-9_-]{20,}|LTAI[A-Za-z0-9]{12,})\b"),
    re.compile(r"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"),
    re.compile(r"\b(?:AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AIza[A-Za-z0-9_-]{30,})\b"),
    re.compile(r"(?i)\b(?:Bearer|Basic)\s+[A-Za-z0-9+/_.=-]{8,}"),
    re.compile(r"(?i)[\"']?(?:[a-z][a-z0-9_]*_)?(?:api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|secret[_-]?key|password|passwd|authorization|token)[\"']?\s*[:=]\s*[\"']?[^\s\"'`;,}]{4,}"),
    re.compile(r"(?i)(?:https?://[^\s<>]*[?&](?:token|code|secret|password|access_key|signature)=)[^\s<>]+"),
]


def content_text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(part["text"] for part in content if isinstance(part, dict)
                         and part.get("type", "").lower() in ("text", "input_text", "output_text")
                         and isinstance(part.get("text"), str))
    return ""


INFRASTRUCTURE_PREFIXES = (
    "# AGENTS.md instructions", "<environment_context>", "<permissions instructions>",
    "<turn_aborted>", "<recommended_plugins>", "<external_codex_apps_open_page>",
    "<system_reminder>", "<skills_instructions>", "<app-context>", "<collaboration_mode>",
)


def parse_messages(raw: str, thread: str):
    groups = {"modern": [], "legacy": [], "response": []}
    occurrence = collections.Counter()
    for line in raw.splitlines():
        if not line.strip():
            continue
        event = json.loads(line)  # Truncated sources fail rather than lose text.
        payload = event.get("payload", {})
        if not isinstance(payload, dict):
            continue
        kind, source_id, role, text = None, None, None, ""
        if event.get("type") == "event_msg" and payload.get("type") == "item_completed":
            item = payload.get("item", {})
            if not isinstance(item, dict):
                raise ValueError("Malformed completed item")
            role = {"UserMessage": "user", "AgentMessage": "assistant"}.get(item.get("type"))
            if role and item.get("phase") not in ("analysis", "reasoning"):
                kind, source_id, text = "modern", item.get("id"), content_text(item.get("content"))
        elif event.get("type") == "event_msg" and payload.get("type") in ("user_message", "agent_message"):
            if payload.get("phase") not in ("analysis", "reasoning") and payload.get("channel") not in ("analysis", "reasoning"):
                kind, source_id = "legacy", payload.get("id")
                role = "user" if payload["type"] == "user_message" else "assistant"
                text = content_text(payload.get("message"))
        elif event.get("type") == "response_item" and payload.get("type") == "message":
            role = payload.get("role")
            if role in ("user", "assistant") and payload.get("channel") not in ("analysis", "reasoning") and payload.get("phase") not in ("analysis", "reasoning"):
                text = content_text(payload.get("content"))
                if not text.lstrip().startswith(INFRASTRUCTURE_PREFIXES):
                    kind, source_id = "response", payload.get("id")
        if kind is None or not text.strip():
            continue
        timestamp = event.get("timestamp")
        if not isinstance(timestamp, str):
            raise ValueError("A visible message has no source timestamp")
        date = dt.datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
        if date.tzinfo is None:
            raise ValueError("A visible message has an ambiguous source timezone")
        stamp = date.timestamp()
        supplied_id = bool(source_id)
        if not supplied_id:
            # Infrastructure lines can be added/compacted without changing visible IDs.
            seed = (role, text, stamp)
            ordinal = occurrence[(kind, seed)]
            occurrence[(kind, seed)] += 1
            source_id = "visible-" + hashlib.sha256(json.dumps([*seed, ordinal], ensure_ascii=False).encode()).hexdigest()
        groups[kind].append((str(source_id), role, text, stamp, supplied_id))

    chosen = []
    for group in groups.values():
        matched = set()
        prior = list(chosen)
        for candidate in group:
            source_id, role, text, stamp, supplied_id = candidate
            duplicate = None
            for index, previous in enumerate(prior):
                if index in matched or previous[1] != role:
                    continue
                if supplied_id and previous[4] and source_id == previous[0]:
                    duplicate = index
                    break
                # Response items mirror visible events within milliseconds. Restrict
                # time matching so a repeated question in a later legacy turn survives.
                if abs(stamp - previous[3]) > 0.05:
                    continue
                comparable = re.sub(r"<oai-mem-citation>.*?</oai-mem-citation>", "", text, flags=re.S).strip()
                previous_text = re.sub(r"<oai-mem-citation>.*?</oai-mem-citation>", "", previous[2], flags=re.S).strip()
                image_copy = role == "user" and comparable.startswith(previous_text) and bool(re.search(r"<image(?:\s|>)", comparable[len(previous_text):]))
                if comparable == previous_text or image_copy:
                    duplicate = index
                    break
            if duplicate is not None:
                matched.add(duplicate)
            else:
                chosen.append(candidate)
    seen = {}
    output = []
    redactions = 0
    for source_id, role, text, stamp, _ in chosen:
        ident = hashlib.sha256((thread + "\0" + source_id + "\0" + role).encode()).hexdigest()
        if ident in seen:
            if seen[ident] != text:
                raise ValueError("A source message identity has conflicting text")
            continue
        seen[ident] = text
        for pattern in REDACTIONS:
            text, count = pattern.subn("[credential omitted]", text)
            redactions += count
        output.append({"id": ident, "sourceThreadID": thread, "role": role, "text": text,
                       "date": stamp - SWIFT_EPOCH, "source": "codex-import"})
    output.sort(key=lambda item: (item["date"], item["id"]))
    return output, redactions


def export(codex: Path, repository: Path, destination: Path):
    if destination.exists():
        raise ValueError("Destination exists; select a fresh export directory")
    with sqlite3.connect((codex / "state_5.sqlite").as_uri() + "?mode=ro", uri=True) as db:
        rows = db.execute("SELECT id,rollout_path,has_user_event,tokens_used FROM threads "
                          "WHERE cwd=? AND thread_source='studyrocket' ORDER BY created_at,id",
                          (str(repository),)).fetchall()
    if not rows:
        raise ValueError("No explicitly tagged academic conversations found")
    records, sources, missing = [], [], []
    source_stats = []
    for thread, rollout_path, has_user, tokens in rows:
        path = Path(rollout_path)
        if not path.exists():
            path = Path(rollout_path + ".zst")
        if not path.exists():
            # Preserve missing index evidence, including known empty probes.
            missing.append({"sourceThreadID": thread, "hasUserEvent": bool(has_user),
                            "tokensUsed": tokens, "emptyIndex": not has_user and tokens == 0})
            continue
        before = path.stat()
        raw = subprocess.run(["zstd", "-dc", str(path)], capture_output=True, check=True).stdout.decode("utf-8") \
            if path.suffix == ".zst" else path.read_text(encoding="utf-8")
        metadata = [event.get("payload", {}) for event in (json.loads(line) for line in raw.splitlines() if line.strip()) if event.get("type") == "session_meta"]
        if len(metadata) != 1 or metadata[0].get("id") != thread or Path(metadata[0].get("cwd", "")).resolve() != repository.resolve():
            raise ValueError("Academic index and rollout identity/scope do not match")
        parsed, redactions = parse_messages(raw, thread)
        after = path.stat()
        identity = lambda stat: (stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns)
        if identity(before) != identity(after):
            raise ValueError("Academic source changed during export; retry after its turn finishes")
        source_stats.append((path, identity(after)))
        records.extend(parsed)
        sources.append({"sourceThreadID": thread, "rolloutSHA256": hashlib.sha256(raw.encode()).hexdigest(),
                        "messageCount": len(parsed), "redactions": redactions,
                        "roles": dict(collections.Counter(item["role"] for item in parsed))})
    records.sort(key=lambda item: (item["date"], item["sourceThreadID"], item["id"]))
    if len({r["id"] for r in records}) != len(records):
        raise ValueError("Duplicate source message identity")
    for path, expected in source_stats:
        if identity(path.stat()) != expected:
            raise ValueError("An academic source changed during the export set")
    destination.mkdir(parents=True, mode=0o700)
    incomplete = destination / "INCOMPLETE"
    incomplete.write_text("Export has not passed final consistency checks.\n")
    os.chmod(incomplete, 0o600)
    data = "".join(json.dumps(r, ensure_ascii=False) + "\n" for r in records).encode()
    for name, payload in {
        "history.jsonl": data,
        "history-manifest.json": (json.dumps({"version": 1, "messageCount": len(records),
            "historySHA256": hashlib.sha256(data).hexdigest(), "sources": sources,
            "missingSources": missing, "completeVisibleSources": not any(not x["emptyIndex"] for x in missing)},
            ensure_ascii=False, indent=2) + "\n").encode()
    }.items():
        with os.fdopen(os.open(destination / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb") as f:
            f.write(payload)
            f.flush()
            os.fsync(f.fileno())
    for path, expected in source_stats:
        if identity(path.stat()) != expected:
            raise ValueError("An academic source changed before export completion")
    incomplete.unlink()
    return {"sourceCount": len(sources), "messageCount": len(records), "missingIndexCount": len(missing),
            "missingNonemptyCount": sum(not x["emptyIndex"] for x in missing),
            "redactions": sum(s["redactions"] for s in sources)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex-home", type=Path, required=True)
    parser.add_argument("--repository", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(export(args.codex_home.resolve(), args.repository.absolute(), args.destination.resolve())))
