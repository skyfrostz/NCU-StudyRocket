#!/usr/bin/env python3
"""Read-only linkage seed -> corrective tools -> signed proposal acceptance.

Uses an isolated repository, the actual Cloud agent/tool/HTTP/write paths and a
loopback scripted SSE provider. No production service, credentials or user files.
"""
import argparse
import copy
import datetime as dt
import json
from pathlib import Path
import re
import time
import unittest
import uuid

from cloud_acceptance import Fixture, sha
from context_window_acceptance import ScriptedProvider, assistant, tool

PLAN = '工作台/下周计划.md'
TIMETABLE = '工作台/学期/2026秋季个人课表.md'
START = '<!-- studyrocket:task-links:start -->'
END = '<!-- studyrocket:task-links:end -->'
BEIJING = dt.timezone(dt.timedelta(hours=8))


def graph_from(source):
    match = re.search(re.escape(START) + r'\n```json\n(.*?)\n```\n' + re.escape(END), source, re.S)
    assert match, 'No linkage block'
    return json.loads(match.group(1))


def graph_in(source, graph):
    block = START + '\n```json\n' + json.dumps(graph, ensure_ascii=False, indent=2) + '\n```\n' + END
    if START in source:
        return re.sub(re.escape(START) + r'.*?' + re.escape(END), lambda _: block, source, flags=re.S)
    return source.rstrip('\n') + '\n\n' + block + '\n'


def identity(graph):
    return {key: {item['id'] for item in graph[key]} for key in ('tasks', 'assignments', 'deliveries')}


class LinkageScenario:
    """Responds to actual tool results, never predicts seed IDs or JSON."""
    def __init__(self, case, mode='classify', probe_unread=False):
        self.case, self.mode, self.probe_unread = case, mode, probe_unread
        self.source = None
        self.base_hash = None
        self.seed = None
        self.corrected = None
        self.pages = []
        self.outcomes = {}

    def proposal(self, graph, call_id):
        return assistant([tool('propose_changes', {
            'path': PLAN, 'baseHash': self.base_hash,
            'content': graph_in(self.source, graph),
            'reason': '合成验收：AI整理类别和关联，等待用户确认。'}, call_id)])

    def respond(self, body, index):
        case = self.case
        # Every round before explicit HTTP confirmation must leave Markdown intact.
        case.assertEqual(case.hashes(), case.before_hashes)
        for message in body['messages']:
            if message.get('role') == 'tool':
                self.outcomes[message['tool_call_id']] = json.loads(message['content'])
        if index == 0 and self.probe_unread:
            return assistant([tool('read_task_linkage', {}, 'unread-seed')])
        if index == 0 or index == 1 and self.probe_unread:
            if self.probe_unread:
                case.assertEqual(self.outcomes['unread-seed']['error'], 'read_required')
            return assistant([tool('read_file', {'path': PLAN}, 'plan'),
                              tool('read_file', {'path': TIMETABLE}, 'timetable')])
        if self.source is None:
            result = self.outcomes['plan']
            case.assertTrue(result['complete'])
            self.source, self.base_hash = result['content'], result['hash']
            case.assertTrue(self.outcomes['timetable']['complete'])
            return assistant([tool('read_task_linkage', {'offset': 0}, 'seed-0')])
        last = body['messages'][-1]
        result = json.loads(last['content'])
        if last['tool_call_id'].startswith('seed-'):
            case.assertEqual(result['status'], 'read_only_preview')
            case.assertEqual(result['baseHash'], self.base_hash)
            case.assertEqual(result['offset'], sum(len(page) for page in self.pages))
            self.pages.append(result['content'])
            if not result['complete']:
                offset = result['nextOffset']
                return assistant([tool('read_task_linkage', {'offset': offset}, f'seed-{offset}')])
            self.seed = json.loads(''.join(self.pages))
            if self.mode == 'read_only':
                return {'content': '已查看只读关联预览，尚未启用，也没有生成修改草案。'}
            self.corrected = copy.deepcopy(self.seed)
            for task in self.corrected['tasks']:
                if task['category'] == 'unclassified':
                    task['category'] = 'responsibility'
            if self.corrected['tasks'] and self.corrected['deliveries']:
                self.corrected['tasks'][0]['deliveryID'] = self.corrected['deliveries'][0]['id']
            if self.mode == 'event':
                self.corrected['tasks'][0]['category'] = 'event'
            if self.mode.startswith('reject_') or self.mode == 'correct_invalid':
                invalid = copy.deepcopy(self.corrected)
                if self.mode == 'correct_invalid':
                    invalid['tasks'][0]['category'] = 'unclassified'
                elif self.mode == 'reject_task_id':
                    old, new = invalid['tasks'][0]['id'], str(uuid.uuid4()).upper()
                    invalid['tasks'][0]['id'] = new
                    for assignment in invalid['assignments']:
                        if assignment['taskID'] == old:
                            assignment['taskID'] = new
                elif self.mode == 'reject_delivery_id':
                    old, new = invalid['deliveries'][0]['id'], str(uuid.uuid4()).upper()
                    invalid['deliveries'][0]['id'] = new
                    for task in invalid['tasks']:
                        if task.get('deliveryID') == old:
                            task['deliveryID'] = new
                elif self.mode == 'reject_assignment_id':
                    invalid['assignments'][0]['id'] = str(uuid.uuid4()).upper()
                elif self.mode == 'reject_origin_date':
                    invalid['tasks'][0]['originDate'] = (dt.date.fromisoformat(case.today) - dt.timedelta(days=1)).isoformat()
                elif self.mode == 'reject_completion':
                    invalid['tasks'][0]['completedAt'] = case.today
                    invalid['tasks'][0]['completionSource'] = 'independent'
                return self.proposal(invalid, 'invalid-classification')
            return self.proposal(self.corrected, 'valid-proposal')
        if last['tool_call_id'] == 'invalid-classification':
            case.assertEqual(result['error'], 'invalid_task_linkage')
            case.assertEqual(case.checked('GET', '/v1/proposals')['proposals'], [])
            return self.proposal(self.corrected, 'corrected-proposal')
        case.assertEqual(result['status'], 'awaiting_user_confirmation', result)
        return {'content': '已形成任务分类与关联草案，请预览后确认；正式文件尚未修改。'}


