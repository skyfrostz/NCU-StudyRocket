#!/usr/bin/env python3
"""Only synthetic history can be trimmed; current request/reference/reasoning stay intact."""
import argparse,json,time,uuid
from pathlib import Path
import cloud_acceptance as qa
p=argparse.ArgumentParser();p.add_argument('--binary',required=True);a=p.parse_args();f=qa.Fixture(a.binary)
# Exercise a deliberately lowered deployment window, not the model default.
f.context_tokens=66_432 # 48,000 input after fixed output and protocol reserves.
PROFILE='SYNTHETIC_REQUIRED_PROFILE\n'+'P'*24000
reasoning='SYNTHETIC_CURRENT_REASONING_'*20

def turn(messages,text='SYNTHETIC_CURRENT_REQUEST_MUST_SURVIVE'):
 f.stop();f.model_responses(messages);f.start();operation=str(uuid.uuid4())
 assert f.request('POST','/v1/chat/send',{'text':text,'clientRequestID':operation,'apiVersion':1})[0]==202
 for _ in range(300):
  terminal=next((x for x in f.request('GET','/v1/chat/history')[1]['terminalTurns'] if x['turnID']==operation),None)
  if terminal:return terminal
  time.sleep(.02)
 raise AssertionError('No terminal')

try:
 f.write('PROFILE.md',PROFILE);f.write('笔记/a.md','A'*8000);f.write('笔记/b.md','B'*8000)
 f.start();f.pair()
 assert turn([{'role':'assistant','content':'OLD_VISIBLE_'+'Z'*6000}])['status']=='completed'
 for index in range(3):
  calls=[{'id':f'read-{path}','type':'function','function':{'name':'read_file','arguments':json.dumps({'path':f'笔记/{path}.md'})}} for path in ('a','b')]
  assert turn([{'role':'assistant','content':None,'reasoning_content':reasoning,'tool_calls':calls},{'role':'assistant','content':'OLD_VISIBLE_'+'Z'*6000}])['status']=='completed'
  requests=json.loads(Path(str(f.model_fixture)+'.requests.json').read_text())
  final=requests[-1]
  assert any(m.get('content')=='SYNTHETIC_CURRENT_REQUEST_MUST_SURVIVE' for m in final)
  assert any(PROFILE in (m.get('content') or '') for m in final)
  assert any(m.get('reasoning_content')==reasoning for m in final)
  assert sum(m.get('role')=='tool' for m in final)==2
  assert not any((m.get('content') or '').startswith('OLD_VISIBLE_') for m in final), 'Only old visible history should leave the budget'
 failed=turn([{'role':'assistant','content':'should not be reached'}],text='CURRENT_OVERSIZE_'+'X'*30000)
 assert failed['status']=='failed' and failed['issueCode']=='context_budget'
 assert turn([{'role':'assistant','content':'Recovered with a small current request.'}])['status']=='completed'
 print('PASS 3 long-history tool rounds retain current request/profile/reasoning; oversized current request fails explicitly; next small request recovers')
finally:f.close()
