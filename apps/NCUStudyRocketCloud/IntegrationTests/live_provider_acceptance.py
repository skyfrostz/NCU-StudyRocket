#!/usr/bin/env python3
"""Explicit opt-in live test against an isolated copy only; structured redacted evidence."""
import argparse,json,time,uuid,statistics,sqlite3,re,hashlib,os
from pathlib import Path
import cloud_acceptance as qa
p=argparse.ArgumentParser();p.add_argument('--base',required=True);p.add_argument('--port',type=int,default=43819);p.add_argument('--binary',required=True);p.add_argument('--pid',type=int,required=True);a=p.parse_args()
base=Path(a.base).resolve();repo=base/'repository';state=base/'state'
assert base.name.startswith('live-qa-') and (base/'ALLOW_LIVE_QA').is_file() and a.port!=43818
assert repo!=Path('/var/lib/studyrocket/cloud/repository') and state!=Path('/var/lib/studyrocket/cloud/state')
os.chdir(base)
report={'api':[],'turns':[],'resources':[]};report_file=base/'report.json'
class Live(qa.Fixture):
 def __init__(self):self.base=base;self.repo=repo;self.state=state;self.binary=a.binary;self.port=a.port;self.identity=qa.Identity(base)
 def request(self,method,path,payload=None,auth=True,extra_headers=None):
  start=time.monotonic();status,result=super().request(method,path,payload,auth,extra_headers)
  report['api'].append({'method':method,'path':path.split('?')[0],'status':status,'ms':round((time.monotonic()-start)*1000,2)});return status,result
f=Live()
def save():report_file.write_text(json.dumps(report,ensure_ascii=False,indent=2))
def resources():
 values={}
 try:
  for line in Path(f'/proc/{a.pid}/status').read_text().splitlines():
   if line.startswith(('VmRSS:','VmHWM:')):k,v,*_=line.split();values[k.rstrip(':')]=int(v)*1024
  for line in Path('/proc/meminfo').read_text().splitlines():
   if line.startswith('MemAvailable:'):values['MemAvailable']=int(line.split()[1])*1024
  group=next(x[3:] for x in Path(f'/proc/{a.pid}/cgroup').read_text().splitlines() if x.startswith('0::'))
  for key in ('memory.current','memory.peak'):
   target=Path('/sys/fs/cgroup')/group.lstrip('/')/key
   if target.exists():values[key]=int(target.read_text())
 except Exception as e:values['error']=type(e).__name__
 values['time']=time.time();report['resources'].append(values)
def chat(text,label):
 before=len(report['api']);start=time.monotonic();identifier=str(uuid.uuid4())
 status,_=f.request('POST','/v1/chat/send',{'text':text,'clientRequestID':identifier,'apiVersion':1})
 entry={'label':label,'id':identifier,'send_status':status};report['turns'].append(entry);save()
 if status!=202:return entry
 while time.monotonic()-start<660:
  resources();status,h=f.request('GET','/v1/chat/history');terminal=next((t for t in h.get('terminalTurns',[]) if t['turnID']==identifier),None)
  if terminal:
   message=next((m for m in h.get('messages',[]) if m.get('turnID')==identifier and m.get('role')=='assistant'),{})
   entry.update({'terminal':terminal['status'],'issue':terminal.get('issueCode'),'seconds':round(time.monotonic()-start,3),'visible_chars':len(message.get('text','')),'public_urls':re.findall(r'https?://[^\s<>"\]\)]+',message.get('text','')),'api_calls':len(report['api'])-before});save();print(json.dumps(entry,ensure_ascii=False),flush=True);return entry
  save();time.sleep(2)
 entry['terminal']='timeout';save();f.request('POST','/v1/chat/interrupt',{});return entry
f.pair();resources()
for _ in range(5):
 for path in ['/v1/health','/v1/snapshot','/v1/files/manifest','/v1/history?limit=5','/v1/chat/history','/v1/proposals','/v1/versions','/v1/backups/latest']:f.request('GET',path)
for path in ['PROFILE.md','工作台/下周计划.md','工作台/进度日志.md']:f.request('POST','/v1/files/read',{'path':path})
chat('这是隔离副本中的只读验收，不写正式记录。请读取工作台/下周计划.md与工作台/进度日志.md各前600字，并用read_skill完整读取weekly-reslot技能。然后用web_search搜索“南昌大学 官方网站”，用web_fetch抓取一条官网结果。不要复述任何档案、计划或个人事实，只回复已读取资料、官网页面标题和实际官网链接。不要生成草案。','read_skill_web')
note='笔记/云端隔离验收.md';assert not (repo/note).exists()
chat('仍在隔离副本验收。请先read_file检查笔记/云端隔离验收.md，随后propose_changes建立此文件的草案，完整正文严格为：# 云端隔离验收\n\n- [ ] 合成测试事项\n。不要改任何其他文件，不要写个人事实。只生成待确认草案。','propose_temporary_note')
status,proposals=f.request('GET','/v1/proposals');selected=[x for x in proposals.get('proposals',[]) if x['relativePath']==note]
report['proposal']={'count':len(selected),'file_exists_before_confirmation':(repo/note).exists()}
if len(selected)==1:
 token=f.request('GET','/v1/proposals/challenge')[1]['challenge'];request={'proposalIDs':[selected[0]['id']],'authorization':token+'|'+f.identity.sign(('studyrocket-face-id-v1\n'+token).encode()),'metadata':{'apiVersion':1,'baseRevision':f.manifest()['revision'],'idempotencyKey':str(uuid.uuid4())}}
 status,_=f.request('POST','/v1/proposals/apply',request);report['proposal']['apply_status']=status;report['proposal']['replay_status']=f.request('POST','/v1/proposals/apply',request)[0];report['proposal']['exact_content_match']=(repo/note).read_text()==selected[0]['proposedContent'] if (repo/note).exists() else False
chat('第三轮隔离验收：请读取笔记/云端隔离验收.md，重新读取工作台/下周计划.md前600字，用read_skill读取retro-weekly技能。无需记录个人事实，也不产生草案。只说明笔记是否已存在，以及周复盘应核对哪些可证行为，最多三句话。','continued_context')
# Isolated CAS/replay/stale-group checks, independent of model outcome.
req=f.commit_request({'笔记/云端API验收.md':'# Synthetic API fixture\n'})
report['cas']={'first':f.request('POST','/v1/files/commit',req)[0],'replay':f.request('POST','/v1/files/commit',req)[0]}
stale=f.commit_request({'笔记/云端API验收.md':'new\n'});stale['files'][0]['baseHash']='0'*64;report['cas']['stale']=f.request('POST','/v1/files/commit',stale)[0]
for _ in range(10):f.request('GET','/v1/snapshot');f.request('GET','/v1/history?limit=10')
resources();lat=[x['ms'] for x in report['api']];report['summary']={'requests':len(lat),'median_ms':statistics.median(lat),'p95_ms':sorted(lat)[int(len(lat)*.95)-1],'maximum_rss_bytes':max(x.get('VmRSS',0) for x in report['resources']),'maximum_hwm_bytes':max(x.get('VmHWM',0) for x in report['resources']),'minimum_available_bytes':min(x.get('MemAvailable',2**63) for x in report['resources'])};save();print(json.dumps({'summary':report['summary'],'proposal':report['proposal'],'cas':report['cas']},ensure_ascii=False),flush=True)
