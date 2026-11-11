import importlib.util,json,hashlib,uuid,time,argparse,http.client
from pathlib import Path
parser=argparse.ArgumentParser();parser.add_argument('--binary',required=True);parser.add_argument('--harness',default=str(Path(__file__).resolve().with_name('cloud_acceptance.py')));args=parser.parse_args()
spec=importlib.util.spec_from_file_location('qa',args.harness);qa=importlib.util.module_from_spec(spec);spec.loader.exec_module(qa)
SKILL='.agents/skills/retro-weekly/SKILL.md';EVIDENCE='工作台/每日记录/2026-11.md'
OLD='---\nname: retro-weekly\ndescription: Synthetic weekly review\n---\n# Steps\n- Read evidence.\n';NEW=OLD+'- 核对原文后再生成流程建议。\n'
QUOTES=[f'2026-11-0{i}｜Synthetic completed behaviour {i}.' for i in range(1,4)]
def tool(name,arguments,i):return {'role':'assistant','content':None,'tool_calls':[{'id':i,'type':'function','function':{'name':name,'arguments':json.dumps(arguments)}}]}
def exercise(case):
 f=qa.Fixture(args.binary)
 try:
  f.write(SKILL,OLD);f.write(EVIDENCE,'\n'.join(QUOTES)+'\n');f.write('.agents/skills/retro-weekly/references/example.md','# Read-only reference\n')
  evidence=[{'path':EVIDENCE,'date':f'2026-11-0{i}','quote':q} for i,q in enumerate(QUOTES,1)]
  content=NEW
  if case=='two-evidence':evidence=evidence[:2]
  if case=='yaml-change':content=NEW.replace('name: retro-weekly','name: renamed')
  if case=='script-change':content=NEW+'```sh\necho nope\n```\n'
  f.model_responses([tool('read_skill',{'name':'retro-weekly'},'read'),tool('read_file',{'path':EVIDENCE},'evidence'),tool('propose_skill_update',{'path':SKILL,'content':content,'baseHash':qa.sha(OLD),'reason':'同类可证规律说明需要先核对原文。','evidence':evidence},'propose'),{'role':'assistant','content':'Synthetic review finished.'}])
  f.start();f.pair()
  assert any(e['path'].endswith('references/example.md') for e in f.manifest()['files'])
  req=f.commit_request({SKILL:NEW});assert f.request('POST','/v1/files/commit',req)[0]==403
  op=str(uuid.uuid4());assert f.request('POST','/v1/chat/send',{'text':'Synthetic weekly review','clientRequestID':op,'apiVersion':1})[0]==202
  for _ in range(200):
   if f.request('GET','/v1/operations/'+op)[1]['state']!='running':break
   time.sleep(.02)
  proposals=f.request('GET','/v1/proposals')[1]['proposals']
  assert (f.repo/SKILL).read_text()==OLD
  if case in ('two-evidence','yaml-change','script-change'):
   assert proposals==[],proposals;print('PASS skill rejection',case);return
  assert len(proposals)==1 and proposals[0]['kind']=='skill',proposals
  if case=='crash':f.stop();f.start(failpoint='after_prepare')
  token=f.request('GET','/v1/proposals/challenge')[1]['challenge']
  request={'proposalIDs':[proposals[0]['id']],'authorization':token+'|'+f.identity.sign(('studyrocket-face-id-v1\n'+token).encode()),'metadata':{'baseRevision':f.manifest()['revision'],'idempotencyKey':str(uuid.uuid4()),'apiVersion':1}}
  if case=='crash':
   try:f.request('POST','/v1/proposals/apply',request);raise AssertionError('expected crash')
   except (OSError,http.client.HTTPException):pass
   f.process.wait(timeout=5);assert f.process.returncode==86;f.start()
  else:assert f.request('POST','/v1/proposals/apply',request)[0]==200
  assert (f.repo/SKILL).read_text()==NEW
  assert f.request('GET','/v1/proposals')[1]['proposals']==[]
  assert f.request('POST','/v1/proposals/apply',request)[0]==200
  f.stop(kill=True);f.start();assert (f.repo/SKILL).read_text()==NEW
  print('PASS skill explicit confirmation/durable replay',case)
 finally:f.close()
for case in ('normal','two-evidence','yaml-change','script-change','crash'):exercise(case)
