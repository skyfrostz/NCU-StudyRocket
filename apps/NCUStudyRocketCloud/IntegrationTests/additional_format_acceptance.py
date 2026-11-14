#!/usr/bin/env python3
"""Nine synthetic native file formats; static-only unless explicitly --run-live.

Live mode uses the existing signed Fixture and DeepSeek Proxy. Supply the API key
only in the child environment, never argv/report. Run only after controller
approval, after the four-format suite stops, in a separate <=384 MiB cgroup.
"""
import argparse
import base64
import hashlib
import io
import json
import os
from pathlib import Path
import re
import sys
import time
import uuid
import zipfile

from cloud_acceptance import Fixture, sha
from live_attachment_acceptance import Proxy

FORMATS = {
    'legacy-word.doc': ('application/msword', 'MAPLE-246'),
    'legacy-sheet.xls': ('application/vnd.ms-excel', 'BIRCH-357'),
    'slides.ppt': ('application/vnd.ms-powerpoint', 'PINE-468'),
    'slides.pptx': ('application/vnd.openxmlformats-officedocument.presentationml.presentation', 'PINE-468'),
    'plain.txt': ('text/plain', 'LARCH-579'),
    'notes.md': ('text/markdown', 'CEDAR-680'),
    'table.csv': ('text/csv', 'ELM-791'),
    'data.json': ('application/json', 'WILLOW-802'),
    'shape.jpg': ('image/jpeg', None),
}
CHUNK = 262144
MAX_BYTES = 100 * 1024 * 1024


class QAError(Exception):
    pass


def require(condition, code):
    if not condition:
        raise QAError(code)


