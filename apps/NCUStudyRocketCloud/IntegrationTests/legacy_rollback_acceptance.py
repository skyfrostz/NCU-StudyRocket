#!/usr/bin/env python3
"""Synthetic cloud-to-legacy rollback rehearsal; no production service is used.

On macOS (Python 3, OpenSSL and Swift required):
  python3 legacy_rollback_acceptance.py --binary /path/to/StudyRocketCloud \
      --output /tmp/studyrocket-rollback-new-run

--output must not exist and must be outside the source repository. Omit
--host-readback to build LegacyHostReadback.swift with the current production
HostSnapshotBuilder source and Shared module in an isolated build directory.
An explicitly supplied --host-readback must be built from that same fixture.

Only result.json is sanitized for publication. Other output artifacts are
synthetic but include local paths and test pairing state; keep them local.
Legacy Host HTTP/authentication and real-device re-pairing remain NOT RUN.
"""
from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import socket
import subprocess
import sys
import uuid

import cloud_acceptance as cloud


ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
HOST_SOURCE = ROOT / 'apps/NCUStudyRocket/Sources/StudyRocketHost/HostSnapshotBuilder.swift'
SWIFT_FIXTURE = HERE / 'LegacyHostReadback.swift'
BEIJING = dt.timezone(dt.timedelta(hours=8))


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


RESTORE = load_module('rollback_restore', HERE.parent / 'Deployment/restore_backup.py')
BACKUP = load_module('rollback_backup', HERE.parent / 'Deployment/backup.py')


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def entry(path, root):
    return {'path': path.relative_to(root).as_posix(),
            'bytes': path.stat().st_size, 'sha256': digest(path)}


def write_json(path, value):
    with path.open('x', encoding='utf-8') as target:
        json.dump(value, target, ensure_ascii=False, indent=2)
        target.write('\n')


def checked(status, value):
    # Never dump an HTTP payload or pairing material on failure.
    require(status == 200, f'Expected HTTP 200, received {status}')
    return value


def compile_readback(output):
    require(sys.platform == 'darwin', 'Automatic Mac Host readback compilation requires macOS')
    package = ROOT / 'apps/NCUStudyRocketShared'
    build = ['swift', 'build', '--build-system', 'native', '--package-path', str(package),
             '--scratch-path', str(output / 'swift-build'), '-c', 'debug']
    with (output / 'build.log').open('xb') as log:
        subprocess.run([*build, '--target', 'StudyRocketShared'],
                       stdout=log, stderr=subprocess.STDOUT, check=True)
        result = subprocess.run([*build, '--show-bin-path'],
                                stdout=subprocess.PIPE, stderr=log, check=True, text=True)
        binary_path = Path(result.stdout.strip())
        objects = sorted((binary_path / 'StudyRocketShared.build').glob('*.swift.o'))
        require(objects, 'Shared build produced no object files')
        require((binary_path / 'Modules/StudyRocketShared.swiftmodule').exists(),
                'Shared build produced no Swift module')
        target = output / 'host-readback'
        subprocess.run(['swiftc', '-parse-as-library', '-I', str(binary_path / 'Modules'),
                        str(HOST_SOURCE), str(SWIFT_FIXTURE),
                        *map(str, objects), '-o', str(target)],
                       stdout=log, stderr=subprocess.STDOUT, check=True)
    return target


def synthetic_plan(today, task):
    return (
        '# Synthetic rollback plan\n\n'
        '<!-- studyrocket:weekly:start -->\n'
        '| 日期 | 上午 | 中午 | 晚上 | 待分配 | 完成 |\n'
        '|---|---|---|---|---|---|\n'
        f'| {today} | {task} |  |  |  | [ ] |\n'
        '<!-- studyrocket:weekly:end -->\n\n'
        '<!-- studyrocket:deliveries:start -->\n'
        '- [ ] Synthetic delivery\n'
        '<!-- studyrocket:deliveries:end -->\n\n'
        'Unmanaged explanation preserved.\n'
    )


