#!/usr/bin/env python3
"""Synthetic Chinese context and exact-edit acceptance; no real user text or API.

The source sizes reproduce the reported production shape, not its contents.
Loopback usage values are explicit test doubles, never tokenizer measurements.
"""
import argparse
import datetime
import http.server
import json
import re
from pathlib import Path
import sqlite3
import threading
import time
import unittest
import uuid

import cloud_acceptance as qa

TIMETABLE = '工作台/学期/2026秋季个人课表.md'
OLD = '| fixture-event | 2026-11-14 | 18:00 | 21:00 | 羽毛球训练 | 合成场地 | 合成活动 |'
NEW = OLD.replace('18:00 | 21:00', '19:00 | 22:00')
REQUEST = '本周周六晚上的羽毛球训练时间改为7:00到10:00'


def sized(prefix, byte_count):
    remaining = byte_count - len(prefix.encode())
    assert remaining >= 0
    return prefix + '合成资料' * (remaining // 12) + 'x' * (remaining % 12)


def tool(name, args, call_id):
    return {'id': call_id, 'type': 'function', 'function': {
        'name': name, 'arguments': json.dumps(args, ensure_ascii=False)}}


def assistant(calls, reasoning='完整保留的合成推理。'):
    return {'content': None, 'reasoning_content': reasoning, 'tool_calls': calls}


def valid_usage(prompt=12_000):
    return {'prompt_tokens': prompt, 'completion_tokens': 100, 'total_tokens': prompt + 100}


class ScriptedProvider:
    def __init__(self, respond, usage=lambda body, index: valid_usage()):
        self.requests = []
        self.errors = []
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                owner.requests.append(body)
                index = len(owner.requests) - 1
                try:
                    message = respond(body, index)
                    delta = dict(message)
                    if message.get('tool_calls'):
                        delta['tool_calls'] = [dict(call, index=i) for i, call in enumerate(message['tool_calls'])]
                    finish = 'tool_calls' if message.get('tool_calls') else 'stop'
                    frames = [qa.LocalProvider.frame(delta, finish)]
                    counts = usage(body, index)
                    if counts is not None:
                        # Exercise the actual SSE parser's empty-choices usage frame.
                        frames.append(('data: ' + json.dumps({'choices': [], 'usage': counts}) + '\n\n').encode())
                    frames.append(b'data: [DONE]\n\n')
                    self.send_response(200)
                    self.send_header('Content-Type', 'text/event-stream')
                    self.send_header('Connection', 'close')
                    self.end_headers()
                    for frame in frames:
                        self.wfile.write(frame)
                    self.wfile.flush()
                except Exception as error:
                    owner.errors.append(repr(error))
                    self.send_error(500)
                self.close_connection = True

            def log_message(self, *args):
                pass

        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f'http://127.0.0.1:{self.server.server_port}/chat/completions'

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=3)