class TaskLinkageAgentAcceptance(unittest.TestCase):
    binary = None

    def setUp(self):
        self.f = Fixture(self.binary)
        self.addCleanup(self.f.close)
        self.today = dt.datetime.now(BEIJING).date().isoformat()
        self.write_plan(['完成合成作业 A', '处理合成事项 B'])
        self.f.write(TIMETABLE, '# 合成课表\n\n保留此课表说明。\n')
        self.f.start()
        self.f.pair()

    def write_plan(self, tasks):
        self.f.write(PLAN, '\n'.join([
            '# 合成周计划', '', '<!-- studyrocket:weekly:start -->',
            '| 日期 | 上午 | 中午 | 晚上 | 待分配 | 完成 |',
            '|---|---|---|---|---|---|',
            f'| {self.today} | {"<br>".join(tasks)} |  |  |  | [ ] |',
            '<!-- studyrocket:weekly:end -->', '', '## 交付物清单', '<!-- studyrocket:deliveries:start -->',
            '- [ ] 合成学习成果', '<!-- studyrocket:deliveries:end -->', '',
            '## 缓冲', '<!-- studyrocket:buffer:start -->', '<!-- studyrocket:buffer:end -->', '',
            '## 保留说明',
            '边界外合成说明应原样保留。', '']))

    def hashes(self):
        return {str(path.relative_to(self.f.repo)): sha(path.read_bytes())
                for path in self.f.repo.rglob('*.md')}

    def checked(self, method, path, payload=None, status=200):
        code, value = self.f.request(method, path, payload)
        self.assertEqual(code, status, value)
        return value

    def run_scenario(self, mode='classify', probe_unread=False):
        self.before_hashes = self.hashes()
        scenario = LinkageScenario(self, mode, probe_unread)
        provider = ScriptedProvider(scenario.respond)
        self.addCleanup(provider.close)
        self.f.stop()
        self.f.upstream = provider.url
        self.f.start()
        operation = str(uuid.uuid4())
        self.checked('POST', '/v1/chat/send', {
            'text': '合成验收：请由AI整理任务联动，先形成待确认草案。',
            'clientRequestID': operation, 'apiVersion': 1}, status=202)
        deadline = time.monotonic() + 20
        terminal = None
        while time.monotonic() < deadline:
            history = self.checked('GET', '/v1/chat/history')
            terminal = next((t for t in history.get('terminalTurns', []) if t['turnID'] == operation), None)
            if terminal:
                break
            time.sleep(.03)
        self.assertEqual(provider.errors, [])
        self.assertIsNotNone(terminal, 'No durable agent terminal state')
        self.assertEqual(terminal['status'], 'completed', terminal)
        self.assertEqual(self.hashes(), self.before_hashes)
        return scenario

    def confirmation(self, proposals, revision=None):
        challenge = self.checked('GET', '/v1/proposals/challenge')['challenge']
        return {'proposalIDs': [p['id'] for p in proposals],
                'authorization': challenge + '|' + self.f.identity.sign(('studyrocket-face-id-v1\n' + challenge).encode()),
                'metadata': {'apiVersion': 1, 'idempotencyKey': str(uuid.uuid4()),
                             'baseRevision': revision or self.checked('GET', '/v1/snapshot')['revision']}}

    def assert_proposal(self, scenario):
        proposals = self.checked('GET', '/v1/proposals')['proposals']
        self.assertEqual(len(proposals), 1, proposals)
        self.assertEqual(proposals[0]['relativePath'], PLAN)
        self.assertEqual(proposals[0]['baseHash'], scenario.base_hash)
        proposed = graph_from(proposals[0]['proposedContent'])
        self.assertEqual(identity(proposed), identity(scenario.seed))
        self.assertTrue(all(t['category'] != 'unclassified' for t in proposed['tasks']))
        return proposals

    def test_seed_is_read_only_requires_source_and_paginates(self):
        self.write_plan([f'处理合成事项 {i}' for i in range(18)])
        scenario = self.run_scenario('read_only', probe_unread=True)
        self.assertGreater(len(scenario.pages), 1)
        self.assertEqual(len(scenario.seed['tasks']), 18)
        self.assertEqual(self.checked('GET', '/v1/proposals')['proposals'], [])
        self.assertNotIn(START, (self.f.repo / PLAN).read_text())

    def test_invalid_classification_is_corrected_before_confirmation(self):
        scenario = self.run_scenario('correct_invalid')
        proposals = self.assert_proposal(scenario)
        self.assertNotIn(START, (self.f.repo / PLAN).read_text())
        self.checked('POST', '/v1/proposals/apply', self.confirmation(proposals))
        persisted = graph_from((self.f.repo / PLAN).read_text())
        self.assertEqual(identity(persisted), identity(scenario.seed))
        self.assertEqual(persisted['tasks'][0]['deliveryID'], persisted['deliveries'][0]['id'])
        self.assertEqual(self.checked('GET', '/v1/proposals')['proposals'], [])

    def test_existing_completed_task_keeps_identity_and_completion(self):
        scenario = self.run_scenario()
        proposals = self.assert_proposal(scenario)
        self.checked('POST', '/v1/proposals/apply', self.confirmation(proposals))
        snapshot = self.checked('GET', '/v1/snapshot')
        day = next(d for d in snapshot['week']['days'] if d['id'] == self.today)
        task = next(s for s in day['slots'] if s['id'] == 'morning')['tasks'][0]
        self.checked('POST', '/v1/periods/toggle', {
            'dayID': self.today, 'periodID': 'morning', 'taskID': task['id'],
            'logicalTaskID': task['logicalTaskID'], 'assignmentID': task['assignmentID'],
            'isCompleted': True, 'metadata': {'apiVersion': 1,
                'baseRevision': snapshot['revision'], 'idempotencyKey': str(uuid.uuid4())}})
        before = graph_from((self.f.repo / PLAN).read_text())
        again = self.run_scenario()
        proposals = self.assert_proposal(again)
        self.checked('POST', '/v1/proposals/apply', self.confirmation(proposals))
        after = graph_from((self.f.repo / PLAN).read_text())
        self.assertEqual(identity(before), identity(after))
        for old in before['tasks']:
            new = next(t for t in after['tasks'] if t['id'] == old['id'])
            self.assertEqual(new.get('completedAt'), old.get('completedAt'))
            self.assertEqual(new.get('completionSource'), old.get('completionSource'))
        self.assertTrue(next(t for t in after['tasks'] if t['id'] == task['logicalTaskID']).get('completedAt'))

    def test_conflicting_source_is_not_overwritten_by_confirmation(self):
        scenario = self.run_scenario()
        proposals = self.assert_proposal(scenario)
        old_revision = self.checked('GET', '/v1/snapshot')['revision']
        changed = (self.f.repo / PLAN).read_text() + '\n另一端确认的合成说明。\n'
        self.checked('POST', '/v1/files/commit', self.f.commit_request({PLAN: changed}))
        for revision in (old_revision, self.checked('GET', '/v1/snapshot')['revision']):
            error = self.checked('POST', '/v1/proposals/apply', self.confirmation(proposals, revision), status=409)
            self.assertEqual(error['code'], 'conflict')
            self.assertEqual((self.f.repo / PLAN).read_text(), changed)
            self.assertEqual(self.checked('GET', '/v1/proposals')['proposals'], proposals)

    def test_first_activation_cannot_fabricate_completion(self):
        scenario = self.run_scenario('reject_completion')
        proposals = self.assert_proposal(scenario)
        self.assertTrue(all(t.get('completedAt') is None for t in graph_from(proposals[0]['proposedContent'])['tasks']))

    def test_existing_graph_rejects_identity_history_and_completion_changes(self):
        first = self.run_scenario()
        self.checked('POST', '/v1/proposals/apply', self.confirmation(self.assert_proposal(first)))
        for mode in ('reject_task_id', 'reject_delivery_id', 'reject_assignment_id',
                     'reject_origin_date', 'reject_completion'):
            with self.subTest(mode=mode):
                scenario = self.run_scenario(mode)
                proposals = self.assert_proposal(scenario)
                self.checked('POST', '/v1/proposals/apply', self.confirmation(proposals))
                self.assertEqual(identity(graph_from((self.f.repo / PLAN).read_text())), identity(first.seed))

    def test_explicit_event_category_routes_without_word_heuristic(self):
        self.write_plan(['19:00 合成晚间时段'])
        scenario = self.run_scenario('event')
        self.assertEqual(scenario.seed['tasks'][0]['category'], 'unclassified')
        proposals = self.checked('GET', '/v1/proposals')['proposals']
        self.assertEqual({p['relativePath'] for p in proposals}, {PLAN, TIMETABLE})
        week = next(p for p in proposals if p['relativePath'] == PLAN)
        timetable = next(p for p in proposals if p['relativePath'] == TIMETABLE)
        graph = graph_from(week['proposedContent'])
        self.assertEqual(identity(graph), identity(scenario.seed))
        self.assertTrue(graph['tasks'][0]['cancelled'])
        self.assertFalse(graph['assignments'][0]['active'])
        digest = sha('event|' + graph['tasks'][0]['id'])
        event_id = '-'.join((digest[:8], digest[8:12], digest[12:16], digest[16:20], digest[20:32])).upper()
        self.assertIn(f'| {event_id} | {self.today} | 19:00 |', timetable['proposedContent'])
        self.assertIn('合成晚间时段', timetable['proposedContent'])
        self.checked('POST', '/v1/proposals/apply', self.confirmation([week]), status=422)
        self.assertEqual(self.hashes(), self.before_hashes)
        self.checked('POST', '/v1/proposals/apply', self.confirmation(proposals))
        snapshot = self.checked('GET', '/v1/snapshot')
        today = next(d for d in snapshot['week']['days'] if d['id'] == self.today)
        self.assertEqual(next(s for s in today['slots'] if s['id'] == 'morning')['tasks'], [])
        self.assertEqual((self.f.repo / TIMETABLE).read_text(), timetable['proposedContent'])


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', required=True)
    args, remaining = parser.parse_known_args()
    TaskLinkageAgentAcceptance.binary = str(Path(args.binary).resolve())
    unittest.main(argv=[__file__, *remaining], verbosity=2)
