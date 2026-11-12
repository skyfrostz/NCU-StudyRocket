#!/usr/bin/env python3
"""Synthetic managed-boundary and untouched-byte regression through Cloud HTTP."""
import argparse
import datetime as dt
import json
from pathlib import Path
import sqlite3
import time
import unittest
import uuid

from cloud_acceptance import Fixture, sha

PLAN = '工作台/下周计划.md'
TABLE = '工作台/学期/2026秋季个人课表.md'


class ProposalSafetyAcceptance(unittest.TestCase):
    binary = None

    def setUp(self):
        self.f = Fixture(self.binary)
        self.addCleanup(self.f.close)
        today = dt.datetime.now(dt.timezone(dt.timedelta(hours=8))).date().isoformat()
        self.row = f'| {today} | 合成任务 |  |  |  | [ ] |'
        self.blocks = {
            'weekly': '<!-- studyrocket:weekly:start -->\n| 日期 | 上午 | 中午 | 晚上 | 待分配 | 完成 |\n|---|---|---|---|---|---|\n' + self.row + '\n<!-- studyrocket:weekly:end -->',
            'deliveries': '<!-- studyrocket:deliveries:start -->\n- [ ] 合成交付物\n<!-- studyrocket:deliveries:end -->',
            'buffer': '<!-- studyrocket:buffer:start -->\n合成缓冲说明\n<!-- studyrocket:buffer:end -->',
        }
        self.source = '\n\n'.join(self.blocks.values()) + '\r\nUNICODE e\u0301 tail\r\n'
        self.table = '<!-- studyrocket:timetable:start -->\n合成导入\n<!-- studyrocket:timetable:end -->\n<!-- studyrocket:events:start -->\n<!-- studyrocket:events:end -->\r\n保留尾部'
        self.f.write(PLAN, self.source)
        self.f.write(TABLE, self.table)
        self.f.start(); self.f.pair()

    def checked(self, method, path, body=None, status=200):
        code, value = self.f.request(method, path, body)
        self.assertEqual(code, status, value)
        return value

    def propose(self, candidate, path=PLAN):
        original = (self.f.repo / path).read_bytes()
        def call(name, arguments, identity):
            return {'role': 'assistant', 'content': None, 'tool_calls': [{
                'id': identity, 'type': 'function',
                'function': {'name': name, 'arguments': json.dumps(arguments)}}]}
        self.f.stop()
        self.f.model_responses([
            call('read_file', {'path': PLAN}, 'read-plan'),
            call('read_file', {'path': TABLE}, 'read-table'),
            call('propose_changes', {'path': path, 'baseHash': sha(original), 'content': candidate,
                                     'reason': 'Synthetic data safety regression'}, 'proposal'),
            {'role': 'assistant', 'content': '合成检查结束，尚未确认。'}])
        self.f.start()
        operation = str(uuid.uuid4())
        self.checked('POST', '/v1/chat/send', {'text': '仅提交合成草案。', 'clientRequestID': operation, 'apiVersion': 1}, status=202)
        deadline = time.monotonic() + 15
        terminal = None
        while time.monotonic() < deadline:
            history = self.checked('GET', '/v1/chat/history')
            terminal = next((t for t in history.get('terminalTurns', []) if t['turnID'] == operation), None)
            if terminal: break
            time.sleep(.03)
        self.assertIsNotNone(terminal)
        self.assertEqual(terminal['status'], 'completed', terminal)
        self.assertEqual((self.f.repo / path).read_bytes(), original)
        transcript = json.loads(Path(str(self.f.model_fixture) + '.requests.json').read_text())
        return next(json.loads(m['content']) for m in transcript[-1] if m.get('tool_call_id') == 'proposal')

    def confirmation(self, proposals):
        challenge = self.checked('GET', '/v1/proposals/challenge')['challenge']
        return {'proposalIDs': [p['id'] for p in proposals],
                'authorization': challenge + '|' + self.f.identity.sign(('studyrocket-face-id-v1\n' + challenge).encode()),
                'metadata': {'apiVersion': 1, 'baseRevision': self.f.manifest()['revision'], 'idempotencyKey': str(uuid.uuid4())}}

    def test_missing_reordered_or_broken_blocks_are_rejected_before_registration(self):
        candidates = [self.source.replace(block, '') for block in self.blocks.values()]
        candidates += [self.blocks['buffer'] + '\n' + self.blocks['weekly'] + '\n' + self.blocks['deliveries'],
                       self.source + '\n' + self.blocks['buffer'],
                       self.source.replace('<!-- studyrocket:buffer:end -->', '<!-- studyrocket:buffer:end ->')]
        for candidate in candidates:
            with self.subTest(candidate_hash=sha(candidate)):
                result = self.propose(candidate)
                self.assertEqual(result['error'], 'invalid_planning_boundaries')
                self.assertEqual(self.checked('GET', '/v1/proposals')['proposals'], [])

    def test_timetable_import_boundary_is_protected(self):
        result = self.propose('<!-- studyrocket:events:start -->\n<!-- studyrocket:events:end -->', path=TABLE)
        self.assertEqual(result['error'], 'invalid_planning_boundaries')
        self.assertEqual(self.checked('GET', '/v1/proposals')['proposals'], [])

    def test_confirmation_rejects_unsafe_proposal_persisted_by_an_old_version(self):
        self.propose(self.source.replace('合成任务', '用户授权的新任务'))
        proposals = self.checked('GET', '/v1/proposals')['proposals']
        self.assertEqual(len(proposals), 1)
        self.f.stop()
        legacy = proposals[0]
        legacy['proposedContent'] = legacy['proposedContent'].replace(self.blocks['buffer'], '')
        with sqlite3.connect(self.f.state / 'cloud.sqlite') as db:
            db.execute('UPDATE proposals SET body=? WHERE id=?', (json.dumps(legacy, ensure_ascii=False), legacy['id']))
        self.f.start()
        request = self.confirmation(proposals)
        result = self.checked('POST', '/v1/proposals/apply', request, status=422)
        self.assertEqual(result['code'], 'invalid_planning_boundaries')
        self.assertEqual((self.f.repo / PLAN).read_bytes(), self.source.encode())
        self.assertEqual(len(self.checked('GET', '/v1/proposals')['proposals']), 1)

    def test_exact_mixed_newline_bytes_survive_preview_confirmation_and_replay(self):
        source = '前文\rCR\u0085NEL\u2028LS\u2029PS\n' + self.source.replace('\n', '\r\n') + '无末尾换行'
        self.f.write(PLAN, source)
        candidate = source.replace('合成任务', '- [ ] 合成任务<br>- [ ] 第二项')
        expected = source.replace('合成任务', '合成任务<br>第二项')
        self.assertEqual(self.propose(candidate)['status'], 'awaiting_user_confirmation')
        proposals = self.checked('GET', '/v1/proposals')['proposals']
        self.assertEqual(proposals[0]['proposedContent'].encode(), expected.encode())
        request = self.confirmation(proposals)
        first = self.checked('POST', '/v1/proposals/apply', request)
        self.assertEqual((self.f.repo / PLAN).read_bytes(), expected.encode())
        self.assertEqual(self.checked('POST', '/v1/proposals/apply', request), first)
        self.assertEqual((self.f.repo / PLAN).read_bytes(), expected.encode())
        self.assertEqual((self.f.repo / TABLE).read_bytes(), self.table.encode())


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', required=True)
    args, remaining = parser.parse_known_args()
    ProposalSafetyAcceptance.binary = str(Path(args.binary).resolve())
    unittest.main(argv=[__file__, *remaining], verbosity=2)
