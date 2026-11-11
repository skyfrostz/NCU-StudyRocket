#!/usr/bin/env python3
"""Synthetic restore safety checks; never reads a user repository or production path."""
import hashlib
import argparse
import datetime
import importlib.util
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import uuid

SCRIPT = Path(__file__).resolve().parent.parent / 'Deployment/restore_backup.py'
SPEC = importlib.util.spec_from_file_location('restore_backup', SCRIPT)
RESTORE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RESTORE)


class RestoreAcceptance(unittest.TestCase):
    binary = None

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='studyrocket-restore-qa-')
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name).resolve()
        self.backup = self.base / 'backup'
        self.backup.mkdir()
        self.destination = self.base / 'restored'
        self.repository_id = str(uuid.uuid4())
        self.repository = self.backup / 'repository'
        (self.repository / '笔记').mkdir(parents=True)
        (self.repository / 'PROFILE.md').write_text('# Synthetic profile\n')
        (self.repository / '笔记/a.md').write_text('Synthetic original 中文\n')
        with sqlite3.connect(self.backup / 'cloud.sqlite') as database:
            database.execute('CREATE TABLE kv(key TEXT PRIMARY KEY,value TEXT)')
            database.execute('CREATE TABLE operations(id TEXT,state TEXT)')
            database.execute('INSERT INTO kv VALUES (?,?)', ('repositoryID', self.repository_id))
            database.execute('INSERT INTO operations VALUES (?,?)', ('synthetic-receipt', 'succeeded'))
        files = [self.entry(path, self.repository) for path in sorted(self.repository.rglob('*.md'))]
        (self.backup / 'manifest.json').write_text(json.dumps({'version': 1, 'repositoryID': self.repository_id, 'files': files}))
        self.receipt()

    @staticmethod
    def entry(path, root):
        data = path.read_bytes()
        return {'path': path.relative_to(root).as_posix(), 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}

    def receipt(self):
        entries = [self.entry(path, self.backup) for path in sorted(self.backup.rglob('*'))
                   if path.is_file() and path.name != 'verified-backup.json']
        (self.backup / 'verified-backup.json').write_text(json.dumps({'version': 1, 'createdAt': '2026-11-11T00:00:00+00:00', 'files': entries}))

    def rejected(self, backup=None, destination=None, repository_id=None):
        destination = destination or self.destination
        with self.assertRaises((ValueError, OSError, sqlite3.DatabaseError)):
            RESTORE.restore(backup or self.backup, destination, repository_id)
        self.assertFalse(destination.exists(), 'Preflight rejection must not create a destination')

    def test_cli_restores_exact_files_database_identity_and_receipts(self):
        before = {str(p.relative_to(self.backup)): p.read_bytes() for p in self.backup.rglob('*') if p.is_file()}
        result = subprocess.run([sys.executable, str(SCRIPT), '--backup', str(self.backup),
                                 '--destination', str(self.destination), '--expected-repository-id', self.repository_id],
                                capture_output=True, text=True, check=True)
        self.assertFalse(json.loads(result.stdout)['liveSwitchPerformed'])
        self.assertEqual((self.destination / 'repository/笔记/a.md').read_bytes(), before['repository/笔记/a.md'])
        self.assertEqual((self.destination / 'state/cloud.sqlite').read_bytes(), before['cloud.sqlite'])
        with sqlite3.connect(self.destination / 'state/cloud.sqlite') as database:
            self.assertEqual(database.execute('SELECT state FROM operations').fetchone(), ('succeeded',))
        self.assertFalse((self.destination / 'RESTORE_INCOMPLETE').exists())
        self.assertEqual({str(p.relative_to(self.backup)): p.read_bytes() for p in self.backup.rglob('*') if p.is_file()}, before)
        self.assertEqual((self.destination / 'state/cloud.sqlite').stat().st_mode & 0o777, 0o600)

    def test_existing_destination_is_never_replaced(self):
        self.destination.mkdir()
        sentinel = self.destination / 'keep'; sentinel.write_text('untouched')
        with self.assertRaises(ValueError): RESTORE.restore(self.backup, self.destination)
        self.assertEqual(sentinel.read_text(), 'untouched')

    def mac_receipt(self):
        source = json.loads((self.backup / 'verified-backup.json').read_text())
        (self.backup / 'verified-backup.json').unlink()
        receipt = {'id': '20261111T000000Z-mac', 'createdAt': 816134400,
                   'files': [{'path': item['path'], 'byteCount': item['bytes'], 'sha256': item['sha256']}
                             for item in source['files']]}
        (self.backup / '_download-receipt.json').write_text(json.dumps(receipt))

    def test_mac_download_can_restore_without_server_disk(self):
        self.mac_receipt()
        result = RESTORE.restore(self.backup, self.destination, self.repository_id)
        self.assertEqual(result['repositoryID'], self.repository_id)
        self.assertEqual((self.destination / 'repository/笔记/a.md').read_text(), 'Synthetic original 中文\n')
        self.assertFalse(result['liveSwitchPerformed'])
        self.assertFalse((self.destination / 'RESTORE_INCOMPLETE').exists())

    def test_mac_download_rejects_tamper_and_unlisted_files(self):
        self.mac_receipt()
        target = self.repository / '笔记/a.md'; original = target.read_bytes()
        target.write_text('tampered'); self.rejected(); target.write_bytes(original)
        (self.backup / 'unexpected').write_text('unlisted'); self.rejected()

    def test_mac_download_rejects_invalid_receipt_or_ambiguous_markers(self):
        self.mac_receipt()
        path = self.backup / '_download-receipt.json'; original = path.read_text()
        receipt = json.loads(original); receipt['createdAt'] = float('nan')
        path.write_text(json.dumps(receipt)); self.rejected(); path.write_text(original)
        (self.backup / 'verified-backup.json').write_text('{}'); self.rejected()

    def test_symlink_backup_argument_is_rejected(self):
        alias = self.base / 'alias'; alias.symlink_to(self.backup, target_is_directory=True)
        self.rejected(backup=alias)

    def test_symlink_inside_backup_is_rejected(self):
        target = self.repository / '笔记/a.md'; target.unlink(); target.symlink_to(self.repository / 'PROFILE.md')
        self.rejected()

    def test_symlink_destination_parent_is_rejected(self):
        alias = self.base / 'alias'; alias.symlink_to(self.base, target_is_directory=True)
        self.rejected(destination=alias / 'restored')

    def test_changed_file_and_receipt_mismatch_are_rejected(self):
        (self.repository / '笔记/a.md').write_text('changed after verified backup')
        self.rejected()

    def test_changed_manifest_even_with_new_receipt_is_rejected(self):
        path = self.backup / 'manifest.json'; manifest = json.loads(path.read_text())
        manifest['files'][0]['sha256'] = '0' * 64
        path.write_text(json.dumps(manifest)); self.receipt()
        self.rejected()

    def test_sqlite_damage_even_with_matching_receipt_is_rejected(self):
        (self.backup / 'cloud.sqlite').write_bytes(b'not a database')
        self.receipt()
        self.rejected()

    def test_wrong_repository_and_unrecovered_journal_are_rejected(self):
        self.rejected(repository_id=str(uuid.uuid4()))
        with sqlite3.connect(self.backup / 'cloud.sqlite') as database:
            database.execute("UPDATE operations SET state='prepared'")
        self.receipt()
        self.rejected()

    def test_unlisted_file_and_path_traversal_are_rejected(self):
        extra = self.backup / 'unlisted.txt'; extra.write_text('unlisted')
        self.rejected()
        extra.unlink()
        path = self.backup / 'verified-backup.json'; receipt = json.loads(path.read_text())
        receipt['files'][0]['path'] = '../outside.md'
        path.write_text(json.dumps(receipt))
        self.rejected()

    def test_copy_failure_keeps_incomplete_destination_without_success_receipt(self):
        with patch.object(RESTORE.shutil, 'copyfileobj', side_effect=OSError('synthetic disk failure')):
            with self.assertRaises(OSError): RESTORE.restore(self.backup, self.destination)
        self.assertTrue((self.destination / 'RESTORE_INCOMPLETE').is_file())
        self.assertFalse((self.destination / 'restore-receipt.json').exists())

    def test_actual_cloud_snapshot_restores_pairing_and_idempotent_receipt(self):
        if self.binary is None: self.skipTest('Pass --binary to include the actual cloud snapshot round trip')
        import cloud_acceptance as cloud
        fixture = cloud.Fixture(self.binary)
        self.addCleanup(fixture.close)
        fixture.start(); fixture.pair()
        request = fixture.commit_request({'笔记/a.md': 'actual cloud backup restore fixture\n'})
        status, receipt = fixture.request('POST', '/v1/files/commit', request)
        self.assertEqual(status, 200, receipt)
        backup = fixture.base / 'backup-for-restore'
        fixture.cli('backup', '--repository', str(fixture.repo), '--state', str(fixture.state), '--output', str(backup))
        files = [self.entry(path, backup) for path in backup.rglob('*') if path.is_file()]
        (backup / 'verified-backup.json').write_text(json.dumps({'version': 1, 'createdAt': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'files': files}))
        destination = fixture.base.resolve() / 'restored-cloud'
        RESTORE.restore(backup.resolve(), destination, request['repositoryID'])
        fixture.stop()
        fixture.repo, fixture.state = destination / 'repository', destination / 'state'
        fixture.start()
        self.assertEqual(fixture.manifest()['repositoryID'], request['repositoryID'])
        self.assertEqual(fixture.request('POST', '/v1/files/commit', request), (status, receipt))
        self.assertEqual((fixture.repo / '笔记/a.md').read_text(), 'actual cloud backup restore fixture\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary')
    arguments, remaining = parser.parse_known_args()
    RestoreAcceptance.binary = arguments.binary
    unittest.main(argv=[__file__, *remaining], verbosity=2)
