#!/usr/bin/env python3
"""Synthetic Cloud proposal-to-toggle acceptance for independent period tasks.

Uses the real HTTP, proposal, signature and write paths with a scripted model.
No production endpoint, model credential or user Markdown is accessed.
Run with --binary /absolute/path/StudyRocketCloud.
"""
import argparse
import datetime as dt
import json
from pathlib import Path
import time
import unittest
import uuid

from cloud_acceptance import Fixture, sha


PLAN = '工作台/下周计划.md'
BEIJING = dt.timezone(dt.timedelta(hours=8))
TASKS = ['完成合成练习 A', '整理合成笔记 B']
CELL = '- [ ] ' + TASKS[0] + '<br>- [ ] ' + TASKS[1]
OUTSIDE = 'Unmanaged synthetic explanation must remain unchanged.\n'


def plan(days, cell):
    rows = ''.join(f'| {day} | {cell} |  |  |  | [ ] |\n' for day in days)
    return ('# Synthetic independent-task plan\n\n'
            '<!-- studyrocket:weekly:start -->\n'
            '| 日期 | 上午 | 中午 | 晚上 | 待分配 | 完成 |\n'
            '|---|---|---|---|---|---|\n' + rows +
            '<!-- studyrocket:weekly:end -->\n\n' + OUTSIDE)


def tool(name, arguments, call_id):
    return {'role': 'assistant', 'content': None, 'tool_calls': [{
        'id': call_id, 'type': 'function',
        'function': {'name': name, 'arguments': json.dumps(arguments, ensure_ascii=False)}}]}


