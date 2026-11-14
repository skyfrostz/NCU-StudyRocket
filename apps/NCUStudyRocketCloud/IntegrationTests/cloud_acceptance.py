#!/usr/bin/env python3
"""Independent black-box acceptance. Requires only Python 3, openssl and a built server.

python3 cloud_acceptance.py --binary /absolute/path/StudyRocketCloud
No production service or model endpoint is used. Test files are synthetic.
"""
import argparse
import base64
import concurrent.futures
import datetime
import hashlib
import http.client
import http.server
import json
import os
from pathlib import Path
import shutil
import socket
import sqlite3
import subprocess
import tempfile
import threading
import time
import unittest
import uuid


def sha(value):
    return hashlib.sha256(value.encode() if isinstance(value, str) else value).hexdigest()


def run(*args, data=None):
    return subprocess.run(args, input=data, check=True, capture_output=True).stdout


class LocalProvider:
    """Loopback HTTP peer exercising the real streaming parser, never the fixture path."""
    def __init__(self, frames, hold=False):
        self.release = threading.Event()
        self.requests = []
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                length = int(self.headers.get('Content-Length', '0'))
                owner.requests.append({'body': json.loads(self.rfile.read(length)), 'authorization': self.headers.get('Authorization')})
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.send_header('Connection', 'close')
                self.end_headers()
                try:
                    for frame in frames:
                        self.wfile.write(frame); self.wfile.flush()
                    if hold: owner.release.wait(10)
                except (BrokenPipeError, ConnectionResetError):
                    pass
                self.close_connection = True

            def log_message(self, *args):
                pass

        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f'http://127.0.0.1:{self.server.server_port}/chat/completions'

    def close(self):
        self.release.set(); self.server.shutdown(); self.server.server_close(); self.thread.join(timeout=3)

    @staticmethod
    def frame(delta, finish=None):
        return ('data: ' + json.dumps({'choices': [{'delta': delta, 'finish_reason': finish}]}, ensure_ascii=False) + '\n\n').encode()


class Identity:
    """Use OpenSSL independently of the server's Crypto implementation."""
    def __init__(self, directory):
        self.key = directory / 'device.pem'
        run('openssl', 'genpkey', '-algorithm', 'EC', '-pkeyopt', 'ec_paramgen_curve:P-256', '-out', str(self.key))
        public = run('openssl', 'pkey', '-in', str(self.key), '-pubout', '-outform', 'DER')
        assert public[-65] == 4, 'expected uncompressed P-256 point'
        self.public = base64.b64encode(public[-64:]).decode()
        self.device_id = None

    def sign(self, data):
        der = run('openssl', 'dgst', '-sha256', '-sign', str(self.key), data=data)
        assert der[0] == 0x30 and der[2] == 2
        r_end = 4 + der[3]
        r = int.from_bytes(der[4:r_end], 'big')
        assert der[r_end] == 2
        s = int.from_bytes(der[r_end + 2:], 'big')
        return base64.b64encode(r.to_bytes(32, 'big') + s.to_bytes(32, 'big')).decode()

    def headers(self, method, path, body):
        timestamp, nonce = str(int(time.time())), str(uuid.uuid4())
        canonical = '\n'.join((method, path.split('?')[0], timestamp, nonce, sha(body)))
        return {'X-StudyRocket-Device': self.device_id,
                'X-StudyRocket-Timestamp': timestamp, 'X-StudyRocket-Nonce': nonce,
                'X-StudyRocket-Signature': self.sign(canonical.encode())}


