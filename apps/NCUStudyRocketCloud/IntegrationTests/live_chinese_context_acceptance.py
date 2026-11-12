#!/usr/bin/env python3
"""Opt-in, synthetic Chinese context acceptance against an isolated live QA server.

Prepare a fresh directory (never copies real academic files):
  python3 live_chinese_context_acceptance.py prepare --base /tmp/live-qa-chinese-new
  python3 live_chinese_context_acceptance.py prepare --base /tmp/live-qa-tasks-new \
    --scenario independent-tasks

The operator starts StudyRocketCloud with that repository/state, a dedicated
non-production port and the existing fixed-target live_provider_proxy.py. Then:
  python3 live_chinese_context_acceptance.py run --allow-live-provider \
    --base /tmp/live-qa-chinese-new --port 43819 --binary /path/StudyRocketCloud \
    --pid PID --proxy-log /path/to/dedicated-structure.jsonl

Only aggregates, status codes, sizes and hashes are reported. No source text,
model reasoning, credentials, device IDs or repository IDs enter the report.
This script never starts/stops production services or accesses public endpoints
directly. The opt-in run spends provider tokens through the isolated server.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import statistics
import subprocess
import sys
import time
import uuid

import cloud_acceptance as qa


MARKER = 'ALLOW_LIVE_QA'
MARKER_BODY = 'Synthetic Chinese context QA only; no production data.\n'
SPEC = 'chinese-context-fixture.json'
REPORT = 'chinese-context-report.json'
WEEK = '工作台/下周计划.md'
TIMETABLE = '工作台/学期/2026秋季个人课表.md'
SCENARIOS = ('time-adjustment', 'independent-tasks')
ORIGINAL_TASK = '合成学习任务'
ADDED_TASK = '发送合成确认邮件'
TARGET_BYTES = {'AGENTS.md': 11000, 'PROFILE.md': 9000,
                '工作台/助理偏好与习惯.md': 3866, TIMETABLE: 27000, WEEK: 17000}


def require(value, message):
    if not value:
        raise AssertionError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def fingerprint(path):
    value = path.read_bytes()
    return {'bytes': len(value), 'sha256': sha(value)}


def write_json(path, value, exclusive=False):
    with path.open('x' if exclusive else 'w', encoding='utf-8') as target:
        json.dump(value, target, ensure_ascii=False, indent=2)
        target.write('\n')


def padded(header, trailer, target):
    filler = '合成资料仅用于隔离验收，所有人物、课程及活动均为虚构，不代表用户事实。\n'
    remaining = target - len((header + trailer).encode())
    require(remaining >= 0, 'Synthetic target size is smaller than fixture')
    count, remaining = divmod(remaining, len(filler.encode()))
    pad = filler * count + '合' * (remaining // 3) + ' ' * (remaining % 3)
    result = header + pad + trailer
    require(len(result.encode()) == target, 'Synthetic byte padding failed')
    return result


def safe_base(raw):
    raw = Path(os.path.abspath(raw.expanduser()))
    require(raw.name.startswith('live-qa-'), 'Base name must begin live-qa-')
    require(not raw.is_symlink(), 'Base must not be a symlink')
    base = raw.resolve()
    require('/var/lib/studyrocket/cloud' not in str(base), 'Production paths are forbidden')
    return base


def scenario_prompt(scenario):
    require(scenario in SCENARIOS, 'Unsupported synthetic scenario')
    preamble = (
        '这是合成隔离验收，不含真实学业资料。请先用read_file完整读取工作台/下周计划.md和'
        '工作台/学期/2026秋季个人课表.md，两份文件均须依nextOffset读到末尾，允许同轮读取多个文件。'
    )
    if scenario == 'independent-tasks':
        action = (
            '然后仅修改周计划今天上午的安排：在原有“合成学习任务”之外，新增一项独立的'
            '“发送合成确认邮件”。原任务和新增任务必须能分别完成，保留原任务原文；'
            '不要改日期、其他时段、交付物、管理标记或其他任何字节，不要改课表，也不要生成其他草案。'
            '请用propose_changes的edits精确修改，oldText包含今天完整计划行以确保唯一匹配；'
        )
    else:
        action = (
            '然后仅对课表的“合成活动时段调整”这一行，用propose_changes的edits精确替换，把开始14:00改为15:00；'
            '结束16:00、ID、日期、名称和其余所有字节保持不变。不要改周计划，不要生成其他草案。'
            'oldText请包含完整活动行以确保唯一匹配；'
        )
    return preamble + action + (
        'baseHash必须来自本回合完整读取。'
        '最终只回复两份文件末尾核验码与“草案待确认”，不要复述资料正文或宣称已保存。'
    )


def prepare(args):
    base = safe_base(args.base)
    require(not base.exists(), 'Prepare requires a fresh base directory')
    require(base.parent.is_dir(), 'Base parent must exist')
    # Reuse the normal Fixture repository/state setup. Its temporary signing key
    # is not copied; run creates a fresh isolated QA identity.
    fixture = qa.Fixture(sys.executable)
    try:
        today = dt.datetime.now(dt.timezone(dt.timedelta(hours=8))).date().isoformat()
        week_code, timetable_code = 'WEEK-CHINESE-48271', 'TABLE-CHINESE-73192'
        timetable_row = f'| synthetic-time-adjustment | {today} | 14:00 | 16:00 | 合成活动时段调整 | 合成地点 | 仅验收 |'
        week_row = f'| {today} | {ORIGINAL_TASK} | 弹性缓冲 | 合成核对任务 |  | [ ] |'
        if args.scenario == 'independent-tasks':
            target_path, old_row = WEEK, week_row
            new_row = week_row.replace(ORIGINAL_TASK, ORIGINAL_TASK + '<br>' + ADDED_TASK)
        else:
            target_path, old_row = TIMETABLE, timetable_row
            new_row = timetable_row.replace('| 14:00 |', '| 15:00 |')
        sources = {
            'AGENTS.md': padded('# 合成隔离测试说明\n只依据当前用户要求操作合成文件，草案待确认。\n', '\n', 11000),
            'PROFILE.md': padded('# 合成个人档案\n这是虚构的分页验收资料，不含真实个人信息。\n', '\n', 9000),
            '工作台/助理偏好与习惯.md': padded('# 合成表达偏好\n只报告验收结论，不输出资料正文。\n', '\n', 3866),
            WEEK: padded(
                '# 合成周计划\n\n<!-- studyrocket:weekly:start -->\n'
                '| 日期 | 上午 | 中午 | 晚上 | 待分配 | 完成 |\n|---|---|---|---|---|---|\n'
                + week_row + '\n'
                '<!-- studyrocket:weekly:end -->\n\n<!-- studyrocket:deliveries:start -->\n'
                '- [ ] 合成可核验交付物\n<!-- studyrocket:deliveries:end -->\n\n边界外说明保持不变。\n',
                f'\n计划末尾核验码：{week_code}\n', 17000),
            TIMETABLE: padded('# 合成课表与活动\n\n',
                '\n<!-- studyrocket:events:start -->\n'
                '| ID | 日期 | 开始 | 结束 | 名称 | 地点 | 说明 |\n'
                '| --- | --- | --- | --- | --- | --- | --- |\n'
                + timetable_row + '\n<!-- studyrocket:events:end -->\n'
                + f'课表末尾核验码：{timetable_code}\n', 27000),
        }
        for name, content in sources.items():
            fixture.write(name, content)
        base.mkdir(mode=0o700)
        shutil.copytree(fixture.repo, base / 'repository')
        (base / 'state').mkdir(mode=0o700)
        (base / MARKER).write_text(MARKER_BODY, encoding='utf-8')
        spec = {'version': 1, 'syntheticOnly': True, 'date': today, 'scenario': args.scenario,
                'targetPath': target_path, 'oldRow': old_row, 'newRow': new_row,
                'weekCode': week_code, 'timetableCode': timetable_code,
                'files': {name: fingerprint(base / 'repository' / name) for name in sources}}
        write_json(base / SPEC, spec, exclusive=True)
        result = {'result': 'PREPARED', 'syntheticOnly': True, 'scenario': args.scenario,
                  'requiredReferenceBytes': sum(TARGET_BYTES[name] for name in TARGET_BYTES if name not in (WEEK, TIMETABLE)),
                  'timetableBytes': TARGET_BYTES[TIMETABLE], 'planBytes': TARGET_BYTES[WEEK],
                  'fileCount': len(list((base / 'repository').rglob('*.md'))),
                  'liveProviderInvoked': False}
        print(json.dumps(result, indent=2))
    finally:
        fixture.close()


def validate_server(args, base):
    require(args.allow_live_provider, 'Run requires --allow-live-provider')
    require((base / MARKER).read_text(encoding='utf-8') == MARKER_BODY, 'Missing synthetic-only marker')
    require(1024 <= args.port <= 65535 and args.port not in (43817, 43818), 'Use a non-production QA port')
    require(args.pid > 1, 'A specific temporary server PID is required')
    require(not (base / REPORT).exists(), 'Report already exists; prepare a new base')
    binary = args.binary.resolve(strict=True)
    require(binary.is_file() and os.access(binary, os.X_OK), 'Cloud binary must be executable')
    # Match the exact temporary repository/state/port arguments to a live PID.
    proc = Path(f'/proc/{args.pid}/cmdline')
    if proc.exists():
        command = proc.read_bytes().split(b'\0')
        command = [part.decode() for part in command if part]
        expected = [('--repository', str(base / 'repository')), ('--state', str(base / 'state')),
                    ('--host', '127.0.0.1'), ('--port', str(args.port))]
        for key, value in expected:
            require(key in command and command[command.index(key) + 1] == value,
                    'Temporary server process arguments do not match fixture')
        require(Path(f'/proc/{args.pid}/exe').resolve() == binary, 'PID does not run the selected cloud binary')
        require('--test-upstream-url' in command and '--allow-test-failpoints' in command,
                'Live QA must use the dedicated fixed-target test proxy')
        upstream = command[command.index('--test-upstream-url') + 1]
        require(re.fullmatch(r'http://127\.0\.0\.1:\d+/chat/completions', upstream),
                'Live QA upstream must be a loopback fixed-target proxy')
        require('--test-model-fixture' not in command, 'A deterministic model fixture is not live acceptance')
    else:
        raise AssertionError('Live resource/PID validation requires Linux /proc; prepare is portable')
    return binary


def resource_sample(pid):
    values = {'time': time.time()}
    try:
        for line in Path(f'/proc/{pid}/status').read_text().splitlines():
            if line.startswith(('VmRSS:', 'VmHWM:')):
                key, value, *_ = line.split()
                values[key.rstrip(':')] = int(value) * 1024
        for line in Path('/proc/meminfo').read_text().splitlines():
            if line.startswith('MemAvailable:'):
                values['MemAvailable'] = int(line.split()[1]) * 1024
        group = next(line[3:] for line in Path(f'/proc/{pid}/cgroup').read_text().splitlines() if line.startswith('0::'))
        for key in ('memory.current', 'memory.peak'):
            target = Path('/sys/fs/cgroup') / group.lstrip('/') / key
            if target.exists():
                values[key] = int(target.read_text())
    except (OSError, ValueError, StopIteration) as error:
        values['error'] = type(error).__name__
    return values


def structure_summary(path, start):
    with path.open('rb') as source:
        source.seek(start)
        records = [json.loads(line) for line in source if line.strip()]
    requests = [item for item in records if item.get('event') == 'request']
    responses = [item for item in records if item.get('event') == 'response']
    tools = [tool for item in responses for tool in item.get('tools', [])]
    usage = [item['usage'] for item in responses if isinstance(item.get('usage'), dict)]
    numeric_usage = [{key: value for key, value in item.items()
                      if key in ('prompt_tokens', 'completion_tokens', 'total_tokens',
                                 'prompt_cache_hit_tokens', 'prompt_cache_miss_tokens')
                      and type(value) in (int, float)} for item in usage]
    outcomes = {tool.get('call_id'): tool for item in requests for tool in item.get('tool_outcomes', [])}
    return {
        'requestCount': len(requests), 'responseCount': len(responses),
        'maximumInputBytes': max((item.get('input_bytes', 0) for item in requests), default=0),
        'maximumReasoningCharacters': max((item.get('reasoning_chars', 0) for item in requests), default=0),
        'allModelsFlash': bool(requests) and all(item.get('model') == 'deepseek-flash' for item in requests),
        'readFileCalls': sum(tool.get('name') == 'read_file' for tool in tools),
        'exactEditProposalCalls': sum(tool.get('name') == 'propose_changes' and 'edits' in tool.get('argument_keys', [])
                                     and 'content' not in tool.get('argument_keys', []) for tool in tools),
        'paginatedReadResults': sum('nextOffset' in tool.get('shape', []) for tool in outcomes.values()),
        'toolErrors': sorted({tool['error'] for tool in outcomes.values() if tool.get('error')}),
        'usage': numeric_usage,
        'transportErrors': sum(item.get('event') == 'transport_error' for item in records),
    }


def run(args):
    base = safe_base(args.base)
    binary = validate_server(args, base)
    proxy_log = args.proxy_log.resolve(strict=True)
    require(proxy_log.is_file(), 'Dedicated proxy structure log must exist')
    spec = json.loads((base / SPEC).read_text(encoding='utf-8'))
    require(spec.get('version') == 1 and spec.get('syntheticOnly') is True, 'Invalid synthetic fixture spec')
    scenario = spec.get('scenario', 'time-adjustment')
    require(scenario in SCENARIOS, 'Unsupported synthetic scenario')
    target_path = WEEK if scenario == 'independent-tasks' else TIMETABLE
    require(spec['targetPath'] == target_path, 'Scenario target does not match prepared fixture')
    repo = base / 'repository'
    for name, expected in spec['files'].items():
        require(fingerprint(repo / name) == expected, 'Fixture source differs from prepared synthetic bytes')
    report = {'result': 'RUNNING', 'syntheticOnly': True, 'productionAccessed': False, 'scenario': scenario,
              'realDeviceTested': False, 'binarySHA256': sha(binary.read_bytes()),
              'requiredReferenceBytes': sum(spec['files'][name]['bytes'] for name in TARGET_BYTES if name not in (WEEK, TIMETABLE)),
              'timetableBytes': spec['files'][TIMETABLE]['bytes'], 'planBytes': spec['files'][WEEK]['bytes'],
              'api': [], 'resources': []}

    class Live(qa.Fixture):
        def __init__(self):
            self.base, self.repo, self.state = base, repo, base / 'state'
            self.binary, self.port = str(binary), args.port
            self.identity = qa.Identity(base)

        def request(self, method, path, payload=None, auth=True, extra_headers=None):
            started = time.monotonic()
            status, result = super().request(method, path, payload, auth, extra_headers)
            report['api'].append({'method': method, 'path': path.split('?')[0], 'status': status,
                                  'milliseconds': round((time.monotonic() - started) * 1000, 2)})
            return status, result

    fixture = Live()
    report_path = base / REPORT
    operation = str(uuid.uuid4())
    original = (repo / target_path).read_text(encoding='utf-8')
    expected = original.replace(spec['oldRow'], spec['newRow'])
    require(original.count(spec['oldRow']) == 1, 'Synthetic edit row must be unique')
    before = {path.relative_to(repo).as_posix(): sha(path.read_bytes()) for path in repo.rglob('*.md')}
    log_start = proxy_log.stat().st_size
    stage = 'pair-and-send'
    try:
        fixture.pair()
        prompt = scenario_prompt(scenario)
        status, _ = fixture.request('POST', '/v1/chat/send', {'text': prompt, 'clientRequestID': operation, 'apiVersion': 1})
        require(status == 202, 'Chat send was not accepted')
        started = time.monotonic()
        stage = 'wait-for-model-terminal'
        terminal = None
        while time.monotonic() - started < args.timeout:
            report['resources'].append(resource_sample(args.pid))
            status, history = fixture.request('GET', '/v1/chat/history')
            require(status == 200, 'Chat history read failed')
            terminal = next((item for item in history.get('terminalTurns', []) if item['turnID'] == operation), None)
            if terminal:
                break
            write_json(report_path, report)
            time.sleep(2)
        require(terminal is not None, 'No authoritative terminal before timeout')
        report['terminal'] = {'status': terminal['status'], 'issueCode': terminal.get('issueCode'),
                              'seconds': round(time.monotonic() - started, 3)}
        require(terminal['status'] == 'completed', 'Model turn did not complete')
        visible = '\n'.join(item.get('text', '') for item in history.get('messages', [])
                            if item.get('turnID') == operation and item.get('role') == 'assistant')
        report['bothFileTailCodesObserved'] = spec['weekCode'] in visible and spec['timetableCode'] in visible
        require(report['bothFileTailCodesObserved'], 'Model did not report both file tail check codes')
        after_turn = {path.relative_to(repo).as_posix(): sha(path.read_bytes()) for path in repo.rglob('*.md')}
        report['allMarkdownUnchangedBeforeConfirmation'] = before == after_turn
        require(before == after_turn, 'Model turn changed a file before confirmation')
        stage = 'inspect-proposal'
        status, pending = fixture.request('GET', '/v1/proposals')
        require(status == 200, 'Proposal list failed')
        proposals = pending.get('proposals', [])
        require(len(proposals) == 1 and proposals[0]['relativePath'] == target_path, 'Expected exactly one scenario target proposal')
        proposal = proposals[0]
        require(proposal['baseHash'] == before[target_path], 'Proposal base hash differs')
        require(proposal['originalContent'] == original and proposal['proposedContent'] == expected,
                'Proposal differs from the exact requested synthetic replacement')
        markers = re.findall(r'^<!-- studyrocket:[^\n]+ -->$', original, flags=re.M)
        require(re.findall(r'^<!-- studyrocket:[^\n]+ -->$', expected, flags=re.M) == markers,
                'Proposal management markers changed')
        report['proposal'] = {'count': 1, 'exactReplacement': True, 'baseHashMatched': True,
                              'managementMarkersPreserved': len(markers),
                              'originalSHA256': sha(original.encode()), 'proposedSHA256': sha(expected.encode())}
        stage = 'confirm-and-replay'
        status, challenge = fixture.request('GET', '/v1/proposals/challenge')
        require(status == 200, 'Challenge request failed')
        token = challenge['challenge']
        request = {'proposalIDs': [proposal['id']],
                   'authorization': token + '|' + fixture.identity.sign(('studyrocket-face-id-v1\n' + token).encode()),
                   'metadata': {'apiVersion': 1, 'baseRevision': fixture.manifest()['revision'],
                                'idempotencyKey': str(uuid.uuid4())}}
        first = fixture.request('POST', '/v1/proposals/apply', request)
        replay = fixture.request('POST', '/v1/proposals/apply', request)
        require(first[0] == 200 and replay == first, 'Signed confirmation or exact replay failed')
        require((repo / target_path).read_text(encoding='utf-8') == expected, 'Confirmed bytes differ from preview')
        after = {path.relative_to(repo).as_posix(): sha(path.read_bytes()) for path in repo.rglob('*.md')}
        require({name: value for name, value in after.items() if name != target_path}
                == {name: value for name, value in before.items() if name != target_path}, 'An unrelated source changed')
        status, pending = fixture.request('GET', '/v1/proposals')
        require(status == 200 and pending.get('proposals') == [], 'Confirmed proposal was not consumed')
        report['confirmation'] = {'applyStatus': first[0], 'replayStatus': replay[0],
                                  'replayReceiptMatched': True, 'exactAppliedBytes': True,
                                  'unrelatedMarkdownUnchanged': True, 'proposalConsumed': True}
        if scenario == 'independent-tasks':
            stage = 'verify-independent-task-snapshot'
            status, snapshot = fixture.request('GET', '/v1/snapshot')
            require(status == 200, 'Confirmed task snapshot read failed')
            today = next((day for day in snapshot['week']['days'] if day['id'] == spec['date']), None)
            require(today is not None, 'Prepared date is outside the current snapshot window')
            week_period = next((slot for slot in today['slots'] if slot['id'] == 'morning'), None)
            home_period = next((slot for slot in snapshot['home']['periods'] if slot['id'] == 'morning'), None)
            require(week_period is not None and home_period is not None, 'Morning task period is missing')
            tasks = week_period['tasks']
            independent = {
                'weekTaskCount': len(tasks), 'homeTaskCount': len(home_period['tasks']),
                'titlesMatched': [task['text'] for task in tasks] == [ORIGINAL_TASK, ADDED_TASK],
                'distinctTaskIDs': len({task['id'] for task in tasks}) == 2,
                'noCheckboxPrefixes': all(not re.match(r'^\s*(?:[-*]\s+)?\[[ xX]\]', task['text']) for task in tasks),
                'bothInitiallyIncomplete': len(tasks) == 2 and all(not task['isCompleted'] for task in tasks),
                'homeWeekTasksMatched': home_period['tasks'] == tasks,
                'canonicalTaskSeparatorObserved': '<br>' in proposal['proposedContent'] and '<br>' in spec['newRow'],
            }
            report['independentTasks'] = independent
            require(independent['weekTaskCount'] == 2 and independent['homeTaskCount'] == 2
                    and all(value for key, value in independent.items() if key not in ('weekTaskCount', 'homeTaskCount')),
                    'Confirmed morning tasks are not independently represented in home and week')
        stage = 'verify-model-structure'
        structure = structure_summary(proxy_log, log_start)
        report['modelStructure'] = structure
        require(structure['readFileCalls'] >= 5 and structure['paginatedReadResults'] >= 4,
                'Insufficient multi-file paginated read evidence')
        require(structure['exactEditProposalCalls'] == 1, 'Expected one internal exact-edit proposal call')
        require(structure['maximumInputBytes'] > 64000, 'Context did not exceed the previous artificial input limit')
        require(structure['usage'] and all(item.get('prompt_tokens', 0) > 0 for item in structure['usage']),
                'No positive provider prompt usage was recorded')
        require(structure['allModelsFlash'] and structure['maximumReasoningCharacters'] > 0,
                'Flash reasoning continuation evidence missing')
        require(not structure['toolErrors'] and structure['transportErrors'] == 0, 'Tool or provider transport errors occurred')
        report['resources'].append(resource_sample(args.pid))
        latencies = [item['milliseconds'] for item in report['api']]
        report['summary'] = {'requests': len(latencies), 'medianMilliseconds': statistics.median(latencies),
                             'maximumRSSBytes': max(item.get('VmRSS', 0) for item in report['resources']),
                             'maximumHWMBytes': max(item.get('VmHWM', 0) for item in report['resources']),
                             'minimumAvailableBytes': min(item.get('MemAvailable', 2**63) for item in report['resources'])}
        report['result'] = 'PASS'
    except Exception as error:
        report.update({'result': 'FAIL', 'stage': stage, 'errorType': type(error).__name__})
        # Only fixed local assertion labels are included; never raw API bodies.
        if isinstance(error, AssertionError):
            report['check'] = str(error)
        if stage == 'wait-for-model-terminal' and report.get('terminal') is None:
            try:
                fixture.request('POST', '/v1/chat/interrupt', {})
            except Exception:
                pass
    write_json(report_path, report)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report['result'] == 'PASS' else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    prepare_parser = commands.add_parser('prepare')
    prepare_parser.add_argument('--base', type=Path, required=True)
    prepare_parser.add_argument('--scenario', choices=SCENARIOS, default='time-adjustment')
    live = commands.add_parser('run')
    live.add_argument('--base', type=Path, required=True)
    live.add_argument('--allow-live-provider', action='store_true')
    live.add_argument('--port', type=int, required=True)
    live.add_argument('--binary', type=Path, required=True)
    live.add_argument('--pid', type=int, required=True)
    live.add_argument('--proxy-log', type=Path, required=True)
    live.add_argument('--timeout', type=int, default=900)
    args = parser.parse_args()
    try:
        if args.command == 'prepare':
            prepare(args)
            return 0
        require(30 <= args.timeout <= 1800, 'Timeout must be between 30 and 1800 seconds')
        return run(args)
    except Exception as error:
        print(json.dumps({'result': 'REJECTED', 'errorType': type(error).__name__,
                          'check': str(error) if isinstance(error, AssertionError) else 'Invalid fixture inputs'}))
        return 2


if __name__ == '__main__':
    sys.exit(main())