def rehearse(binary, output, readback):
    fixture = cloud.Fixture(str(binary))
    try:
        today = dt.datetime.now(BEIJING).date().isoformat()
        fixture.write('工作台/下周计划.md', synthetic_plan(today, 'Synthetic original task'))
        fixture.start()
        fixture.pair()
        original = checked(*fixture.request('GET', '/v1/snapshot'))

        operation, fact_id, task_id, assignment_id, delivery_id = [
            str(uuid.uuid4()).upper() for _ in range(5)
        ]
        pending = {'deliveries': [], 'periods': [],
                   'weekBaseRevision': original['revision'], 'week': original['week']}
        archive_dir = output / 'phone-cache/preserved-queues'
        archive_dir.mkdir(parents=True)
        archive = archive_dir / 'legacy-queue.json'
        encode = lambda value: base64.b64encode(json.dumps(value).encode()).decode()
        write_json(archive, {
            'id': str(uuid.uuid4()), 'createdAt': 816134400,
            'repositoryID': 'legacy-synthetic-root-hash',
            'endpoint': 'https://old.synthetic.invalid',
            'drafts': encode(pending), 'cachedSnapshot': encode(original),
            'facts': encode([{'repositoryID': 'legacy-synthetic-root-hash',
                              'fact': {'id': operation, 'date': today,
                                       'text': 'Synthetic old queue fact'}}]),
            'input': 'Synthetic old unsent text',
        })
        archive_hash = digest(archive)

        new_text = 'Synthetic cloud-confirmed new task'
        legacy_task = subprocess.check_output(
            [str(readback), '--task-id', new_text], text=True, stderr=subprocess.PIPE
        ).strip()
        require(legacy_task, 'Production task parser returned no identity')
        graph = {
            'version': 1, 'activationDate': today,
            'tasks': [{'id': task_id, 'text': new_text, 'category': 'study',
                       'originDate': today, 'deliveryID': delivery_id, 'cancelled': False}],
            'assignments': [{'id': assignment_id, 'taskID': task_id, 'date': today,
                             'periodID': 'morning', 'legacyTaskID': legacy_task, 'active': True}],
            'deliveries': [{'id': delivery_id, 'text': 'Synthetic delivery',
                            'carried': False, 'cancelled': False}],
        }
        candidate = (synthetic_plan(today, new_text)
                     + '\n<!-- studyrocket:task-links:start -->\n```json\n'
                     + json.dumps(graph) + '\n```\n<!-- studyrocket:task-links:end -->\n')
        request = fixture.commit_request({'工作台/下周计划.md': candidate})
        checked(*fixture.request('POST', '/v1/files/commit', request))
        current = checked(*fixture.request('GET', '/v1/snapshot'))
        fact = {'id': fact_id, 'date': today, 'text': 'Synthetic fact confirmed after cloud cutover'}
        checked(*fixture.request('POST', '/v1/facts', {
            'repositoryID': request['repositoryID'], 'entry': fact,
            'metadata': {'apiVersion': 1, 'baseRevision': current['revision'],
                         'idempotencyKey': fact_id},
        }))
        confirmed = checked(*fixture.request('GET', '/v1/snapshot'))
        require(any(task['id'] == task_id and task['text'] == new_text
                    for task in confirmed['week']['linkage']['tasks']), 'Cloud task was not confirmed')
        require(confirmed['recentFacts'] == [fact], 'Cloud fact was not confirmed exactly once')
        write_json(output / 'cloud-confirmed-snapshot.json', confirmed)
        before = {path.relative_to(fixture.repo).as_posix(): digest(path)
                  for path in fixture.repo.rglob('*.md') if path.is_file()}

        # Stop only this fixture's process before the final consistent backup.
        fixture.stop()
        require(fixture.process.poll() is not None, 'Temporary cloud writer is still alive')
        with socket.socket() as probe:
            require(probe.connect_ex(('127.0.0.1', fixture.port)) != 0,
                    'Temporary cloud listener is still reachable')
        backup = output / 'backup'
        fixture.cli('backup', '--repository', str(fixture.repo), '--state', str(fixture.state),
                    '--output', str(backup))
        BACKUP.verify_snapshot(backup)
        entries = [entry(path, backup) for path in sorted(backup.rglob('*')) if path.is_file()]
        write_json(backup / 'verified-backup.json', {
            'version': 1, 'createdAt': dt.datetime.now(dt.timezone.utc).isoformat(), 'files': entries,
        })
        destination = output / 'legacy-restored'
        RESTORE.restore(backup, destination, request['repositoryID'])
        restored = destination / 'repository'
        after = {path.relative_to(restored).as_posix(): digest(path)
                 for path in restored.rglob('*') if path.is_file()}
        require(after == before, 'Restored file inventory or hashes differ')
        require(not (restored / '.studyrocket-cloud.json').exists(),
                'Fresh recovery directory inherited a cloud binding')

        snapshot_path = output / 'legacy-host-snapshot.json'
        subprocess.run([str(readback), str(restored), str(snapshot_path)],
                       check=True, capture_output=True)
        legacy = json.loads(snapshot_path.read_text(encoding='utf-8'))
        require(legacy['week'] == confirmed['week'], 'Legacy week projection differs')
        require(legacy['recentFacts'] == confirmed['recentFacts'], 'Legacy facts differ')
        require(legacy['revision'] != confirmed['revision'],
                'Path-based legacy revision unexpectedly reused cloud revision')
        text = (restored / '工作台/下周计划.md').read_text(encoding='utf-8')
        markers = ['weekly:start', 'weekly:end', 'deliveries:start', 'deliveries:end',
                   'task-links:start', 'task-links:end']
        require(all(text.count('<!-- studyrocket:' + marker + ' -->') == 1 for marker in markers),
                'Management markers were not preserved exactly once')
        require('Unmanaged explanation preserved.' in text, 'Unmanaged text was lost')
        require(legacy['week']['linkage']['tasks'][0]['id'] == task_id, 'Stable task ID changed')
        require(legacy['week']['linkage']['assignments'][0]['id'] == assignment_id,
                'Stable assignment ID changed')
        require(legacy['week']['linkage']['deliveries'][0]['id'] == delivery_id,
                'Stable delivery ID changed')
        require(digest(archive) == archive_hash, 'Separate old queue archive changed')
        require(dt.datetime.now(BEIJING).date().isoformat() == today,
                'Rehearsal crossed a Beijing date boundary; rerun in a new directory')
        return {
            'result': 'PASS',
            'scope': 'isolated cloud HTTP writes -> stopped writer -> verified backup -> '
                     'new directory restore -> production Mac HostSnapshotBuilder readback',
            'cloudWritesConfirmed': 2, 'temporaryWriterStoppedBeforeBackup': True,
            'temporaryListenerClosedBeforeBackup': True,
            'restoredFiles': len(before), 'factCount': len(legacy['recentFacts']),
            'stableTasks': len(legacy['week']['linkage']['tasks']),
            'stableAssignments': len(legacy['week']['linkage']['assignments']),
            'stableDeliveries': len(legacy['week']['linkage']['deliveries']),
            'managementMarkers': len(markers), 'exactRestoredFileHashes': True,
            'unmanagedTextPreserved': True, 'legacySnapshotWeekAndFactsMatch': True,
            'legacyRevisionDiffersAsExpected': True, 'recoveredDirectoryHasNoCloudBinding': True,
            'oldQueueArchiveUnchanged': True, 'oldQueueSHA256': archive_hash,
            'cloudBinarySHA256': digest(binary), 'hostReadbackBinarySHA256': digest(readback),
            'realMarkdownTouched': False, 'realAppOrHostTouched': False,
            'realCodexStarted': False, 'productionCloudAccessed': False,
            'liveSwitchPerformed': False,
            'notRun': ['legacy Host HTTP listener and authentication', 'real-device re-pairing',
                       'real-device pending queue replay', 'production cutover'],
            'limits': [
                'Production Host snapshot source was executed without starting the legacy Host service.',
                'A synthetic client queue archive was kept byte-for-byte; it is separate from cloud backup.',
                'Preservation of that archive does not verify Mobile queue migration or replay.',
            ],
        }
    finally:
        fixture.close()


