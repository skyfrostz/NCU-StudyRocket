#!/usr/bin/env python3
"""SIGTERM black-box checks with isolated synthetic repositories and loopback peers.

Never uses production credentials, services, files or an external model endpoint.
"""
import argparse
import hashlib
import http.client
import json
import signal
import sqlite3
import subprocess
import time
import unittest
import uuid

from cloud_acceptance import Fixture, LocalProvider


class GracefulShutdownAcceptance(unittest.TestCase):
    binary = None

    def setUp(self):
        self.fixture = Fixture(self.binary)
        self.addCleanup(self.fixture.close)
        self.streams = []
        self.addCleanup(self.close_streams)

    def close_streams(self):
        for connection, response in self.streams:
            response.close()
            connection.close()
        self.streams.clear()

    def start(self, provider=None):
        if provider:
            self.addCleanup(provider.close)
            self.fixture.upstream = provider.url
        self.fixture.start()
        self.fixture.pair()

    def open_stream(self):
        path = '/v1/events'
        connection = http.client.HTTPConnection('127.0.0.1', self.fixture.port, timeout=4)
        connection.request('GET', path, headers=self.fixture.identity.headers('GET', path, b''))
        response = connection.getresponse()
        self.assertEqual(response.status, 200)
        self.streams.append((connection, response))
        # Wait for a complete frame before SIGTERM, proving the response body
        # is already executing rather than merely waiting for an HTTP request.
        frame = []
        while True:
            line = response.readline()
            self.assertTrue(line, 'SSE closed before shutdown')
            frame.append(line)
            if line == b'\n':
                break
        self.assertIn(b'data:', b''.join(frame))

    def repository_hashes(self):
        return {str(path.relative_to(self.fixture.repo)): hashlib.sha256(path.read_bytes()).hexdigest()
                for path in self.fixture.repo.rglob('*') if path.is_file()}

    def terminate_promptly(self):
        before = self.repository_hashes()
        start = time.monotonic()
        self.fixture.process.send_signal(signal.SIGTERM)
        try:
            code = self.fixture.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.fixture.process.kill()
            self.fixture.process.wait(timeout=3)
            self.fail('SIGTERM did not finish within 3 seconds; synthetic fixture required SIGKILL')
        elapsed = time.monotonic() - start
        self.assertEqual(code, 0, 'Graceful service completion must exit successfully')
        self.assertEqual(self.repository_hashes(), before, 'Shutdown must not rewrite repository files')
        for _, response in self.streams:
            response.read()  # Completed chunked body must reach EOF, not reset mid-frame.
        self.close_streams()
        print(f'  SIGTERM exit=0 in {elapsed:.3f}s; repository bytes unchanged', flush=True)

    def test_idle_without_sse(self):
        self.start()
        original = self.fixture.manifest()
        self.terminate_promptly()
        self.fixture.start()
        self.assertEqual(self.fixture.manifest(), original)

    def test_open_sse_finishes_and_releases_http_service(self):
        self.start()
        self.open_stream()
        self.terminate_promptly()

    def active_model_shutdown(self, with_sse):
        text = 'Synthetic visible partial before SIGTERM'
        provider = LocalProvider([LocalProvider.frame({'content': text})], hold=True)
        self.start(provider)
        operation = str(uuid.uuid4())
        status, result = self.fixture.request('POST', '/v1/chat/send', {
            'text': 'Synthetic graceful shutdown check', 'clientRequestID': operation, 'apiVersion': 1})
        self.assertEqual(status, 202, result)
        deadline = time.monotonic() + 3
        while True:
            with sqlite3.connect(self.fixture.state / 'cloud.sqlite') as db:
                partial = db.execute('SELECT text FROM partials WHERE id=?', (operation,)).fetchone()
            if partial and partial[0] == text:
                break
            self.assertLess(time.monotonic(), deadline, 'Model partial was not durably visible')
            time.sleep(.02)
        self.assertEqual(len(provider.requests), 1)
        if with_sse:
            self.open_stream()
        self.terminate_promptly()
        # Preserve the existing restart contract: do not silently finish or
        # resend the uncompleted provider request during graceful shutdown.
        self.fixture.start()
        history = self.fixture.request('GET', '/v1/chat/history')[1]
        terminal = next(value for value in history['terminalTurns'] if value['turnID'] == operation)
        self.assertEqual(terminal['status'], 'interrupted')
        self.assertEqual(terminal['issueCode'], 'server_restarted')
        self.assertEqual(next(value['text'] for value in history['messages'] if value['id'] == operation + '/assistant'), text)
        self.assertEqual(len(provider.requests), 1, 'Restart must not issue a second model request')
        with sqlite3.connect(self.fixture.state / 'cloud.sqlite') as db:
            state, body = db.execute('SELECT state,body FROM turns WHERE id=?', (operation,)).fetchone()
            self.assertEqual(state, 'interrupted')
            self.assertEqual(json.loads(body)['issueCode'], 'server_restarted')
            self.assertIsNone(db.execute('SELECT text FROM partials WHERE id=?', (operation,)).fetchone())

    def test_active_model_without_sse_retains_restart_boundary(self):
        self.active_model_shutdown(with_sse=False)

    def test_active_model_with_sse_retains_restart_boundary(self):
        self.active_model_shutdown(with_sse=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', required=True)
    args, remaining = parser.parse_known_args()
    GracefulShutdownAcceptance.binary = args.binary
    unittest.main(argv=[__file__, *remaining], verbosity=2)