class Acceptance(unittest.TestCase):
    binary = None

    def setUp(self):
        self.f = qa.Fixture(self.binary)
        self.addCleanup(self.f.close)
        self.required = {
            'AGENTS.md': sized('# SYNTHETIC_REQUIRED_RULES\n', 10_429),
            'PROFILE.md': sized('# SYNTHETIC_REQUIRED_PROFILE\n', 10_757),
            '工作台/助理偏好与习惯.md': sized('# SYNTHETIC_REQUIRED_PREFERENCES\n', 2_680),
        }
        for path, text in self.required.items():
            self.f.write(path, text)
        block = '\n'.join([
            '# 合成课表\n', '<!-- studyrocket:events:start -->',
            '| ID | 日期 | 开始 | 结束 | 名称 | 地点 | 说明 |',
            '| --- | --- | --- | --- | --- | --- | --- |', OLD,
            '<!-- studyrocket:events:end -->', '\n## 合成课程资料\n'])
        self.source = sized(block, 26_846)
        self.f.write(TIMETABLE, self.source)
        self.f.start()
        self.f.pair()

    def run_provider(self, provider, text=REQUEST):
        self.addCleanup(provider.close)
        self.f.stop()
        self.f.model_fixture = None
        self.f.upstream = provider.url
        self.f.start()
        operation = str(uuid.uuid4())
        self.assertEqual(self.f.request('POST', '/v1/chat/send', {
            'text': text, 'clientRequestID': operation, 'apiVersion': 1})[0], 202)
        for _ in range(400):
            terminal = next((t for t in self.f.request('GET', '/v1/chat/history')[1]['terminalTurns'] if t['turnID'] == operation), None)
            if terminal:
                self.assertEqual(provider.errors, [])
                return terminal
            time.sleep(.02)
        self.fail('No terminal turn')

    def timetable_provider(self, usage=lambda body, index: valid_usage()):
        def respond(body, index):
            self.assertEqual(body['max_tokens'], 16_384)
            if index == 0:
                return assistant([tool('read_file', {'path': path}, f'required-{i}') for i, path in enumerate(self.required)] +
                                 [tool('read_file', {'path': TIMETABLE}, 'page-0')])
            last = body['messages'][-1]
            result = json.loads(last['content'])
            if result.get('status') == 'awaiting_user_confirmation':
                return {'content': '已生成19:00–22:00的草案，等待用户确认。'}
            if result.get('complete') is False:
                offset = result['nextOffset']
                return assistant([tool('read_file', {'path': TIMETABLE, 'offset': offset}, f'page-{offset}')])
            self.assertTrue(result['complete'])
            if 'content' in result:
                return assistant([tool('read_file', {'path': TIMETABLE}, 'repeat-complete-source')])
            return assistant([tool('propose_changes', {
                'path': TIMETABLE, 'baseHash': result['hash'], 'reason': '合成请求调整训练时间',
                'edits': [{'oldText': OLD, 'newText': NEW}]}, 'proposal')])
        return ScriptedProvider(respond, usage)

    def assert_source_preserved(self):
        self.assertEqual((self.f.repo / TIMETABLE).read_text(), self.source)
        for path, text in self.required.items():
            self.assertEqual((self.f.repo / path).read_text(), text)

    def assert_complete_read_and_proposal(self, provider):
        final = provider.requests[-1]['messages']
        system = final[0]['content']
        stamp = re.search(r'服务端可信当前北京时间：(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)（Asia/Shanghai，UTC\+08:00）', system)
        self.assertIsNotNone(stamp)
        timezone = datetime.timezone(datetime.timedelta(hours=8))
        instant = datetime.datetime.strptime(stamp.group(1), '%Y-%m-%d %H:%M:%S').replace(tzinfo=timezone)
        self.assertLess(abs((datetime.datetime.now(timezone) - instant).total_seconds()), 30)
        monday = instant.date() - datetime.timedelta(days=instant.weekday())
        self.assertIn(f'{monday.isoformat()}至{(monday + datetime.timedelta(days=6)).isoformat()}', system)
        self.assertIn('历史消息或资料中的日期不得当作当前日期', system)
        self.assertTrue(all(body['messages'][0]['content'] == system for body in provider.requests))
        self.assertTrue(any(m.get('content') == REQUEST for m in final))
        for text in self.required.values():
            self.assertEqual(sum(text in (m.get('content') or '') for m in final), 1)
        chunks = []
        for message in final:
            if message['role'] == 'assistant' and message.get('tool_calls'):
                self.assertEqual(message['reasoning_content'], '完整保留的合成推理。')
            if message['role'] != 'tool':
                continue
            result = json.loads(message['content'])
            if result.get('path') in self.required:
                self.assertTrue(result['contentAlreadyInContext'])
                self.assertNotIn('content', result)
            if result.get('path') == TIMETABLE and 'content' in result:
                self.assertLessEqual(len(message['content'].encode()), 12_000)
                chunks.append(result)
        self.assertGreaterEqual(len(chunks), 3)
        self.assertEqual(chunks[0]['offset'], 0)
        for previous, current in zip(chunks, chunks[1:]):
            self.assertEqual(previous['nextOffset'], current['offset'])
        self.assertTrue(chunks[-1]['complete'])
        self.assertEqual(''.join(chunk['content'] for chunk in chunks), self.source)
        proposals = self.f.request('GET', '/v1/proposals')[1]['proposals']
        self.assertEqual(len(proposals), 1)
        self.assertEqual(proposals[0]['baseHash'], qa.sha(self.source))
        self.assertEqual(proposals[0]['proposedContent'], self.source.replace(OLD, NEW))
        self.assert_source_preserved()

    def test_partial_read_never_authorizes_exact_edits(self):
        observed = []
        def respond(body, index):
            if index == 0:
                return assistant([tool('read_file', {'path': TIMETABLE, 'limit': 100}, 'partial')])
            result = json.loads(body['messages'][-1]['content'])
            if index == 1:
                self.assertFalse(result['complete'])
                return assistant([tool('propose_changes', {'path': TIMETABLE, 'baseHash': result['hash'],
                    'reason': '拒绝未读部分', 'edits': [{'oldText': OLD, 'newText': NEW}]}, 'premature')])
            observed.append(result['error'])
            return {'content': '须先完整读取。'}
        terminal = self.run_provider(ScriptedProvider(respond))
        self.assertEqual(terminal['status'], 'completed', terminal)
        self.assertEqual(observed, ['read_required'])
        self.assertEqual(self.f.request('GET', '/v1/proposals')[1]['proposals'], [])
        self.assert_source_preserved()

    def test_long_skill_can_continue_with_declared_offsets(self):
        source = sized('---\nname: daily-checkin\ndescription: Synthetic skill\n---\n', 20_000)
        self.f.write('.agents/skills/daily-checkin/SKILL.md', source)
        chunks = []
        def respond(body, index):
            schema = next(t['function']['parameters'] for t in body['tools'] if t['function']['name'] == 'read_skill')
            self.assertIn('offset', schema['properties'])
            if index == 0:
                return assistant([tool('read_skill', {'name': 'daily-checkin'}, 'skill-0')])
            result = json.loads(body['messages'][-1]['content'])
            chunks.append(result['content'])
            if result['complete']:
                return {'content': '合成技能完整读入。'}
            return assistant([tool('read_skill', {'name': 'daily-checkin', 'offset': result['nextOffset']}, f'skill-{index}')])
        terminal = self.run_provider(ScriptedProvider(respond))
        self.assertEqual(terminal['status'], 'completed', terminal)
        self.assertEqual(''.join(chunks), source)
        self.assertGreater(len(chunks), 1)

    def test_invalid_context_configuration_does_not_start_service(self):
        self.f.stop()
        for value in (-1, 16_384, 1_048_577, 'unlimited'):
            with self.subTest(value=value):
                self.f.context_tokens = value
                with self.assertRaisesRegex(AssertionError, 'invalid_context_configuration'):
                    self.f.start()

    def test_archive_above_old_byte_limit_is_complete_and_window_bound(self):
        source = 'SYNTHETIC_ARCHIVE_BEGIN\n' + '中' * 21_000 + '\nSYNTHETIC_ARCHIVE_END'
        self.f.write('工作台/个人经历与能力档案.md', source)
        def respond(body, index):
            return {'content': '来源明确的合成摘要。' if not body['tools'] else '合成导读已完成。'}
        provider = ScriptedProvider(respond)
        terminal = self.run_provider(provider)
        self.assertEqual(terminal['status'], 'completed', terminal)
        bootstrap = [body for body in provider.requests if not body['tools']]
        self.assertEqual(len(bootstrap), 2)
        self.assertEqual(''.join(body['messages'][1]['content'].split('：\n', 1)[1] for body in bootstrap), source)
        self.assertTrue(all(body['max_tokens'] == 4096 for body in bootstrap))
        self.assertEqual(len(self.f.request('GET', '/v1/chat/history')[1]['messages']), 2)
        self.assertEqual((self.f.repo / '工作台/个人经历与能力档案.md').read_text(), source)

        # A changed larger source invalidates the cache and cannot bypass an
        # operator's deliberately lower model window on the bootstrap path.
        self.f.write('工作台/个人经历与能力档案.md', source * 2)
        self.f.context_tokens = 66_432
        rejected = ScriptedProvider(respond)
        terminal = self.run_provider(rejected)
        self.assertEqual((terminal['status'], terminal['issueCode']), ('failed', 'context_budget'))
        self.assertEqual(rejected.requests, [])

    def test_default_window_handles_real_size_chinese_sources_without_usage(self):
        provider = self.timetable_provider(usage=lambda body, index: None)
        terminal = self.run_provider(provider)
        self.assertEqual(terminal['status'], 'completed', terminal)
        self.assert_complete_read_and_proposal(provider)
        self.assertGreater(len(json.dumps(provider.requests[-1], ensure_ascii=False).encode()), 48_000)

    def test_usage_calibration_retains_full_messages_under_lowered_window(self):
        self.f.context_tokens = 66_432  # Deliberate fixture-only 48K input bound.
        provider = self.timetable_provider()
        terminal = self.run_provider(provider)
        self.assertEqual(terminal['status'], 'completed', terminal)
        self.assert_complete_read_and_proposal(provider)
        # Metrics must already be readable while the service remains alive.
        self.assertIsNone(self.f.process.poll())
        metrics = [json.loads(line) for line in (self.f.base / 'server.log').read_text().splitlines() if line.startswith('{') and 'model_usage' in line]
        self.assertEqual(len(metrics), len(provider.requests))
        for metric in metrics:
            self.assertEqual(metric['prompt_tokens'], 12_000)
            self.assertEqual(metric['max_output_tokens'], 16_384)
            self.assertEqual(set(metric), {'event', 'model', 'phase', 'prompt_tokens', 'completion_tokens', 'total_tokens', 'context_window_tokens', 'max_output_tokens'})

    def test_missing_or_invalid_usage_fails_closed_and_next_small_turn_recovers(self):
        self.f.context_tokens = 66_432
        invalid = [None, valid_usage(0), valid_usage(-1),
                   dict(valid_usage(), prompt_tokens=True), dict(valid_usage(), prompt_tokens='12000'),
                   dict(valid_usage(), prompt_tokens=1.5), dict(valid_usage(), total_tokens=1)]
        for counts in invalid:
            with self.subTest(usage=counts):
                terminal = self.run_provider(self.timetable_provider(usage=lambda body, index, value=counts: value))
                self.assertEqual((terminal['status'], terminal['issueCode']), ('failed', 'context_budget'))
                self.assertEqual(self.f.request('GET', '/v1/proposals')[1]['proposals'], [])
                with sqlite3.connect(self.f.state / 'cloud.sqlite') as db:
                    events = [json.loads(row[0]) for row in db.execute('SELECT body FROM events')]
                event = next(e['chat'] for e in reversed(events) if e.get('chat', {}).get('turnID') == terminal['turnID'] and e['chat']['kind'] == 'status')
                self.assertEqual(event['text'], terminal['message'])
                self.assertEqual(event['issueCode'], 'context_budget')
                recovered = self.run_provider(ScriptedProvider(lambda body, index: {'content': '小请求已恢复。'}, usage=lambda body, index: None), text='合成简短问候')
                self.assertEqual(recovered['status'], 'completed', recovered)
        self.assert_source_preserved()

    def test_high_measured_usage_or_large_new_reasoning_cannot_bypass_window(self):
        self.f.context_tokens = 66_432
        for counts, reasoning in [(valid_usage(48_001), '正常合成推理'), (valid_usage(12_000), '中文' * 10_000)]:
            with self.subTest(prompt=counts['prompt_tokens'], reasoning_bytes=len(reasoning.encode())):
                provider = ScriptedProvider(lambda body, index: assistant([tool('read_file', {'path': TIMETABLE}, 'page')], reasoning), usage=lambda body, index: counts)
                terminal = self.run_provider(provider)
                self.assertEqual((terminal['status'], terminal['issueCode']), ('failed', 'context_budget'))
                self.assertEqual(len(provider.requests), 1)
                self.assertEqual(self.f.request('GET', '/v1/proposals')[1]['proposals'], [])
        self.assert_source_preserved()

    def test_exact_edits_require_full_read_unique_text_and_fresh_hash(self):
        # The model may correct a rejected call in the same turn.
        self.f.write('笔记/edit.md', 'duplicate duplicate\nunique original\n')
        base = qa.sha('duplicate duplicate\nunique original\n')
        args = {'path': '笔记/edit.md', 'baseHash': base, 'reason': '合成精确修改', 'edits': [{'oldText': 'unique original', 'newText': 'unique revised'}]}
        expected = ['read_required', None, 'ambiguous_edit', 'edit_not_found', 'invalid_edits', None]
        observed = []
        calls = [tool('propose_changes', args, 'unread'), tool('read_file', {'path': '笔记/edit.md'}, 'read'),
                 tool('propose_changes', dict(args, edits=[{'oldText': 'duplicate', 'newText': 'x'}]), 'ambiguous'),
                 tool('propose_changes', dict(args, edits=[{'oldText': 'absent', 'newText': 'x'}]), 'missing'),
                 tool('propose_changes', dict(args, content='also present'), 'both'), tool('propose_changes', args, 'valid')]

        def respond(body, index):
            if index:
                observed.append(json.loads(body['messages'][-1]['content']).get('error'))
            return assistant([calls[index]]) if index < len(calls) else {'content': '合成纠错草案待确认。'}
        terminal = self.run_provider(ScriptedProvider(respond))
        self.assertEqual(terminal['status'], 'completed', terminal)
        self.assertEqual(observed, expected)
        proposals = self.f.request('GET', '/v1/proposals')[1]['proposals']
        self.assertEqual(proposals[0]['proposedContent'], 'duplicate duplicate\nunique revised\n')
        self.assertEqual((self.f.repo / '笔记/edit.md').read_text(), 'duplicate duplicate\nunique original\n')

        # A new source hash must be fully read again, including for edit patches.
        self.f.write('笔记/stale.md', 'old source\n')
        stale_args = {'path': '笔记/stale.md', 'baseHash': qa.sha('old source\n'), 'reason': '合成变化', 'edits': [{'oldText': 'old', 'newText': 'new'}]}
        def stale(body, index):
            if index == 0:
                return assistant([tool('read_file', {'path': '笔记/stale.md'}, 'read')])
            if index == 1:
                self.f.write('笔记/stale.md', 'external change\n')
                return assistant([tool('propose_changes', stale_args, 'stale')])
            self.assertEqual(json.loads(body['messages'][-1]['content'])['error'], 'conflict')
            return {'content': '基线变化，草案未登记。'}
        terminal = self.run_provider(ScriptedProvider(stale))
        self.assertEqual(terminal['status'], 'completed', terminal)
        self.assertEqual((self.f.repo / '笔记/stale.md').read_text(), 'external change\n')
        self.assertEqual(len(self.f.request('GET', '/v1/proposals')[1]['proposals']), 1)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', required=True)
    args, remaining = parser.parse_known_args()
    Acceptance.binary = args.binary
    unittest.main(argv=[__file__] + remaining, verbosity=2)
