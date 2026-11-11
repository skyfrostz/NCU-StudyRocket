#!/usr/bin/env python3
"""Synthetic export safety checks. Never reads the user's Codex database or files."""
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent

def load(name):
    spec = importlib.util.spec_from_file_location(name, HERE / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

history, workspace = load("export_history"), load("export_workspace")


def event(kind, payload, stamp="2001-01-01T00:00:00Z"):
    return {"timestamp": stamp, "type": kind, "payload": payload}


def modern(text, ident="item-1", role="UserMessage", stamp="2001-01-01T00:00:00Z", phase=None):
    return event("event_msg", {"type": "item_completed", "item": {"type": role, "id": ident, "content": [{"type": "text", "text": text}], "phase": phase}}, stamp)


def raw(*items):
    return "\n".join(json.dumps(item) for item in items)


class ExportTests(unittest.TestCase):
    def test_mixed_formats_keep_unmirrored_visible_messages(self):
        rows, _ = history.parse_messages(raw(
            event("event_msg", {"type": "user_message", "message": "legacy question"}),
            modern("new answer", role="AgentMessage", stamp="2001-01-01T00:00:03Z"),
            event("response_item", {"type": "message", "role": "assistant", "content": "response-only answer"}, "2001-01-01T00:00:05Z")), "thread")
        self.assertEqual([x["text"] for x in rows], ["legacy question", "new answer", "response-only answer"])
        self.assertEqual(rows[0]["date"], 0)

    def test_mirrors_do_not_duplicate_images_or_citation_metadata(self):
        rows, _ = history.parse_messages(raw(
            modern("question", ident="user"),
            event("response_item", {"type": "message", "role": "user", "content": "question\n<image attachment='synthetic'>metadata</image>"}),
            modern("answer", ident="assistant", role="AgentMessage"),
            event("response_item", {"type": "message", "role": "assistant", "id": "assistant", "content": "answer<oai-mem-citation>metadata</oai-mem-citation>"})), "thread")
        self.assertEqual(len(rows), 2)
        self.assertEqual({x["text"] for x in rows}, {"question", "answer"})

    def test_repeated_real_messages_and_missing_ids_are_preserved(self):
        rows, _ = history.parse_messages(raw(modern("same", None), modern("same", None),
            event("event_msg", {"type": "user_message", "message": "same"}, "2001-01-01T01:00:00Z")), "thread")
        self.assertEqual(len(rows), 3)
        self.assertEqual(len({x["id"] for x in rows}), 3)
        extra = event("turn_context", {"synthetic": True})
        reordered, _ = history.parse_messages(raw(extra, modern("same", None), modern("same", None),
            event("event_msg", {"type": "user_message", "message": "same"}, "2001-01-01T01:00:00Z")), "thread")
        self.assertEqual(rows, reordered)

    def test_conflicting_source_id_fails(self):
        with self.assertRaises(ValueError):
            history.parse_messages(raw(modern("first"), modern("changed")), "thread")

    def test_internal_text_and_reasoning_do_not_export(self):
        items = [modern("reason", role="AgentMessage", phase="analysis"),
            event("response_item", {"type": "message", "role": "assistant", "phase": "reasoning", "content": "private"})]
        for prefix in history.INFRASTRUCTURE_PREFIXES:
            items.append(event("response_item", {"type": "message", "role": "user", "content": prefix + " synthetic"}))
        rows, _ = history.parse_messages(raw(*items), "thread")
        self.assertEqual(rows, [])

    def test_credentials_redacted_and_workspace_rejected(self):
        secrets = ["sk-" + "a" * 30, "AKIA" + "A" * 16, "Bearer synthetic-token-value",
                   '"api_key": "synthetic-private-value"', "DEEPSEEK_API_KEY=synthetic-private-value",
                   "password=synthetic-private-value", "eyJtest.abcdefgh.signature"]
        for secret in secrets:
            rows, count = history.parse_messages(raw(modern(secret)), "thread")
            self.assertGreater(count, 0)
            self.assertNotIn(secret, rows[0]["text"])
            self.assertIsNotNone(workspace.SECRET.search(secret))

    def test_ambiguous_or_missing_timestamp_fails(self):
        for stamp in (None, "2001-01-01T00:00:00"):
            with self.assertRaises(ValueError):
                history.parse_messages(raw(modern("visible", stamp=stamp)), "thread")

    @unittest.skipUnless(shutil.which("zstd"), "zstd is required for compressed fixture")
    def test_source_tagged_scope_compression_and_missing_index(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp); codex = base / "codex"; codex.mkdir(); repo = base / "repo"; repo.mkdir()
            contents = raw(event("session_meta", {"id": "academic", "cwd": str(repo), "source": "vscode"}), modern("synthetic academic"))
            plain = codex / "rollout.jsonl"; plain.write_text(contents)
            subprocess.run(["zstd", "-q", str(plain), "-o", str(plain) + ".zst"], check=True)
            plain.unlink()
            with sqlite3.connect(codex / "state_5.sqlite") as db:
                db.execute("CREATE TABLE threads(id,rollout_path,has_user_event,tokens_used,cwd,thread_source,created_at)")
                db.executemany("INSERT INTO threads VALUES(?,?,?,?,?,?,?)", [
                    ("academic", str(plain), 1, 10, str(repo), "studyrocket", 1),
                    ("development", str(codex / "must-not-read"), 1, 10, str(repo), "cli", 2),
                    ("other-repo", str(codex / "must-not-read"), 1, 10, str(base / "other"), "studyrocket", 3),
                    ("empty", str(codex / "missing"), 0, 0, str(repo), "studyrocket", 4)])
            result = history.export(codex, repo, base / "output")
            self.assertEqual(result["sourceCount"], 1)
            self.assertEqual(result["messageCount"], 1)
            self.assertEqual(result["missingNonemptyCount"], 0)
            manifest = json.loads((base / "output/history-manifest.json").read_text())
            self.assertTrue(manifest["completeVisibleSources"])
            self.assertFalse((base / "output/INCOMPLETE").exists())
            with sqlite3.connect(codex / "state_5.sqlite") as db:
                db.execute("UPDATE threads SET id='wrong-identity' WHERE id='academic'")
            with self.assertRaises(ValueError):
                history.export(codex, repo, base / "rejected")

    def make_repo(self, base):
        root = base / "repo"; root.mkdir()
        (root / "PROFILE.md").write_text("# Synthetic profile\n")
        (root / "AGENTS.md").write_text("# Synthetic instructions\n")
        (root / "apps").mkdir(); (root / "apps/excluded.md").write_text("development text")
        return root

    def test_workspace_allowlist_modes_hashes_and_extra_symlink(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp); root = self.make_repo(base); target = base / "export"
            manifest = workspace.export(root, target, None)
            self.assertEqual(len(manifest["files"]), 2)
            self.assertEqual(workspace.verify(target), manifest)
            manifest["files"][0]["mode"] = "writable"
            (target / "manifest.json").write_text(json.dumps(manifest))
            with self.assertRaises(ValueError): workspace.verify(target)
            manifest["files"][0]["mode"] = "readOnly"
            (target / "manifest.json").write_text(json.dumps(manifest))
            (target / "repository/unexpected").symlink_to(root, target_is_directory=True)
            with self.assertRaises(ValueError): workspace.verify(target)

    def test_workspace_membership_changes_abort_snapshot(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp); root = self.make_repo(base); original = workspace.candidates; calls = 0
            def changing(source):
                nonlocal calls
                calls += 1
                if calls == 2: (source / "校历与重要日期.md").write_text("new concurrent file")
                return original(source)
            with patch.object(workspace, "candidates", changing), self.assertRaises(ValueError):
                workspace.export(root, base / "export", None)
            self.assertFalse((base / "export").exists())


if __name__ == "__main__":
    unittest.main()
