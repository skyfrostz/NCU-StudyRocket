import argparse,json,time,uuid,importlib.util,sqlite3
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--binary',required=True);p.add_argument('--harness',default=str(Path(__file__).resolve().with_name('cloud_acceptance.py')));a=p.parse_args()
s=importlib.util.spec_from_file_location('qa',a.harness);qa=importlib.util.module_from_spec(s);s.loader.exec_module(qa)
f=qa.Fixture(a.binary)
def tool(name,args,i):return {'role':'assistant','content':None,'tool_calls':[{'id':i,'type':'function','function':{'name':name,'arguments':json.dumps(args)}}]}
def run(messages):
 f.stop();f.model_responses(messages+[{'role':'assistant','content':'Synthetic fixture complete.'}]);f.start();op=str(uuid.uuid4());assert f.request('POST','/v1/chat/send',{'text':'Synthetic read delivery regression','clientRequestID':op,'apiVersion':1})[0]==202
 for _ in range(300):
  if f.request('GET','/v1/operations/'+op)[1]['state']!='running':break
  time.sleep(.02)
 return json.loads(Path(str(f.model_fixture)+'.requests.json').read_text())
try:
 f.write('笔记/emoji.md','😀'*8000);f.write('笔记/combining.md','a'+'\u0301'*20000);f.start();f.pair()
 db=sqlite3.connect(f.state/'cloud.sqlite');db.execute("INSERT OR REPLACE INTO kv(key,value) VALUES('legacyRepositoryID',?)",('a'*64,));db.commit();db.close()
 assert f.request('GET','/v1/health')[1]['legacyRepositoryID']=='a'*64
 assert 'legacyRepositoryID' not in f.request('GET','/v1/health',auth=False)[1]
 print('PASS legacy repository mapping visible only to signed clients')
 baseline=f.manifest()['revision'];metadata={'apiVersion':1,'baseRevision':baseline,'idempotencyKey':str(uuid.uuid4())}
 entry={'date':'2025-01-15','deliverables':'Synthetic A','studyTime':'','sleep':'','exercise':'','firstTask':''}
 status,first=f.request('POST','/v1/daily',{'entry':entry,'metadata':metadata});assert status==200 and first['revision']!=baseline,(status,first)
 metadata['idempotencyKey']=str(uuid.uuid4());entry['deliverables']='Synthetic B';assert f.request('POST','/v1/daily',{'entry':entry,'metadata':metadata})[0]==409
 assert 'Synthetic A' in (f.repo/'工作台/每日记录/2025-01.md').read_text()
 print('PASS historical daily CAS: stale same base revision rejected 409')
 propose={'path':'笔记/emoji.md','baseHash':qa.sha('😀'*8000),'content':'Synthetic replaced after full read\n','reason':'synthetic'}
 requests=run([tool('read_file',{'path':'笔记/emoji.md'},'read'),tool('propose_changes',propose,'propose')])
 result=next(json.loads(m['content']) for m in requests[1] if m.get('role')=='tool')
 assert result['nextOffset']<8000 and result['complete'] is False
 assert f.request('GET','/v1/proposals')[1]['proposals']==[]
 for request in requests:
  for m in request:
   if m.get('role')=='tool':assert len(m['content'].encode())<=32000
 print('PASS emoji JSON byte limit: partial read cannot grant proposal hash')
 # Small explicit character pages fit the delivery limit on every platform;
 # all chunks, rather than a former assumption of two pages, authorize edits.
 run([tool('read_file',{'path':'笔记/emoji.md','offset':offset,'limit':2000},f'part-{offset}') for offset in range(0,8000,2000)]+[tool('propose_changes',propose,'propose')])
 assert len(f.request('GET','/v1/proposals')[1]['proposals'])==1
 print('PASS all delivered chunks authorize the complete file')
 huge={'path':'笔记/combining.md','baseHash':qa.sha('a'+'\u0301'*20000),'content':'Synthetic rejected\n','reason':'synthetic'}
 requests=run([tool('read_file',{'path':'笔记/combining.md'},'read'),tool('propose_changes',huge,'propose')])
 assert all(x['relativePath']!='笔记/combining.md' for x in f.request('GET','/v1/proposals')[1]['proposals'])
 assert any('tool_result_too_large' in m.get('content','') for r in requests for m in r if m.get('role')=='tool')
 print('PASS oversized combining Character rejects without read permission')
finally:f.close()