class Fixture:
    def __init__(self, binary):
        self.temp = tempfile.TemporaryDirectory(prefix='studyrocket-cloud-acceptance-')
        self.base = Path(self.temp.name)
        self.repo = self.base / 'repository'
        self.state = self.base / 'state'
        self.repo.mkdir(); self.state.mkdir()
        self.write('PROFILE.md', '# Synthetic acceptance profile\n')
        self.write('AGENTS.md', '# Synthetic test instructions\n')
        self.write('笔记/a.md', 'original A\n')
        self.write('笔记/b.md', 'original B\n')
        self.binary = str(Path(binary).resolve())
        self.identity = Identity(self.base)
        self.process = None
        self.model_fixture = None
        self.upstream = None
        self.context_tokens = None
        self.log = open(self.base / 'server.log', 'ab')
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0)); self.port = sock.getsockname()[1]

    def write(self, path, text):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def cli(self, *args):
        return run(self.binary, *args).decode()

    def start(self, failpoint=None):
        env = os.environ.copy()
        for key in ('DEEPSEEK_API_KEY', 'OPENAI_API_KEY', 'STUDYROCKET_CLOUD_FAILPOINT'):
            env.pop(key, None)
        env.pop('STUDYROCKET_MODEL_CONTEXT_TOKENS', None)
        if self.context_tokens is not None:
            env['STUDYROCKET_MODEL_CONTEXT_TOKENS'] = str(self.context_tokens)
        args = [self.binary, 'serve', '--repository', str(self.repo), '--state', str(self.state),
                '--host', '127.0.0.1', '--port', str(self.port)]
        if failpoint:
            env['STUDYROCKET_CLOUD_FAILPOINT'] = failpoint
            args += ['--allow-test-failpoints']
        if self.model_fixture:
            if '--allow-test-failpoints' not in args: args += ['--allow-test-failpoints']
            args += ['--test-model-fixture', str(self.model_fixture)]
        if self.upstream:
            if '--allow-test-failpoints' not in args: args += ['--allow-test-failpoints']
            args += ['--test-upstream-url', self.upstream]
        self.process = subprocess.Popen(args, env=env, stdout=self.log, stderr=self.log)
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise AssertionError('server exited at startup: ' + (self.base / 'server.log').read_text()[-4000:])
            try:
                status, _ = self.request('GET', '/v1/health', auth=False)
                if status == 200:
                    return
            except (OSError, http.client.HTTPException):
                pass
            time.sleep(.05)
        raise AssertionError('server did not become healthy')

    def stop(self, kill=False):
        if self.process and self.process.poll() is None:
            self.process.kill() if kill else self.process.terminate()
            try: self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill(); self.process.wait(timeout=10)

    def close(self):
        self.stop(); self.log.close(); self.temp.cleanup()

    def pair(self):
        code = json.loads(self.cli('pair-code', '--state', str(self.state)))['code']
        status, result = self.request('POST', '/v1/pair', {
            'code': code, 'deviceName': 'Synthetic QA Device',
            'publicKey': self.identity.public, 'apiVersion': 1}, auth=False)
        assert status == 200, (status, result)
        self.identity.device_id = result['deviceID']

    def request(self, method, path, payload=None, auth=True, extra_headers=None):
        body = b'' if payload is None else json.dumps(payload, ensure_ascii=False, separators=(',', ':')).encode()
        headers = {'Content-Type': 'application/json'}
        if auth: headers.update(self.identity.headers(method, path, body))
        headers.update(extra_headers or {})
        connection = http.client.HTTPConnection('127.0.0.1', self.port, timeout=8)
        try:
            connection.request(method, path, body, headers)
            response = connection.getresponse()
            data = response.read()
            return response.status, json.loads(data) if data else None
        finally:
            connection.close()

    def manifest(self):
        status, value = self.request('GET', '/v1/files/manifest')
        assert status == 200, (status, value)
        return value

    def commit_request(self, updates, operation=None, manifest=None):
        manifest = manifest or self.manifest()
        hashes = {item['path']: item['hash'] for item in manifest['files']}
        return {'repositoryID': manifest['repositoryID'],
                'metadata': {'apiVersion': 1, 'baseRevision': manifest['revision'],
                             'idempotencyKey': operation or str(uuid.uuid4())},
                'files': [{'path': path, 'baseHash': hashes.get(path), 'content': content}
                          for path, content in updates.items()]}

    def model_responses(self, messages):
        self.model_fixture = self.base / 'model-fixture.json'
        self.model_fixture.write_text(json.dumps([{'choices': [{'message': message, 'finish_reason': 'tool_calls' if message.get('tool_calls') else 'stop'}]} for message in messages]))

    def events(self, after=0, count=1):
        path = '/v1/events'
        headers = self.identity.headers('GET', path, b'')
        headers['Last-Event-ID'] = str(after)
        connection = http.client.HTTPConnection('127.0.0.1', self.port, timeout=3)
        values, current = [], {}
        try:
            connection.request('GET', path, headers=headers)
            response = connection.getresponse()
            assert response.status == 200, response.status
            while len(values) < count:
                line = response.readline().decode().strip()
                if line.startswith('id:'): current['id'] = int(line[3:].strip())
                if line.startswith('data:'): current['data'] = json.loads(line[5:].strip())
                if not line and 'id' in current and 'data' in current:
                    values.append(current); current = {}
            return values
        finally:
            connection.close()


