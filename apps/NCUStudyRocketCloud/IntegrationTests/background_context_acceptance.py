import importlib.util,json,time,uuid,argparse
from pathlib import Path
parser=argparse.ArgumentParser();parser.add_argument('--binary',required=True);args=parser.parse_args()
root=Path(__file__).resolve().parent.parent
spec=importlib.util.spec_from_file_location('qa',root/'IntegrationTests/cloud_acceptance.py');qa=importlib.util.module_from_spec(spec);spec.loader.exec_module(qa)
f=qa.Fixture(args.binary)
p=qa.LocalProvider([qa.LocalProvider.frame({'content':'Synthetic source-bound summary.'}),qa.LocalProvider.frame({},'stop'),b'data: [DONE]\n\n'])
archive='SYNTH_ARCHIVE_BEGIN\n'+'中'*9000+'\nSYNTH_ARCHIVE_END'
f.write('工作台/个人经历与能力档案.md',archive);f.upstream=p.url
try:
 f.start();f.pair()
 def chat():
  op=str(uuid.uuid4());assert f.request('POST','/v1/chat/send',{'text':'Synthetic context query','clientRequestID':op,'apiVersion':1})[0]==202
  for _ in range(300):
   h=f.request('GET','/v1/chat/history')[1]
   t=next((x for x in h['terminalTurns'] if x['turnID']==op),None)
   if t:assert t['status']=='completed',t;return
   time.sleep(.02)
  raise AssertionError('timeout')
 chat();assert len(p.requests)==3,len(p.requests)
 chunks=[r['body']['messages'][1]['content'].split('：\n',1)[1] for r in p.requests[:2]]
 assert ''.join(chunks)==archive
 assert all(not r['body']['tools'] for r in p.requests[:2])
 assert len(f.request('GET','/v1/chat/history')[1]['messages'])==2
 f.stop();f.start();chat();assert len(p.requests)==4
 f.write('工作台/个人经历与能力档案.md',archive+' changed');chat();assert len(p.requests)==7
 print('PASS full archive chunk coverage, no-tools bootstrap, invisible derived context, persistent hash cache, changed-source invalidation')
finally:f.close();p.close()