def file_sha(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as source:
        for block in iter(lambda: source.read(CHUNK), b''):
            digest.update(block)
    return digest.hexdigest()


def validate_files(directory, manifest_path):
    directory = Path(directory).resolve(strict=True)
    manifest_data = Path(manifest_path).read_bytes()
    manifest = json.loads(manifest_data)
    require(manifest.get('version') == 1 and manifest.get('synthetic') is True,
            'fixture_manifest_not_synthetic_v1')
    entries = manifest.get('files', [])
    require(len(entries) == len(FORMATS) and {row.get('filename') for row in entries} == set(FORMATS),
            'fixture_manifest_must_list_exact_nine_files')
    rows = {row['filename']: row for row in entries}
    result = []
    for name, (mime, token) in FORMATS.items():
        path = directory / name
        require(path.is_file() and not path.is_symlink(), 'fixture_missing_or_symlink:' + name)
        data = path.read_bytes()
        row = rows[name]
        require(row.get('mimeType') == mime and row.get('byteCount') == len(data)
                and row.get('sha256') == sha(data), 'fixture_manifest_hash_mismatch:' + name)
        ext = path.suffix
        limit = 20 * 1024 * 1024 if ext == '.jpg' else 32 * 1024 * 1024 if ext in {'.xls', '.txt', '.md', '.csv', '.json'} else MAX_BYTES
        require(0 < len(data) <= limit, 'fixture_size_invalid:' + name)
        if ext in {'.doc', '.xls', '.ppt'}:
            require(data.startswith(bytes.fromhex('d0cf11e0a1b11ae1')), 'not_native_legacy_office:' + name)
            require(token.encode() in data or token.encode('utf-16le') in data, 'synthetic_code_missing:' + name)
        elif ext == '.pptx':
            with zipfile.ZipFile(io.BytesIO(data)) as archive:
                require('ppt/presentation.xml' in archive.namelist(), 'not_native_pptx')
                slide_text = b'\n'.join(archive.read(item) for item in archive.namelist() if item.startswith('ppt/slides/slide') and item.endswith('.xml'))
                require(token.encode() in slide_text, 'synthetic_slide_code_missing')
        elif ext == '.jpg':
            require(data.startswith(b'\xff\xd8\xff') and data.endswith(b'\xff\xd9'), 'not_jpeg')
        else:
            text = data.decode('utf-8')
            require(token in text, 'synthetic_code_missing:' + name)
            if ext == '.json':
                require(json.loads(text).get('code') == token, 'synthetic_json_code_invalid')
        result.append({'filename': name, 'mimeType': mime, 'byteCount': len(data), 'sha256': sha(data)})
    require(len(result) <= 10 and sum(row['byteCount'] for row in result) <= MAX_BYTES,
            'message_attachment_limits_exceeded')
    return result, sha(manifest_data)


def parse_answer(answer, checks=None):
    text = answer.strip()
    if text.startswith('```'):
        text = re.sub(r'^```(?:json)?\s*', '', text, count=1, flags=re.I)
        text = re.sub(r'\s*```$', '', text, count=1)
    try:
        value = json.loads(text)
    except (ValueError, TypeError) as error:
        raise QAError('answer_not_a_single_json_mapping') from error
    require(isinstance(value, dict) and set(value) == set(FORMATS), 'answer_filename_mapping_incomplete')
    checks = {} if checks is None else checks
    for name, (_, expected) in FORMATS.items():
        item = value[name]
        require(isinstance(item, dict), 'answer_row_not_object:' + name)
        if expected:
            correct = item.get('code') == expected
        else:
            color, shape = str(item.get('color', '')).lower(), str(item.get('shape', '')).lower()
            correct = (('green' in color or '绿' in color)
                       and ('circle' in shape or '圆' in shape)
                       and str(item.get('number', '')).strip() == '91')
        checks[name] = 'PASS' if correct else 'FAIL'
    require(all(value == 'PASS' for value in checks.values()), 'answer_content_mapping_incorrect')
    return value, checks


def cgroup_budget(expected_unit):
    require(sys.platform == 'linux', 'live_requires_linux_isolated_unit')
    entry = next((line[3:] for line in Path('/proc/self/cgroup').read_text().splitlines() if line.startswith('0::')), None)
    require(entry is not None and expected_unit and Path(entry).name == expected_unit
            and expected_unit.startswith('studyrocket-chat-extra-formats-') and expected_unit.endswith('.service'),
            'live_unit_identity_not_expected')
    group = Path('/sys/fs/cgroup') / entry.lstrip('/')
    raw = (group / 'memory.max').read_text().strip()
    require(raw.isdigit() and 0 < int(raw) <= 384 * 1024 * 1024, 'live_unit_exceeds_384_MiB_or_unbounded')
    return {'unit': expected_unit, 'memoryMaxBytes': int(raw)}


def write_json(path, value):
    path = Path(path)
    temporary = path.with_name(path.name + '.tmp')
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.write('\n'); stream.flush(); os.fsync(stream.fileno())
    os.replace(temporary, path)


def run_live(args, files, manifest_sha):
    require(args.binary and args.approved_binary_sha, 'live_requires_binary_and_explicit_approved_binary_sha')
    binary_sha = file_sha(args.binary)
    require(binary_sha == args.approved_binary_sha, 'live_binary_differs_from_approval')
    budget = cgroup_budget(args.expected_unit)
    key = os.environ.get('DEEPSEEK_API_KEY')
    require(bool(key), 'live_key_must_be_supplied_in_child_environment')
    report_path = Path(args.report)
    journal_path = report_path.with_name(report_path.stem + '.provider-cleanup-journal.json')
    require(not report_path.exists() and not journal_path.exists(), 'live_report_or_cleanup_journal_already_exists')
    report_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    report = {'result': 'FAIL', 'synthetic': True, 'repository': 'temporary_fixture_only',
              'binarySHA256': binary_sha, 'fixtureManifestSHA256': manifest_sha,
              'formats': files, 'budget': budget, 'uploads': [], 'readback': {},
              'content': 'NOT_RUN', 'cleanup': 'NOT_RUN', 'live': True}
    proxy, fixture = None, None
    created_ids = []
    turn = None
    terminal = None
    started = time.monotonic()

    def safe_error(error):
        # An upstream/Fixture error must never leak an environment credential.
        message = str(error).replace(key, '[REDACTED]')
        message = re.sub(r'(?i)Bearer\s+[^\s\"\']+', 'Bearer [REDACTED]', message)
        return {'type': type(error).__name__, 'message': message[:1200]}

    def check_deadline():
        require(time.monotonic() - started < args.timeout, 'live_overall_deadline_exceeded')

    try:
        proxy = Proxy(key, journal_path)
        fixture = Fixture(args.binary)
        fixture.upstream = proxy.url
        fixture.start(); fixture.pair()
        repository_before = {str(path.relative_to(fixture.repo)): file_sha(path) for path in fixture.repo.rglob('*') if path.is_file()}

        def call(action, payload):
            check_deadline()
            status, value = fixture.request('POST', '/v1/attachments/' + action, payload)
            require(status in (200, 202) and isinstance(value, dict), 'attachment_' + action + '_http_' + str(status))
            return value

        for item in files:
            check_deadline()
            name = item['filename']
            data = (Path(args.fixtures) / name).read_bytes()
            require(len(data) == item['byteCount'] and sha(data) == item['sha256'],
                    'fixture_changed_after_preflight:' + name)
            ident = str(uuid.uuid4()); created_ids.append(ident)
            create = {'id': ident, 'filename': name, 'mimeType': item['mimeType'],
                      'byteCount': len(data), 'sha256': sha(data), 'apiVersion': 1}
            state = call('create', create)
            require(state.get('id') == ident, 'create_id_mismatch:' + name)
            for offset in range(0, len(data), CHUNK):
                block = data[offset:offset + CHUNK]
                state = call('chunk', {'id': ident, 'offset': offset,
                                      'base64Data': base64.b64encode(block).decode(), 'sha256': sha(block)})
                require(state.get('uploadedBytes') == offset + len(block), 'chunk_ack_offset_mismatch:' + name)
            call('complete', {'id': ident})
            deadline = time.monotonic() + 300
            while time.monotonic() < deadline:
                state = call('status', {'id': ident})
                require(state.get('id') == ident, 'status_id_mismatch:' + name)
                if state.get('state') == 'ready':
                    break
                if state.get('state') in {'failed', 'removed', 'expired'}:
                    report['failedAttachment'] = {'filename': name, 'state': state.get('state'), 'issue': safe_error(QAError(state.get('issue') or 'attachment_failed'))}
                    raise QAError('attachment_processing_failed:' + name)
                time.sleep(2)
            require(state.get('state') == 'ready', 'attachment_ready_timeout:' + name)
            require(state.get('sha256') == item['sha256'] and state.get('byteCount') == len(data),
                    'attachment_original_identity_changed:' + name)
            report['uploads'].append({'filename': name, 'state': 'ready',
                                      'localIDHash': sha(ident), 'expiresAt': state.get('expiresAt')})
            # Read original bytes through the same signed app API. Provider-native
            # normalization is allowed; original download identity is not.
            offset, restored = 0, bytearray()
            while True:
                block = call('read', {'id': ident, 'offset': offset, 'limit': CHUNK})
                decoded = base64.b64decode(block.get('base64Data', ''), validate=True)
                require(block.get('id') == ident and block.get('offset') == offset
                        and block.get('totalBytes') == len(data) and block.get('sha256') == sha(decoded)
                        and len(decoded) <= CHUNK, 'readback_chunk_mismatch:' + name)
                restored.extend(decoded); offset += len(decoded)
                expected_next = offset if offset < len(data) else None
                require(block.get('nextOffset') == expected_next, 'readback_cursor_mismatch:' + name)
                if expected_next is None:
                    break
                require(bool(decoded), 'readback_zero_progress:' + name)
            require(bytes(restored) == data and sha(restored) == item['sha256'], 'readback_original_sha_mismatch:' + name)
            report['readback'][name] = {'result': 'PASS', 'sha256': sha(restored), 'byteCount': len(restored)}
            write_json(report_path.with_suffix('.progress.json'), report)

        turn = str(uuid.uuid4())
        prompt = ('这是隔离合成文件验收。仅读取随本消息附上的九个文件，不调用任何工具、不产生草案。'
                  '请逐个文件返回一个严格 JSON 对象，键必须是原始完整文件名。'
                  '对每个非图片文件，值为 {"code":"文件中写出的完整校验代码"}，保留代码的字母、数字和连字符。'
                  '对 shape.jpg，值为 {"shape":"形状英文名称","color":"颜色英文名称","number":"图中数字"}。'
                  '不得猜测；看不清时写 null。只输出 JSON，不要 Markdown 围栏，不要输出附件或文件服务编号。')
        status, _ = fixture.request('POST', '/v1/chat/send', {'text': prompt, 'clientRequestID': turn,
                                                            'apiVersion': 1, 'attachmentIDs': created_ids})
        require(status == 202, 'chat_send_not_accepted_' + str(status))
        history = {}
        while True:
            check_deadline()
            status, history = fixture.request('GET', '/v1/chat/history')
            require(status == 200, 'chat_history_not_200')
            terminal = next((row for row in history.get('terminalTurns', []) if row.get('turnID') == turn), None)
            if terminal:
                break
            time.sleep(2)
        report['terminal'] = {k: terminal.get(k) for k in ('status', 'issueCode')}
        require(terminal.get('status') == 'completed', 'chat_did_not_complete')
        answers = [row['text'] for row in history.get('messages', [])
                   if row.get('turnID') == turn and row.get('role') == 'assistant' and row.get('phase') != 'commentary']
        answer = '\n'.join(answers)
        # The prompt never reveals the expected answers; validation is per-file.
        report['answer'] = answer.replace(key, '[REDACTED]')
        report['content'] = 'FAIL'
        report['perFileContent'] = {}
        mapping, checks = parse_answer(answer, report['perFileContent'])
        report.update(answerMapping=mapping, perFileContent=checks, content='PASS')
        user = next((row for row in history.get('messages', []) if row.get('turnID') == turn and row.get('role') == 'user'), None)
        require(user and {row['id'] for row in user.get('attachments', [])} == set(created_ids), 'history_missing_exact_attachment_set')
        native_ids = {row.get('id') for row in proxy.native_files}
        require(len(proxy.native_files) == len(files) and len(native_ids) == len(files) and None not in native_ids,
                'native_upload_set_not_exactly_nine')
        require(proxy.uploads == len(files), 'native_files_uploaded_more_than_once')
        require(proxy.chat_file_ids and all(set(ids) == native_ids and len(ids) == len(files) for ids in proxy.chat_file_ids),
                'each_chat_round_must_reference_exact_nine_native_files')
        require(all(row.get('expires_at') for row in proxy.native_files), 'native_expiry_missing')
        report['native'] = {'uploads': proxy.uploads, 'fileBlocks': proxy.file_blocks,
                            'eachRoundExactNineFiles': True,
                            'files': [{k: row.get(k) for k in ('filename', 'purpose', 'bytes', 'created_at', 'expires_at')} for row in proxy.native_files]}
        repository_after = {str(path.relative_to(fixture.repo)): file_sha(path) for path in fixture.repo.rglob('*') if path.is_file()}
        require(repository_after == repository_before, 'temporary_academic_repository_changed')
        report['temporaryRepositoryUnchanged'] = True
        report['result'] = 'PASS'
    except Exception as error:
        report['error'] = safe_error(error)
    finally:
        cleanup_errors = []
        if fixture is not None and fixture.process is not None and fixture.process.poll() is None:
            if turn and not terminal:
                try:
                    fixture.request('POST', '/v1/chat/interrupt', {'turnID': turn, 'operationID': str(uuid.uuid4())})
                except Exception as error:
                    cleanup_errors.append(safe_error(error))
            for ident in created_ids:
                try:
                    status, value = fixture.request('POST', '/v1/attachments/remove', {'id': ident})
                    if status not in (200, 202): cleanup_errors.append({'type': 'remove_http', 'status': status})
                except Exception as error:
                    cleanup_errors.append(safe_error(error))
            cleanup_deadline = time.monotonic() + 90
            while proxy is not None and time.monotonic() < cleanup_deadline:
                uploaded_ids = {row.get('id') for row in proxy.native_files}
                if uploaded_ids and proxy.deleted_ids == uploaded_ids:
                    break
                if not uploaded_ids and not created_ids:
                    break
                for ident in created_ids:
                    try: fixture.request('POST', '/v1/attachments/status', {'id': ident})
                    except Exception: pass
                time.sleep(1)
        native_ids = {row.get('id') for row in proxy.native_files} if proxy is not None else set()
        deleted_ids = set(proxy.deleted_ids) if proxy is not None else set()
        exact = None not in native_ids and deleted_ids == native_ids
        report['cleanup'] = 'PASS' if exact and len(native_ids) == len(files) and not cleanup_errors else 'FAIL'
        report['providerCleanup'] = {'expectedNativeFiles': len(files), 'uploadedNativeFiles': len(native_ids),
                                     'confirmedDeletedFiles': len(deleted_ids), 'exactSetMatch': exact,
                                     'nativeIDHashes': sorted(sha(value) for value in native_ids if isinstance(value, str)),
                                     'deletedIDHashes': sorted(sha(value) for value in deleted_ids),
                                     'deleteRequestCount': sum(path.startswith('DELETE /files/') for path in proxy.paths) if proxy else 0,
                                     'errors': cleanup_errors}
        if fixture is not None:
            try:
                fixture.close()
                report['fixtureShutdown'] = 'PASS' if fixture.process is None or fixture.process.returncode == 0 else 'FAIL'
            except Exception as error:
                report['fixtureShutdown'] = 'FAIL'; report['fixtureShutdownError'] = safe_error(error)
        if proxy is not None:
            try: proxy.close()
            except Exception as error: report['proxyShutdownError'] = safe_error(error)
        if report['cleanup'] != 'PASS' or report.get('fixtureShutdown') != 'PASS' or 'proxyShutdownError' in report:
            report['result'] = 'FAIL'
        report['elapsedSeconds'] = round(time.monotonic() - started, 3)
        write_json(report_path, report)
    print(json.dumps({'result': report['result'], 'report': str(report_path), 'content': report['content'],
                      'cleanup': report['cleanup'], 'nativeFiles': len(native_ids), 'deletedFiles': len(deleted_ids)}, ensure_ascii=False))
    return 0 if report['result'] == 'PASS' else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixtures', required=True)
    parser.add_argument('--manifest', required=True)
    parser.add_argument('--report', required=True)
    parser.add_argument('--run-live', action='store_true', help='Explicit controller-authorized real API execution only')
    parser.add_argument('--binary')
    parser.add_argument('--approved-binary-sha')
    parser.add_argument('--expected-unit')
    parser.add_argument('--timeout', type=int, default=900)
    args = parser.parse_args()
    os.umask(0o077)
    files, manifest_sha = validate_files(args.fixtures, args.manifest)
    if not args.run_live:
        report = {'result': 'STATIC_PASS', 'live': 'NOT_RUN', 'synthetic': True,
                  'files': files, 'fixtureManifestSHA256': manifest_sha,
                  'totalByteCount': sum(row['byteCount'] for row in files),
                  'contentRecognition': 'NOT_RUN', 'providerCleanup': 'NOT_RUN'}
        Path(args.report).parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        write_json(args.report, report)
        print(json.dumps({'result': 'STATIC_PASS', 'live': 'NOT_RUN', 'fileCount': len(files), 'totalByteCount': report['totalByteCount']}, ensure_ascii=False))
        return 0
    return run_live(args, files, manifest_sha)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (QAError, OSError, ValueError) as error:
        # Preflight errors never include environment values or upstream headers.
        print(json.dumps({'result': 'PRECHECK_FAIL', 'errorType': type(error).__name__}), file=sys.stderr)
        sys.exit(1)