class Acceptance(unittest.TestCase):
    binary = None

    def setUp(self):
        self.f = Fixture(self.binary)
        self.addCleanup(self.f.close)
        self.f.start(); self.f.pair()

    def assert_terminal_sse_matches_history(self, terminal):
        with sqlite3.connect(self.f.state / 'cloud.sqlite') as db:
            events = [(seq, json.loads(body)) for seq, body in db.execute('SELECT seq,body FROM events ORDER BY seq')]
        seq, _ = next((seq, event) for seq, event in reversed(events)
                      if event.get('chat', {}).get('turnID') == terminal['turnID'] and event['chat']['kind'] == 'status')
        emitted = self.f.events(after=seq - 1, count=1)[0]['data']['chat']
        self.assertEqual(emitted['status'], terminal['status'])
        self.assertEqual(emitted.get('issueCode'), terminal.get('issueCode'))
        self.assertEqual(emitted.get('text'), terminal.get('message'))

    def test_authentication_boundaries(self):
        for path in ('/v1/snapshot', '/v1/chat/history', '/v1/proposals', '/v1/files/manifest', '/v1/events'):
            with self.subTest(path=path):
                status, result = self.f.request('GET', path, auth=False)
                self.assertEqual(status, 401, result)
        before = (self.f.repo / '笔记/a.md').read_bytes()
        status, _ = self.f.request('POST', '/v1/files/commit', self.f.commit_request({'笔记/a.md': 'forbidden'}), auth=False)
        self.assertEqual(status, 401)
        self.assertEqual((self.f.repo / '笔记/a.md').read_bytes(), before)

    def test_signature_and_nonce_replay_rejected(self):
        path = '/v1/files/manifest'
        headers = self.f.identity.headers('GET', path, b'')
        self.assertEqual(self.f.request('GET', path, extra_headers=headers)[0], 200)
        status, result = self.f.request('GET', path, extra_headers=headers)
        self.assertEqual(status, 401, result)
        headers = self.f.identity.headers('GET', path, b'')
        headers['X-StudyRocket-Signature'] = base64.b64encode(bytes(64)).decode()
        self.assertEqual(self.f.request('GET', path, extra_headers=headers)[0], 401)
        # A correctly signed request from the distant past must also be rejected.
        timestamp, nonce = '1', str(uuid.uuid4())
        headers = {'X-StudyRocket-Device': self.f.identity.device_id,
                   'X-StudyRocket-Timestamp': timestamp, 'X-StudyRocket-Nonce': nonce,
                   'X-StudyRocket-Signature': self.f.identity.sign('\n'.join(('GET', path, timestamp, nonce, sha(b''))).encode())}
        self.assertEqual(self.f.request('GET', path, extra_headers=headers)[0], 401)

    def test_duplicate_and_payload_collision_survive_restart(self):
        request = self.f.commit_request({'笔记/a.md': 'accepted once\n'})
        status, receipt = self.f.request('POST', '/v1/files/commit', request)
        self.assertEqual(status, 200, receipt)
        self.assertEqual(self.f.request('POST', '/v1/files/commit', request), (status, receipt))
        self.f.stop(kill=True); self.f.start()
        self.assertEqual(self.f.request('POST', '/v1/files/commit', request), (status, receipt))
        # JSON object order is not payload identity. Native encoders may reorder keys.
        reordered = {key: request[key] for key in reversed(request)}
        reordered['metadata'] = {key: request['metadata'][key] for key in reversed(request['metadata'])}
        self.assertEqual(self.f.request('POST', '/v1/files/commit', reordered), (status, receipt))
        request['files'][0]['content'] = 'must never overwrite\n'
        status, result = self.f.request('POST', '/v1/files/commit', request)
        self.assertIn(status, (409, 422), result)
        self.assertEqual((self.f.repo / '笔记/a.md').read_text(), 'accepted once\n')

    def test_stale_hash_rejects_whole_group(self):
        request = self.f.commit_request({'笔记/a.md': 'new A\n', '笔记/b.md': 'new B\n'})
        self.f.write('笔记/b.md', 'external B\n')
        status, result = self.f.request('POST', '/v1/files/commit', request)
        self.assertEqual(status, 409, result)
        self.assertEqual((self.f.repo / '笔记/a.md').read_text(), 'original A\n')
        self.assertEqual((self.f.repo / '笔记/b.md').read_text(), 'external B\n')

    def test_paths_cannot_escape_repository(self):
        outside = self.f.base / 'outside'
        outside.mkdir(); (outside / 'secret.md').write_text('untouched\n')
        (self.f.repo / '笔记/link.md').symlink_to(outside / 'secret.md')
        (self.f.repo / '笔记/linked').symlink_to(outside, target_is_directory=True)
        for path in ('../outside/secret.md', '笔记/link.md', '笔记/linked/secret.md', '/tmp/escape.md', 'apps/forbidden.md'):
            with self.subTest(path=path):
                request = self.f.commit_request({path: 'escaped\n'})
                status, result = self.f.request('POST', '/v1/files/commit', request)
                self.assertIn(status, (400, 403, 409, 422), result)
                status, result = self.f.request('POST', '/v1/files/read', {'path': path})
                self.assertIn(status, (400, 403, 404, 422), result)
        self.assertEqual((outside / 'secret.md').read_text(), 'untouched\n')

    def test_two_clients_racing_cannot_overwrite(self):
        manifest = self.f.manifest()
        requests = [self.f.commit_request({'笔记/a.md': value}, manifest=manifest) for value in ('race A\n', 'race B\n')]
        with concurrent.futures.ThreadPoolExecutor(2) as pool:
            results = list(pool.map(lambda request: self.f.request('POST', '/v1/files/commit', request), requests))
        self.assertEqual(sorted(status for status, _ in results), [200, 409], results)

    def _crash_recovery(self, failpoint):
        request = self.f.commit_request({'笔记/a.md': 'committed A\n', '笔记/b.md': 'committed B\n'})
        self.f.stop(); self.f.start(failpoint)
        with self.assertRaises((OSError, http.client.HTTPException)):
            self.f.request('POST', '/v1/files/commit', request)
        self.assertEqual(self.f.process.wait(timeout=10), 86, 'failpoint did not terminate process')
        if failpoint == 'after_first_rename':
            contents = [(self.f.repo / p).read_text() for p in ('笔记/a.md', '笔记/b.md')]
            self.assertEqual(sum(c.startswith('committed') for c in contents), 1, contents)
        self.f.start()
        self.assertEqual((self.f.repo / '笔记/a.md').read_text(), 'committed A\n')
        self.assertEqual((self.f.repo / '笔记/b.md').read_text(), 'committed B\n')
        status, result = self.f.request('POST', '/v1/files/commit', request)
        self.assertEqual(status, 200, result)
        status, result = self.f.request('GET', '/v1/operations/' + request['metadata']['idempotencyKey'])
        self.assertEqual(status, 200, result)
        self.assertIn(result['state'], ('committed', 'completed', 'succeeded'))

    def test_crash_after_prepare(self):
        self._crash_recovery('after_prepare')

    def test_crash_after_first_rename(self):
        self._crash_recovery('after_first_rename')

    def test_repository_identity_survives_move(self):
        original = self.f.manifest()['repositoryID']
        self.f.stop()
        new = self.f.base / 'moved-repository'
        self.f.repo.rename(new); self.f.repo = new
        self.f.start()
        self.assertEqual(self.f.manifest()['repositoryID'], original)

    def test_fact_replay_preserves_exactly_one_entry(self):
        status, snapshot = self.f.request('GET', '/v1/snapshot')
        self.assertEqual(status, 200, snapshot)
        operation = str(uuid.uuid4())
        today = datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8))).date().isoformat()
        request = {'repositoryID': self.f.manifest()['repositoryID'],
                   'metadata': {'apiVersion': 1, 'baseRevision': snapshot['revision'], 'idempotencyKey': operation},
                   'entry': {'id': operation, 'date': today, 'text': 'Synthetic fact saved exactly once'}}
        status, result = self.f.request('POST', '/v1/facts', request)
        self.assertEqual(status, 200, result)
        self.f.stop(kill=True); self.f.start()
        self.assertEqual(self.f.request('POST', '/v1/facts', request)[0], 200)
        content = (self.f.repo / '工作台/每日记录' / (today[:7] + '.md')).read_text()
        self.assertEqual(content.count('Synthetic fact saved exactly once'), 1)
        request['entry']['text'] = 'Different payload under same ID must fail'
        status, result = self.f.request('POST', '/v1/facts', request)
        self.assertIn(status, (409, 422), result)
        self.assertEqual((self.f.repo / '工作台/每日记录' / (today[:7] + '.md')).read_text(), content)

    def test_sse_reconnect_replays_only_missed_durable_events(self):
        request = self.f.commit_request({'笔记/a.md': 'first event\n'})
        self.assertEqual(self.f.request('POST', '/v1/files/commit', request)[0], 200)
        first = self.f.events(count=1)[0]
        request = self.f.commit_request({'笔记/b.md': 'second event\n'})
        self.assertEqual(self.f.request('POST', '/v1/files/commit', request)[0], 200)
        self.f.stop(kill=True); self.f.start()
        second = self.f.events(after=first['id'], count=1)[0]
        self.assertGreater(second['id'], first['id'])
        self.assertEqual(second['data']['kind'], 'snapshot')
        self.assertEqual(self.f.events(after=first['id'], count=1)[0], second, 'Reconnect must replay the same persisted event')

    def _create_proposals(self):
        def tool(name, arguments, call_id):
            return {'role': 'assistant', 'content': None, 'tool_calls': [
                {'id': call_id, 'type': 'function', 'function': {'name': name, 'arguments': json.dumps(arguments)}}]}
        self.f.stop()
        self.f.model_responses([
            tool('read_file', {'path': '笔记/a.md'}, 'read_a'),
            tool('propose_changes', {'path': '笔记/a.md', 'baseHash': sha('original A\n'), 'content': 'preview A\n', 'reason': 'synthetic acceptance'}, 'propose_a'),
            tool('read_file', {'path': '笔记/b.md'}, 'read_b'),
            tool('propose_changes', {'path': '笔记/b.md', 'baseHash': sha('original B\n'), 'content': 'preview B\n', 'reason': 'synthetic acceptance'}, 'propose_b'),
            {'role': 'assistant', 'content': 'Synthetic preview is ready for explicit confirmation.'}])
        self.f.start()
        operation = str(uuid.uuid4())
        request = {'text': 'Synthetic request: propose both fixture edits.', 'clientRequestID': operation, 'apiVersion': 1}
        status, result = self.f.request('POST', '/v1/chat/send', request)
        self.assertIn(status, (200, 202), result)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            status, value = self.f.request('GET', '/v1/operations/' + operation)
            if status == 200 and value['state'] != 'running': break
            time.sleep(.05)
        self.assertEqual(value['state'], 'succeeded', value)
        status, result = self.f.request('GET', '/v1/proposals')
        self.assertEqual(status, 200, result)
        self.assertEqual(len(result['proposals']), 2, result)
        return result['proposals']

    def _start_model_run(self, responses, text='Synthetic agent acceptance'):
        self.f.stop()
        self.f.model_responses([])
        for response in responses:
            for choice in response.get('choices', []):
                choice.setdefault('finish_reason', 'tool_calls' if choice.get('message', {}).get('tool_calls') else 'stop')
        self.f.model_fixture.write_text(json.dumps(responses))
        self.f.start()
        operation = str(uuid.uuid4())
        request = {'text': text, 'clientRequestID': operation, 'apiVersion': 1}
        status, result = self.f.request('POST', '/v1/chat/send', request)
        self.assertIn(status, (200, 202), result)
        return operation

    def _terminal(self, operation, timeout=15):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            status, history = self.f.request('GET', '/v1/chat/history')
            self.assertEqual(status, 200, history)
            terminal = next((t for t in history.get('terminalTurns', []) if t['turnID'] == operation), None)
            if terminal: return terminal, history
            time.sleep(.05)
        self.fail('Agent failed to publish a durable terminal state')

    @staticmethod
    def _tool_response(name, arguments, call_id='tool-call', reasoning=None):
        message = {'role': 'assistant', 'content': None, 'tool_calls': [
            {'id': call_id, 'type': 'function', 'function': {'name': name, 'arguments': json.dumps(arguments)}}]}
        if reasoning is not None: message['reasoning_content'] = reasoning
        return {'choices': [{'message': message, 'finish_reason': 'tool_calls'}]}

    def test_agent_rejects_unread_hash_and_forbidden_tools(self):
        propose = {'path': '笔记/a.md', 'baseHash': sha('original A\n'), 'content': 'unread proposal\n', 'reason': 'synthetic'}
        operation = self._start_model_run([
            self._tool_response('propose_changes', propose, 'unread'),
            self._tool_response('exec', {'command': 'touch prohibited'}, 'forbidden'),
            self._tool_response('read_file', {'path': '../outside.md'}, 'escape'),
            {'choices': [{'message': {'role': 'assistant', 'content': 'The invalid operations were rejected.'}}]}])
        terminal, _ = self._terminal(operation)
        self.assertEqual(terminal['status'], 'completed')
        self.assertEqual(self.f.request('GET', '/v1/proposals')[1]['proposals'], [])
        self.assertEqual((self.f.repo / '笔记/a.md').read_text(), 'original A\n')
        self.assertFalse((self.f.repo / 'prohibited').exists())

    def test_agent_tool_budget_has_explicit_persisted_failure(self):
        operation = self._start_model_run([self._tool_response('list_files', {}, f'round-{i}') for i in range(12)])
        terminal, _ = self._terminal(operation)
        self.assertEqual(terminal['status'], 'failed')
        self.assertEqual(terminal['issueCode'], 'tool_budget')
        self.assert_terminal_sse_matches_history(terminal)
        self.f.stop(kill=True); self.f.start()
        self.assertEqual(self._terminal(operation)[0], terminal)

    def test_agent_output_budget_is_failure_not_false_completion(self):
        operation = self._start_model_run([{'choices': [{'finish_reason': 'length', 'message': {'role': 'assistant', 'content': 'Truncated response'}}]}])
        terminal, _ = self._terminal(operation)
        self.assertEqual(terminal['status'], 'failed')
        self.assertEqual(terminal['issueCode'], 'output_budget')
        self.assertEqual(self.f.request('GET', '/v1/proposals')[1]['proposals'], [])

    def test_agent_preserves_reasoning_and_tool_ids_between_rounds(self):
        reasoning = 'SYNTHETIC INTERNAL FIELD\nUnicode: 保留原样'
        first = self._tool_response('read_file', {'path': '笔记/a.md'}, 'stable-tool-call', reasoning=reasoning)
        operation = self._start_model_run([first, {'choices': [{'message': {'role': 'assistant', 'content': 'Visible final answer.'}}]}])
        terminal, history = self._terminal(operation)
        self.assertEqual(terminal['status'], 'completed')
        requests = json.loads(Path(str(self.f.model_fixture) + '.requests.json').read_text())
        self.assertEqual(len(requests), 2)
        assistant = next(m for m in requests[1] if m.get('tool_calls'))
        self.assertEqual(assistant, first['choices'][0]['message'], 'Reasoning and tool call fields must survive unchanged')
        tool_result = next(m for m in requests[1] if m.get('tool_call_id') == 'stable-tool-call')
        self.assertEqual(json.loads(tool_result['content'])['hash'], sha('original A\n'))
        self.assertFalse(any(reasoning in m['text'] for m in history['messages']), 'Internal reasoning must not appear in visible history')

    def test_agent_cancel_during_provider_wait_is_prompt_and_durable(self):
        operation = self._start_model_run([{'_test_delay_ms': 30_000, 'choices': [{'message': {'role': 'assistant', 'content': 'Must not complete after cancellation'}}]}])
        transcript = Path(str(self.f.model_fixture) + '.requests.json')
        deadline = time.monotonic() + 3
        while not transcript.exists() and time.monotonic() < deadline: time.sleep(.02)
        self.assertTrue(transcript.exists(), 'Fixture must enter suspended provider work before cancellation')
        start = time.monotonic()
        status, result = self.f.request('POST', '/v1/chat/interrupt', {'turnID': operation, 'operationID': str(uuid.uuid4()), 'apiVersion': 1})
        self.assertEqual(status, 200, result)
        terminal, history = self._terminal(operation, timeout=3)
        self.assertLess(time.monotonic() - start, 3)
        self.assertEqual(terminal['status'], 'interrupted')
        self.assert_terminal_sse_matches_history(terminal)
        self.assertFalse(any(m['text'] == 'Must not complete after cancellation' for m in history['messages']))
        self.f.stop(kill=True); self.f.start()
        self.assertEqual(self._terminal(operation)[0], terminal)

    def test_agent_context_budget_has_explicit_failure(self):
        self.f.context_tokens = 65_536
        self.f.write('笔记/large.md', 'synthetic text ' * 1800)
        operation = self._start_model_run([self._tool_response('read_file', {'path': '笔记/large.md'}, f'large-{i}') for i in range(8)])
        terminal, _ = self._terminal(operation)
        self.assertEqual(terminal['status'], 'failed')
        self.assertEqual(terminal['issueCode'], 'context_budget')
        self.assert_terminal_sse_matches_history(terminal)

    def test_chat_request_id_replay_cannot_duplicate_turn(self):
        text = 'Synthetic idempotent chat'
        operation = self._start_model_run([{'choices': [{'message': {'role': 'assistant', 'content': 'One answer only'}}]}], text=text)
        self._terminal(operation)
        self.f.stop(kill=True); self.f.start()
        request = {'text': text, 'clientRequestID': operation, 'apiVersion': 1}
        status, history = self.f.request('POST', '/v1/chat/send', request)
        self.assertEqual(status, 202, history)
        self.assertEqual(sum(m['text'] == text for m in history['messages']), 1)
        self.assertEqual(sum(m['text'] == 'One answer only' for m in history['messages']), 1)
        request['text'] = 'Different text under the same request ID'
        status, result = self.f.request('POST', '/v1/chat/send', request)
        self.assertIn(status, (409, 422), result)

    def _start_http_run(self, provider):
        self.addCleanup(provider.close)
        self.f.stop(); self.f.upstream = provider.url; self.f.start()
        operation = str(uuid.uuid4())
        status, result = self.f.request('POST', '/v1/chat/send', {'text': 'Synthetic real HTTP streaming check', 'clientRequestID': operation, 'apiVersion': 1})
        self.assertEqual(status, 202, result)
        return operation

    def test_real_http_stream_requires_done_and_preserves_truncated_text(self):
        provider = LocalProvider([LocalProvider.frame({'content': 'Synthetic truncated visible answer'})])
        operation = self._start_http_run(provider)
        terminal, history = self._terminal(operation)
        self.assertEqual(terminal['status'], 'failed')
        self.assertEqual(terminal['issueCode'], 'provider_stream_incomplete')
        answer = next(m for m in history['messages'] if m['id'] == operation + '/assistant')
        self.assertIn('Synthetic truncated visible answer', answer['text'])
        self.assertEqual(answer['status'], 'failed', 'History must not relabel a truncated answer completed')
        self.assertIsNone(provider.requests[0]['authorization'], 'Test loopback transport must not receive a provider credential')

    def test_real_http_complete_stream_has_visible_text_without_reasoning(self):
        provider = LocalProvider([LocalProvider.frame({'reasoning_content': 'SYNTHETIC PRIVATE REASONING'}),
                                  LocalProvider.frame({'content': '完整 synthetic answer'}),
                                  LocalProvider.frame({}, 'stop'), b'data: [DONE]\n\n'])
        operation = self._start_http_run(provider)
        terminal, history = self._terminal(operation)
        self.assertEqual(terminal['status'], 'completed')
        answer = next(m for m in history['messages'] if m['id'] == operation + '/assistant')
        self.assertEqual(answer['text'], '完整 synthetic answer')
        self.assertFalse(any('SYNTHETIC PRIVATE REASONING' in m['text'] for m in history['messages']))

    def test_real_http_cancel_keeps_partial_and_does_not_wait_for_eof(self):
        provider = LocalProvider([LocalProvider.frame({'content': 'Visible before cancellation'})], hold=True)
        operation = self._start_http_run(provider)
        events = self.f.events(count=2)
        self.assertTrue(any(e['data'].get('chat', {}).get('kind') == 'delta' for e in events))
        start = time.monotonic()
        self.f.request('POST', '/v1/chat/interrupt', {'turnID': operation, 'operationID': str(uuid.uuid4()), 'apiVersion': 1})
        terminal, history = self._terminal(operation, timeout=3)
        self.assertLess(time.monotonic() - start, 3)
        self.assertEqual(terminal['status'], 'interrupted')
        self.assertTrue(any('Visible before cancellation' in m['text'] for m in history['messages']))

    def test_real_http_crash_recovers_visible_partial_without_resending(self):
        provider = LocalProvider([LocalProvider.frame({'content': 'Visible before process crash'})], hold=True)
        operation = self._start_http_run(provider)
        events = self.f.events(count=2)
        self.assertTrue(any(e['data'].get('chat', {}).get('kind') == 'delta' for e in events))
        self.f.stop(kill=True); self.f.start()
        terminal, history = self._terminal(operation)
        self.assertEqual(terminal['status'], 'interrupted')
        self.assertEqual(terminal['issueCode'], 'server_restarted')
        answer = next(m for m in history['messages'] if m['id'] == operation + '/assistant')
        self.assertEqual(answer['text'], 'Visible before process crash')
        self.assertEqual(len(provider.requests), 1, 'Restart must not silently create a second provider request')

    def test_proposals_are_durable_but_write_only_after_signed_confirmation(self):
        proposals = self._create_proposals()
        self.assertEqual((self.f.repo / '笔记/a.md').read_text(), 'original A\n')
        self.assertEqual((self.f.repo / '笔记/b.md').read_text(), 'original B\n')
        self.f.stop(kill=True); self.f.start()
        self.assertEqual(self.f.request('GET', '/v1/proposals')[1]['proposals'], proposals)
        request = {'proposalIDs': [p['id'] for p in proposals], 'authorization': '',
                   'metadata': {'baseRevision': self.f.manifest()['revision'], 'idempotencyKey': str(uuid.uuid4()), 'apiVersion': 1}}
        self.assertEqual(self.f.request('POST', '/v1/proposals/apply', request)[0], 403)
        self.assertEqual((self.f.repo / '笔记/a.md').read_text(), 'original A\n')
        status, challenge = self.f.request('GET', '/v1/proposals/challenge')
        self.assertEqual(status, 200, challenge)
        token = challenge['challenge']
        request['authorization'] = token + '|' + self.f.identity.sign(('studyrocket-face-id-v1\n' + token).encode())
        status, result = self.f.request('POST', '/v1/proposals/apply', request)
        self.assertEqual(status, 200, result)
        self.assertEqual((self.f.repo / '笔记/a.md').read_text(), 'preview A\n')
        self.assertEqual((self.f.repo / '笔记/b.md').read_text(), 'preview B\n')
        self.assertEqual(self.f.request('GET', '/v1/proposals')[1]['proposals'], [])
        self.assertEqual(self.f.request('POST', '/v1/proposals/apply', request)[0], 200, 'Lost receipt replay must not require another confirmation')

    def test_complete_imported_history_paginates_and_reimport_deduplicates(self):
        source = self.f.base / 'visible-history.jsonl'
        messages = [{'id': 'synthetic-visible-' + str(i), 'sourceThreadID': 'synthetic-legacy-thread',
                     'role': 'user' if i % 2 == 0 else 'assistant', 'text': f'Visible synthetic history {i}: 中文正文\nsecond line',
                     'date': float(i), 'source': 'codex-import'} for i in range(451)]
        source.write_text('\n'.join(json.dumps(m, ensure_ascii=False) for m in messages) + '\n')
        self.f.stop()
        self.f.cli('history-import', '--state', str(self.f.state), '--file', str(source))
        self.f.cli('history-import', '--state', str(self.f.state), '--file', str(source))
        self.f.start()
        found, cursor = [], 0
        while True:
            status, page = self.f.request('GET', f'/v1/history?after={cursor}&limit=37')
            self.assertEqual(status, 200, page)
            self.assertEqual(page['total'], len(messages))
            found.extend(page['messages'])
            if page.get('nextCursor') is None: break
            self.assertGreater(page['nextCursor'], cursor)
            cursor = page['nextCursor']
        self.assertEqual(found, messages, 'Every visible message, ordering and exact text must survive import/restart')
        self.f.stop(kill=True); self.f.start()
        self.assertEqual(self.f.request('GET', '/v1/history?limit=1')[1]['total'], 451)

    def test_stale_proposal_cannot_partially_apply(self):
        proposals = self._create_proposals()
        self.f.write('笔记/b.md', 'external edit after preview\n')
        status, challenge = self.f.request('GET', '/v1/proposals/challenge')
        self.assertEqual(status, 200, challenge)
        token = challenge['challenge']
        request = {'proposalIDs': [p['id'] for p in proposals],
                   'authorization': token + '|' + self.f.identity.sign(('studyrocket-face-id-v1\n' + token).encode()),
                   'metadata': {'baseRevision': self.f.manifest()['revision'], 'idempotencyKey': str(uuid.uuid4()), 'apiVersion': 1}}
        status, result = self.f.request('POST', '/v1/proposals/apply', request)
        self.assertEqual(status, 409, result)
        self.assertEqual((self.f.repo / '笔记/a.md').read_text(), 'original A\n')
        self.assertEqual((self.f.repo / '笔记/b.md').read_text(), 'external edit after preview\n')
        self.assertEqual(len(self.f.request('GET', '/v1/proposals')[1]['proposals']), 2)

    def test_repository_rejects_second_writer_with_different_state(self):
        other_state = self.f.base / 'other-state'
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0)); other_port = sock.getsockname()[1]
        result = subprocess.run([self.f.binary, 'serve', '--repository', str(self.f.repo),
                                 '--state', str(other_state), '--host', '127.0.0.1', '--port', str(other_port)],
                                capture_output=True, timeout=10)
        self.assertNotEqual(result.returncode, 0, 'A second state directory must not create another writer for the same repository')
        self.assertIn(b'writer', result.stderr.lower())
        self.assertEqual(self.f.request('GET', '/v1/files/manifest')[0], 200)

    def test_live_backup_restores_files_identity_versions_and_receipts(self):
        original_id = self.f.manifest()['repositoryID']
        request = self.f.commit_request({'笔记/a.md': 'backed-up version\n'})
        status, receipt = self.f.request('POST', '/v1/files/commit', request)
        self.assertEqual(status, 200, receipt)
        status, versions = self.f.request('GET', '/v1/versions')
        self.assertEqual(status, 200, versions)
        self.assertEqual(versions['versions'][0]['operationID'], request['metadata']['idempotencyKey'])
        version_request = {'id': versions['versions'][0]['id'], 'path': '笔记/a.md'}
        self.assertEqual(self.f.request('POST', '/v1/versions/read', version_request)[1]['content'], 'backed-up version\n')
        backup = self.f.base / 'consistent-backup'
        self.f.cli('backup', '--repository', str(self.f.repo), '--state', str(self.f.state), '--output', str(backup))
        manifest = json.loads((backup / 'manifest.json').read_text())
        self.assertEqual(manifest['repositoryID'], original_id)
        for item in manifest['files']:
            content = (backup / 'repository' / item['path']).read_bytes()
            self.assertEqual(sha(content), item['sha256'])
            self.assertEqual(len(content), item['bytes'])
        request2 = self.f.commit_request({'笔记/a.md': 'later not backed up\n'})
        self.assertEqual(self.f.request('POST', '/v1/files/commit', request2)[0], 200)
        self.f.stop()
        restored_state = self.f.base / 'restored-state'; restored_state.mkdir()
        shutil.copy2(backup / 'cloud.sqlite', restored_state / 'cloud.sqlite')
        self.f.repo, self.f.state = backup / 'repository', restored_state
        self.f.start()
        self.assertEqual(self.f.manifest()['repositoryID'], original_id)
        self.assertEqual((self.f.repo / '笔记/a.md').read_text(), 'backed-up version\n')
        self.assertEqual(self.f.request('POST', '/v1/files/commit', request), (status, receipt), 'Restored receipt must prevent duplicate application')
        self.assertEqual(len(self.f.request('GET', '/v1/versions')[1]['versions']), 1)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', required=True)
    args, remaining = parser.parse_known_args()
    Acceptance.binary = args.binary
    unittest.main(argv=[__file__, *remaining], verbosity=2)
