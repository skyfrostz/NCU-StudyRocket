#!/usr/bin/env python3
"""Full attachment backup/download/restore path against an isolated native server."""
import argparse, hashlib, importlib.util, json, sqlite3, subprocess, sys, unittest
from pathlib import Path
import attachment_acceptance as ATT

DEPLOY = Path(__file__).resolve().parent.parent / 'Deployment'
def load(name):
    spec = importlib.util.spec_from_file_location(name, DEPLOY / (name + '.py'))
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module); return module
BACKUP, RESTORE = load('backup'), load('restore_backup')

class AttachmentBackupAcceptance(unittest.TestCase):
    binary = ''
    def test_complete_backup_and_restore_preserve_attachment_identity_and_hash(self):
        case = ATT.AttachmentAcceptance(); case.binary = self.binary; case.setUp()
        self.addCleanup(case.tearDown)
        attachment = case.ready(case.upload(b'backup synthetic material'))
        turn = case.send([attachment['id']]); case.terminal(turn)
        parent = case.f.state.parent.resolve() / 'backups'; parent.mkdir(exist_ok=True)
        output = parent / 'synthetic-attachment-backup'
        subprocess.run([self.binary, 'backup', '--repository', str(case.f.repo), '--state', str(case.f.state), '--output', str(output)], check=True, capture_output=True)
        BACKUP.verify_snapshot(output)
        manifest = json.loads((output / 'manifest.json').read_text())
        entries = {item['path']: item for item in manifest['attachmentFiles']}
        self.assertEqual(len(entries), 2)
        object_name = 'attachments/objects/' + attachment['sha256']
        source = case.f.state / object_name
        self.assertEqual(source.stat().st_ino, (output / object_name).stat().st_ino, 'Snapshots must hardlink immutable objects')
        receipt = []
        for path in output.rglob('*'):
            if path.is_file():
                name = path.relative_to(output).as_posix()
                item = {'path': name, 'bytes': path.stat().st_size, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
                if name in entries: item['expiresAt'] = entries[name]['expiresAt']
                receipt.append(item)
        (output / 'verified-backup.json').write_text(json.dumps({'version': 1, 'createdAt': '2026-11-14T00:00:00Z', 'files': receipt}))
        status, served = case.f.request('GET', '/v1/backups/latest')
        self.assertEqual(status, 200, served)
        remote = next(item for item in served['files'] if item['path'] == object_name)
        self.assertIn('expiresAt', remote)
        status, chunk = case.f.request('POST', '/v1/backups/read', {'backupID': output.name, 'path': object_name, 'offset': 0, 'limit': 262144})
        self.assertEqual(status, 200, chunk)
        destination = case.f.state.parent.resolve() / 'restored-attachment'
        restored = RESTORE.restore(output, destination)
        self.assertFalse(restored['liveSwitchPerformed'])
        self.assertEqual((destination / 'state' / object_name).read_bytes(), source.read_bytes())
        with sqlite3.connect(destination / 'state/cloud.sqlite') as db:
            record = json.loads(db.execute('SELECT body FROM attachments WHERE id=?', (attachment['id'],)).fetchone()[0])
        self.assertEqual(record['attachment']['state'], 'ready')
        self.assertEqual(record['attachment']['sha256'], attachment['sha256'])

if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('--binary', required=True); args = parser.parse_args()
    AttachmentBackupAcceptance.binary = args.binary
    unittest.main(argv=[sys.argv[0]], verbosity=2)