class IndependentTasksAcceptance(unittest.TestCase):
    binary = None

    def setUp(self):
        self.f = Fixture(self.binary)
        self.addCleanup(self.f.close)
        today = dt.datetime.now(BEIJING).date()
        self.today = today.isoformat()
        self.past = (today - dt.timedelta(days=8)).isoformat()
        self.future = (today + dt.timedelta(days=10)).isoformat()
        self.days = [self.past, self.today, self.future]
        self.original = plan(self.days, '')
        self.f.write(PLAN, self.original)

    def checked(self, method, path, payload=None, status=200):
        code, value = self.f.request(method, path, payload)
        self.assertEqual(code, status, value)
        return value

    def snapshot(self):
        return self.checked('GET', '/v1/snapshot')

    def metadata(self, snapshot=None):
        return {'apiVersion': 1, 'baseRevision': (snapshot or self.snapshot())['revision'],
                'idempotencyKey': str(uuid.uuid4())}

    def row(self, snapshot, day):
        week = snapshot['week']
        rows = week['days'] + week['historicalRows'] + week['futureRows']
        # Current rows expose ISO id; historical/future rows expose an opaque id.
        return next(row for row in rows if row['id'] == day or row['dateLabel'].startswith(day))

    def period(self, snapshot, day):
        return next(slot for slot in self.row(snapshot, day)['slots'] if slot['id'] == 'morning')

    def assert_tasks(self, period, texts=TASKS, completed=None):
        tasks = period['tasks']
        self.assertEqual([task['text'] for task in tasks], texts)
        self.assertEqual(len({task['id'] for task in tasks}), len(texts))
        for task in tasks:
            self.assertNotRegex(task['text'], r'^\s*(?:[-*]\s+)?\[[ xX]\]')
        if completed is not None:
            self.assertEqual([task['isCompleted'] for task in tasks], completed)
            self.assertEqual(period['isCompleted'], all(completed))
        return tasks

    def propose_and_confirm(self, cell=CELL):
        candidate = plan(self.days, cell)
        before_hash = sha((self.f.repo / PLAN).read_bytes())
        self.f.model_responses([
            tool('read_file', {'path': PLAN}, 'read-plan'),
            tool('propose_changes', {'path': PLAN, 'baseHash': before_hash,
                                    'content': candidate, 'reason': 'Synthetic independent task acceptance'}, 'propose-plan'),
            {'role': 'assistant', 'content': 'Synthetic plan preview awaits explicit confirmation.'}])
        self.f.start()
        self.f.pair()
        operation = str(uuid.uuid4())
        self.checked('POST', '/v1/chat/send', {
            'text': 'Synthetic request: add two independently completable tasks to the same period.',
            'clientRequestID': operation, 'apiVersion': 1}, status=202)
        deadline = time.monotonic() + 15
        terminal = None
        while time.monotonic() < deadline:
            history = self.checked('GET', '/v1/chat/history')
            terminal = next((turn for turn in history.get('terminalTurns', []) if turn['turnID'] == operation), None)
            if terminal:
                break
            time.sleep(.03)
        self.assertIsNotNone(terminal, 'Proposal turn never reached a durable terminal state')
        self.assertEqual(terminal['status'], 'completed', terminal)
        proposals = self.checked('GET', '/v1/proposals')['proposals']
        self.assertEqual(len(proposals), 1, proposals)
        self.assertEqual(proposals[0]['relativePath'], PLAN)
        self.assertEqual(proposals[0]['baseHash'], before_hash)
        expected = plan(self.days, cell.replace('- [ ] ', ''))
        self.assertEqual(proposals[0]['proposedContent'], expected,
                         'Preview must preserve explicit task boundaries while cleaning checkbox prefixes')
        self.assertEqual(sha((self.f.repo / PLAN).read_bytes()), before_hash,
                         'A model proposal must not write before confirmation')
        challenge = self.checked('GET', '/v1/proposals/challenge')['challenge']
        request = {'proposalIDs': [proposals[0]['id']],
                   'authorization': challenge + '|' + self.f.identity.sign(
                       ('studyrocket-face-id-v1\n' + challenge).encode()),
                   'metadata': self.metadata()}
        applied = self.checked('POST', '/v1/proposals/apply', request)
        self.assertEqual((self.f.repo / PLAN).read_text(), proposals[0]['proposedContent'])
        self.assertEqual(self.checked('GET', '/v1/proposals')['proposals'], [])
        versions = self.checked('GET', '/v1/versions')
        self.assertEqual(self.checked('POST', '/v1/proposals/apply', request), applied)
        self.assertEqual(self.checked('GET', '/v1/versions'), versions,
                         'Replaying signed confirmation must not create a second write')
        return self.snapshot()

    def toggle_request(self, snapshot, day, task):
        return {'dayID': day, 'periodID': 'morning', 'taskID': task['id'],
                'isCompleted': True, 'metadata': self.metadata(snapshot)}

    def test_first_system_prompt_teaches_explicit_independent_task_boundaries(self):
        self.f.model_responses([{'role': 'assistant', 'content': 'Synthetic prompt inspection complete.'}])
        self.f.start()
        self.f.pair()
        self.checked('POST', '/v1/chat/send', {
            'text': 'Synthetic request: explain the task format.',
            'clientRequestID': str(uuid.uuid4()), 'apiVersion': 1}, status=202)
        transcript = Path(str(self.f.model_fixture) + '.requests.json')
        deadline = time.monotonic() + 5
        while not transcript.exists() and time.monotonic() < deadline:
            time.sleep(.03)
        self.assertTrue(transcript.exists(), 'The first model request was not captured')
        requests = json.loads(transcript.read_text())
        system = '\n'.join(message['content'] for message in requests[0]
                           if message.get('role') == 'system')
        for required in ('<br>', '同一时段', '分号'):
            with self.subTest(required=required):
                self.assertTrue(required in system,
                                f'First system prompt is missing shared task-format guidance: {required}')

    def test_proposal_home_week_independent_toggle_and_lost_receipt_replay(self):
        snapshot = self.propose_and_confirm()
        tasks = self.assert_tasks(self.period(snapshot, self.today), completed=[False, False])
        home = next(period for period in snapshot['home']['periods'] if period['id'] == 'morning')
        self.assertEqual(self.assert_tasks(home, completed=[False, False]), tasks)
        request = self.toggle_request(snapshot, self.today, tasks[0])
        receipt = self.checked('POST', '/v1/periods/toggle', request)
        self.assert_tasks(self.period(receipt, self.today), completed=[True, False])
        self.assert_tasks(next(p for p in receipt['home']['periods'] if p['id'] == 'morning'),
                          completed=[True, False])
        saved_hash = sha((self.f.repo / PLAN).read_bytes())
        versions = self.checked('GET', '/v1/versions')
        # Model a client that lost its receipt and reconnects after server restart.
        self.f.stop(kill=True)
        self.f.start()
        self.assertEqual(self.checked('POST', '/v1/periods/toggle', request), receipt)
        self.assertEqual(sha((self.f.repo / PLAN).read_bytes()), saved_hash)
        self.assertEqual(self.checked('GET', '/v1/versions'), versions)
        refreshed = self.snapshot()
        self.assert_tasks(self.period(refreshed, self.today), completed=[True, False])
        self.assert_tasks(self.period(refreshed, self.past), completed=[False, False])
        self.assert_tasks(self.period(refreshed, self.future), completed=[False, False])
        self.assertIn(OUTSIDE, (self.f.repo / PLAN).read_text())

    def test_historical_and_future_tasks_use_actual_date_not_row_id(self):
        snapshot = self.propose_and_confirm()
        for day, bucket in ((self.past, 'historicalRows'), (self.future, 'futureRows')):
            with self.subTest(day=day):
                row = self.row(snapshot, day)
                self.assertIn(row, snapshot['week'][bucket])
                self.assertNotEqual(row['id'], day)
                tasks = self.assert_tasks(self.period(snapshot, day), completed=[False, False])
                invalid = self.toggle_request(snapshot, row['id'], tasks[0])
                before_hash = sha((self.f.repo / PLAN).read_bytes())
                status, error = self.f.request('POST', '/v1/periods/toggle', invalid)
                self.assertEqual(status, 422, error)
                self.assertEqual(error['code'], 'invalid_period')
                self.assertEqual(sha((self.f.repo / PLAN).read_bytes()), before_hash)
                snapshot = self.checked('POST', '/v1/periods/toggle', self.toggle_request(snapshot, day, tasks[0]))
                self.assert_tasks(self.period(snapshot, day), completed=[True, False])
                content = (self.f.repo / PLAN).read_text()
                self.assertIn(f'| {day} | morning | {tasks[0]["id"]} |', content)
                self.assertNotIn(f'| {row["id"]} | morning |', content)
                self.assert_tasks(self.period(snapshot, self.today), completed=[False, False])
        self.assert_tasks(self.period(snapshot, self.past), completed=[True, False])

    def test_legacy_whole_period_request_cannot_complete_both_tasks(self):
        snapshot = self.propose_and_confirm()
        period = self.period(snapshot, self.today)
        before_hash = sha((self.f.repo / PLAN).read_bytes())
        for whole_text in (period['text'], '；'.join(TASKS)):
            with self.subTest(whole_text=whole_text):
                request = {'dayID': self.today, 'periodID': 'morning', 'textHash': sha(whole_text),
                           'isCompleted': True, 'metadata': self.metadata(snapshot)}
                status, error = self.f.request('POST', '/v1/periods/toggle', request)
                self.assertEqual(status, 422, error)
                self.assertEqual(error['code'], 'period_upgrade_required')
                self.assertEqual(sha((self.f.repo / PLAN).read_bytes()), before_hash)
                self.assert_tasks(self.period(self.snapshot(), self.today), completed=[False, False])
        # A cached current-client task ID for the formerly merged item is stale too.
        stale_task = {'id': 'task:' + sha('；'.join(TASKS)) + ':1'}
        request = self.toggle_request(snapshot, self.today, stale_task)
        status, error = self.f.request('POST', '/v1/periods/toggle', request)
        self.assertEqual(status, 422, error)
        self.assertEqual(error['code'], 'period_task_changed')
        self.assertEqual(sha((self.f.repo / PLAN).read_bytes()), before_hash)
        self.assert_tasks(self.period(self.snapshot(), self.today), completed=[False, False])

    def test_single_task_semicolons_are_preserved(self):
        text = '整理例题；保留原推导; 在同一份笔记标注条件'
        snapshot = self.propose_and_confirm('- [ ] ' + text)
        task = self.assert_tasks(self.period(snapshot, self.today), [text], [False])[0]
        home = next(period for period in snapshot['home']['periods'] if period['id'] == 'morning')
        self.assert_tasks(home, [text], [False])
        snapshot = self.checked('POST', '/v1/periods/toggle', self.toggle_request(snapshot, self.today, task))
        self.assert_tasks(self.period(snapshot, self.today), [text], [True])


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', required=True)
    args, remaining = parser.parse_known_args()
    IndependentTasksAcceptance.binary = str(Path(args.binary).resolve())
    unittest.main(argv=[__file__, *remaining], verbosity=2)
