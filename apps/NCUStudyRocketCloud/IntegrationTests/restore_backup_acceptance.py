#!/usr/bin/env python3
"""Synthetic restore safety checks; never reads a user repository or production path."""
import hashlib
import copy
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

    def attachment(self, expired=False):
        data = b"synthetic attachment contents"
        digest = hashlib.sha256(data).hexdigest()
        path = self.backup / "attachments" / "objects" / digest
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        expiry = datetime.datetime.now(datetime.timezone.utc).timestamp() + (-60 if expired else 86400)
        entry = {**self.entry(path, self.backup), "expiresAt": expiry}
        manifest_path = self.backup / 'manifest.json'
        manifest = json.loads(manifest_path.read_text()); manifest['attachmentFiles'] = [entry]
        manifest_path.write_text(json.dumps(manifest))
        self.receipt()
        receipt_path = self.backup / 'verified-backup.json'
        receipt = json.loads(receipt_path.read_text())
        for item in receipt['files']:
            if item['path'] == entry['path']:
                item['expiresAt'] = expiry
        receipt_path.write_text(json.dumps(receipt))
        return path

    def test_attachment_restores_into_private_state(self):
        path = self.attachment()
        RESTORE.restore(self.backup, self.destination, self.repository_id)
        restored = self.destination / 'state' / path.relative_to(self.backup)
        self.assertEqual(restored.read_bytes(), path.read_bytes())
        self.assertEqual(restored.stat().st_mode & 0o777, 0o600)

    def test_expired_attachment_is_never_restored(self):
        path = self.attachment(expired=True)
        RESTORE.restore(self.backup, self.destination)
        self.assertFalse((self.destination / 'state' / path.relative_to(self.backup)).exists())
        self.assertTrue(path.exists(), 'Read-only restore must not edit original backup')

    def test_expired_attachment_may_already_be_pruned(self):
        path = self.attachment(expired=True); path.unlink()
        RESTORE.restore(self.backup, self.destination)
        self.assertFalse((self.destination / 'state/attachments').exists())

    @staticmethod
    def attachment_record(ident):
        return {"attachment": {"id": ident, "filename": "synthetic.txt", "mimeType": "text/plain",
                    "byteCount": 12, "sha256": "a" * 64, "state": "ready", "uploadedBytes": 12, "expiresAt": 0},
                "providerFileID": "file-api-synthetic", "providerExpiresAt": 0, "uploadStarted": True,
                "providerFilename": ident + ".txt", "purpose": "user_data", "createHash": "b" * 64}

    def put_attachment_record(self, ident, body):
        with sqlite3.connect(self.backup / 'cloud.sqlite') as database:
            database.execute('CREATE TABLE IF NOT EXISTS attachments(id TEXT PRIMARY KEY,body TEXT)')
            database.execute('DELETE FROM attachments')
            database.execute('INSERT INTO attachments VALUES (?,?)', (ident, json.dumps(body)))
        self.receipt()

    def test_restore_expires_database_metadata_without_reviving_bytes(self):
        ident = str(uuid.uuid4())
        self.put_attachment_record(ident, self.attachment_record(ident))
        self.attachment(expired=True)
        RESTORE.restore(self.backup, self.destination)
        with sqlite3.connect(self.destination / 'state/cloud.sqlite') as database:
            restored = json.loads(database.execute('SELECT body FROM attachments').fetchone()[0])
        self.assertEqual(restored['attachment']['state'], 'expired')
        self.assertIsNone(restored['providerFileID'])
        self.assertFalse(restored['uploadStarted'])

    def test_provider_converted_size_is_optional_and_independent_of_original(self):
        ident = str(uuid.uuid4())
        body = self.attachment_record(ident)
        body['attachment'].update(filename='synthetic.xlsx',
            mimeType='application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
            byteCount=1484, uploadedBytes=1484)
        body['providerFilename'] = ident + '.xlsx'
        original = copy.deepcopy(body['attachment'])
        # Missing/null stays compatible with legacy records; conversion can
        # produce either fewer or more bytes, within its independent hard cap.
        RESTORE.validate_attachment_record(ident, json.dumps(body))
        for converted in (None, 0, 1, 168, 2048, 9_007_199_254_740_991):
            with self.subTest(converted=converted):
                body['providerByteCount'] = converted
                result = RESTORE.validate_attachment_record(ident, json.dumps(body))
                self.assertEqual(result['attachment'], original)
                self.assertEqual(result['providerByteCount'], converted)
        body['providerByteCount'] = 168
        self.put_attachment_record(ident, body)
        RESTORE.restore(self.backup, self.destination)
        with sqlite3.connect(self.destination / 'state/cloud.sqlite') as database:
            restored = json.loads(database.execute('SELECT body FROM attachments').fetchone()[0])
        self.assertEqual(restored['providerByteCount'], 168)
        self.assertEqual(restored['attachment']['byteCount'], 1484)
        self.assertEqual(restored['attachment']['sha256'], original['sha256'])

    def test_provider_size_invalid_types_and_boundaries_rejected_before_restore(self):
        ident = str(uuid.uuid4())
        sentinel = self.base / 'outside-sentinel.md'
        sentinel.write_bytes(b'provider size validation must not touch this file')
        for value in (True, False, -1, 9_007_199_254_740_992, 10 ** 1000,
                      168.0, 1.5, '168', [], {}, float('nan'), float('inf')):
            with self.subTest(provider_bytes=value):
                body = self.attachment_record(ident)
                body['providerByteCount'] = value
                self.put_attachment_record(ident, body)
                before = (self.backup / 'cloud.sqlite').read_bytes()
                self.rejected()
                self.assertEqual((self.backup / 'cloud.sqlite').read_bytes(), before)
                self.assertEqual(sentinel.read_bytes(), b'provider size validation must not touch this file')

    def test_attachment_database_traversal_rejected_before_any_restore(self):
        ident = str(uuid.uuid4())
        sentinel = self.base / 'outside-sentinel.md'
        sentinel.write_bytes(b'never delete or replace this independent file')
        protected = (self.repository / 'PROFILE.md').read_bytes()
        for malicious_hash in ('../../../repository/PROFILE.md', '../../../../outside-sentinel.md',
                               str(sentinel), '..\\outside-sentinel.md'):
            with self.subTest(hash=malicious_hash):
                body = self.attachment_record(ident)
                body['attachment']['sha256'] = malicious_hash
                self.put_attachment_record(ident, body)
                before = (self.backup / 'cloud.sqlite').read_bytes()
                self.rejected()
                self.assertEqual(sentinel.read_bytes(), b'never delete or replace this independent file')
                self.assertEqual((self.repository / 'PROFILE.md').read_bytes(), protected)
                self.assertEqual((self.backup / 'cloud.sqlite').read_bytes(), before)

    def test_duplicate_attachment_json_keys_cannot_disagree_with_native_decoder(self):
        ident = str(uuid.uuid4())
        body = self.attachment_record(ident)
        self.put_attachment_record(ident, body)
        encoded = json.dumps(body).replace('"sha256": "' + 'a' * 64 + '"',
            '"sha256": "../../../repository/PROFILE.md", "sha256": "' + 'a' * 64 + '"', 1)
        with sqlite3.connect(self.backup / 'cloud.sqlite') as database:
            database.execute('UPDATE attachments SET body=? WHERE id=?', (encoded, ident))
        self.receipt()
        self.rejected()

    def test_attachment_database_rejects_unsafe_identity_hash_size_type_and_dates(self):
        ident = str(uuid.uuid4())
        base = self.attachment_record(ident)
        bad_fields = [
            ('attachment.id', str(uuid.uuid4())), ('attachment.id', '../outside'),
            ('attachment.sha256', 'A' * 64), ('attachment.sha256', 'a' * 63),
            ('attachment.filename', '../outside.txt'), ('attachment.filename', 'bad\r\n.txt'),
            ('attachment.filename', 'a' * 256 + '.txt'), ('attachment.filename', 'unknown.bin'),
            ('attachment.byteCount', -1), ('attachment.byteCount', True),
            ('attachment.byteCount', 32 * 1024 * 1024 + 1),
            ('attachment.uploadedBytes', -1), ('attachment.uploadedBytes', 13), ('attachment.uploadedBytes', 11),
            ('attachment.mimeType', 'text/plain\r\nInjected: value'),
            ('attachment.mimeType', 'm' * 151), ('attachment.state', 'arbitrary'),
            ('attachment.expiresAt', float('nan')), ('attachment.expiresAt', 10 ** 1000), ('providerExpiresAt', float('inf')),
            ('attachment.expiresAt', datetime.datetime.now(datetime.timezone.utc).timestamp() - 978307200 + 31 * 86400),
            ('attachment.issue', 'a' * 4001), ('providerFileID', None), ('uploadStarted', False),
            ('sentAt', True), ('providerFilename', '../escape.txt'),
            ('providerFileID', '../../remote'), ('uploadStarted', 'true'),
            ('purpose', 'rich_layout_recognition'), ('createHash', '../invalid')]
        for name, value in bad_fields:
            with self.subTest(field=name, value=value):
                body = copy.deepcopy(base)
                if name.startswith('attachment.'):
                    body['attachment'][name.split('.')[1]] = value
                else:
                    body[name] = value
                self.put_attachment_record(ident, body)
                self.rejected()
        for row_id in ('../outside', 'a' * 32):
            with self.subTest(row_id=row_id):
                self.put_attachment_record(row_id, base)
                self.rejected()
        body = copy.deepcopy(base)
        body['attachment'].update(filename='synthetic.pdf', mimeType='text/plain')
        body.update(providerFilename=ident + '.pdf', purpose='rich_layout_recognition')
        self.put_attachment_record(ident, body)
        self.rejected()

    def test_live_attachment_missing_or_tampered_rejects(self):
        path = self.attachment(); path.write_bytes(b'tampered')
        self.rejected(); path.unlink(); self.rejected()

    def test_attachment_requires_matching_expiry_inventory(self):
        path = self.attachment()
        manifest = self.backup / 'manifest.json'
        value = json.loads(manifest.read_text()); value['attachmentFiles'] = []
        manifest.write_text(json.dumps(value)); self.receipt()
        self.rejected()

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