def executable(value):
    path = Path(value).expanduser().resolve(strict=True)
    if not path.is_file() or not os.access(path, os.X_OK):
        raise ValueError('Expected an executable file')
    return path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, help='Built local StudyRocketCloud executable')
    parser.add_argument('--output', type=Path, required=True, help='New output directory; must not exist')
    parser.add_argument('--host-readback', help='Optional precompiled LegacyHostReadback executable')
    args = parser.parse_args()
    try:
        binary = executable(args.binary)
        readback = executable(args.host_readback) if args.host_readback else None
        require(not os.path.lexists(args.output.expanduser()), 'Output directory already exists')
        output = args.output.expanduser().resolve()
        require(ROOT != output and ROOT not in output.parents,
                'Output directory must be outside the source repository')
        require(output.parent.is_dir(), 'Output parent directory must exist')
        output.mkdir(mode=0o700)
    except (OSError, ValueError, AssertionError) as error:
        parser.error(str(error))

    stage = 'compile-host-readback' if readback is None else 'rollback-rehearsal'
    try:
        if readback is None:
            readback = compile_readback(output)
        stage = 'rollback-rehearsal'
        report = rehearse(binary, output, readback)
        report.update({
            'completedAtUTC': dt.datetime.now(dt.timezone.utc).isoformat(),
            'platform': platform.system(), 'architecture': platform.machine(),
            'hostReadbackMode': 'supplied' if args.host_readback else 'compiled-current-source',
            'fixtureSHA256': digest(Path(__file__).resolve()),
            'swiftFixtureSHA256': digest(SWIFT_FIXTURE),
            'hostSnapshotBuilderSourceSHA256': digest(HOST_SOURCE),
        })
    except Exception as error:
        # Failure output is deliberately bounded; raw logs stay local.
        report = {'result': 'FAIL', 'stage': stage, 'errorType': type(error).__name__,
                  'liveSwitchPerformed': False, 'productionCloudAccessed': False}
        write_json(output / 'result.json', report)
        print(json.dumps(report, indent=2))
        return 1
    write_json(output / 'result.json', report)
    print(json.dumps(report, indent=2))
    return 0


if __name__ == '__main__':
    sys.exit(main())
