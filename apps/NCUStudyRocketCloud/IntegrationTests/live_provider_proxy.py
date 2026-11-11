#!/usr/bin/env python3
"""Fixed-target live QA proxy. Never logs bodies, reasoning, headers or credentials."""
import argparse,json,os,time,threading,urllib.request,urllib.error,http.server,re
p=argparse.ArgumentParser();p.add_argument('--port',type=int,default=43820);p.add_argument('--log',required=True);a=p.parse_args()
lock=threading.Lock();counter=0

def record(value):
 with lock:
  with open(a.log,'a') as f:f.write(json.dumps(value,separators=(',',':'))+'\n');f.flush()

class Handler(http.server.BaseHTTPRequestHandler):
 def do_POST(self):
  global counter
  if self.path!='/chat/completions':self.send_error(404);return
  size=int(self.headers.get('Content-Length','0'))
  if not 0<size<=2097152:self.send_error(413);return
  data=self.rfile.read(size);payload=json.loads(data)
  with lock:counter+=1;ident=counter
  start=time.monotonic();calls={};finishes=[];urls=set();usage=None
  messages=payload.get('messages',[])
  outcomes=[]
  for m in messages:
   if m.get('role')=='tool':
    try:
     v=json.loads(m.get('content',''));outcomes.append({'call_id':m.get('tool_call_id'),'error':v.get('error') if isinstance(v,dict) else None,'shape':sorted(v.keys()) if isinstance(v,dict) else type(v).__name__})
    except Exception:outcomes.append({'call_id':m.get('tool_call_id'),'shape':'text'})
  record({'event':'request','id':ident,'timestamp':time.time(),'bytes':size,'input_bytes':len(json.dumps({'messages':messages,'tools':payload.get('tools',[])},ensure_ascii=False,separators=(',',':')).encode()),'message_roles':[x.get('role') for x in messages],'reasoning_chars':sum(len(x.get('reasoning_content') or '') for x in messages),'model':payload.get('model'),'reasoning_effort':payload.get('reasoning_effort'),'tool_outcomes':outcomes})
  request=urllib.request.Request('https://api.deepseek.com/chat/completions',data=data,headers={'Authorization':'Bearer '+os.environ['DEEPSEEK_API_KEY'],'Content-Type':'application/json'},method='POST')
  try:
   with urllib.request.urlopen(request,timeout=190) as upstream:
    self.send_response(upstream.status);self.send_header('Content-Type','text/event-stream');self.send_header('Connection','close');self.end_headers()
    for line in upstream:
     try:self.wfile.write(line);self.wfile.flush()
     except (BrokenPipeError,ConnectionResetError):break
     if not line.startswith(b'data:'):continue
     frame=line[5:].strip()
     if frame==b'[DONE]':continue
     try:item=json.loads(frame)
     except Exception:continue
     if item.get('usage'):usage={k:v for k,v in item['usage'].items() if isinstance(v,(int,float))}
     for choice in item.get('choices',[]):
      if choice.get('finish_reason'):finishes.append(choice['finish_reason'])
      delta=choice.get('delta',{})
      for url in re.findall(r'https?://[^\s<>"\]\)]+',delta.get('content') or ''):urls.add(url)
      for call in delta.get('tool_calls',[]):
       old=calls.setdefault(call.get('index',0),{'name':'','arguments':''});fn=call.get('function',{})
       old['name']+=fn.get('name') or '';old['arguments']+=fn.get('arguments') or ''
    result=[]
    for call in calls.values():
     try:arguments=json.loads(call['arguments']);keys=sorted(arguments.keys()) if isinstance(arguments,dict) else []
     except Exception:keys=['invalid_json']
     result.append({'name':call['name'],'argument_keys':keys})
    record({'event':'response','id':ident,'status':upstream.status,'seconds':round(time.monotonic()-start,3),'finish':finishes,'tools':result,'public_url_seen':bool(urls),'usage':usage})
  except urllib.error.HTTPError as error:
   record({'event':'response','id':ident,'status':error.code,'seconds':round(time.monotonic()-start,3)})
   self.send_response(error.code);self.end_headers()
  except Exception as error:
   record({'event':'transport_error','id':ident,'type':type(error).__name__,'seconds':round(time.monotonic()-start,3)})
  self.close_connection=True
 def log_message(self,*args):pass
http.server.ThreadingHTTPServer(('127.0.0.1',a.port),Handler).serve_forever()
