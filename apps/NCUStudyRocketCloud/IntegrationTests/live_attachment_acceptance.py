#!/usr/bin/env python3
"""Opt-in native DeepSeek Files API probe, only synthetic PNG/PDF and temporary academic files.
Requires DEEPSEEK_API_KEY. Never points the app at a production repository. Records no credential.
python3 live_attachment_acceptance.py --binary /path/StudyRocketCloud --report /tmp/live-files.json
"""
import argparse, base64, http.server, io, json, os, re, struct, threading, time, urllib.request, urllib.error, uuid, zipfile, zlib
from pathlib import Path
from cloud_acceptance import Fixture, sha

def png():
    width,height=400,260
    pixels=bytearray([245,245,245]*(width*height))
    def rect(x,y,w,h,color):
        for yy in range(y,y+h):
            for xx in range(x,x+w):pixels[(yy*width+xx)*3:(yy*width+xx)*3+3]=bytes(color)
    rect(90,25,220,210,(220,35,35))
    segments={'4':[1,2,5,6],'2':[0,1,6,4,3]}
    geometry=[(0,0,40,9),(32,0,9,48),(32,43,9,48),(0,82,40,9),(0,43,9,48),(0,0,9,48),(0,41,40,9)]
    for digit,x in [('4',140),('2',210)]:
        for segment in segments[digit]:
            dx,dy,w,h=geometry[segment];rect(x+dx,80+dy,w,h,(255,255,255))
    def chunk(name,data):return struct.pack('>I',len(data))+name+data+struct.pack('>I',zlib.crc32(name+data)&0xffffffff)
    raw=b''.join(b'\0'+pixels[y*width*3:(y+1)*width*3] for y in range(height))
    return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',width,height,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(raw))+chunk(b'IEND',b'')

def pdf():
    content=b'0.1 0.25 0.85 rg 80 80 m 260 80 l 170 250 l h f\nBT /F1 18 Tf 0 0 0 rg 90 290 Td (SYNTHETIC FIGURE) Tj ET\nBT /F1 24 Tf 0 0 0 rg 115 40 Td (VALUE: 73) Tj ET\n'
    objects=[b'<< /Type /Catalog /Pages 2 0 R >>',b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 350] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',b'<< /Length '+str(len(content)).encode()+b' >>\nstream\n'+content+b'endstream']
    data=bytearray(b'%PDF-1.4\n');offsets=[0]
    for i,obj in enumerate(objects,1):offsets.append(len(data));data.extend(f'{i} 0 obj\n'.encode()+obj+b'\nendobj\n')
    start=len(data);data.extend(f'xref\n0 {len(offsets)}\n0000000000 65535 f \n'.encode())
    for offset in offsets[1:]:data.extend(f'{offset:010d} 00000 n \n'.encode())
    data.extend(f'trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{start}\n%%EOF\n'.encode());return bytes(data)

def office_document(kind):
    ns='http://schemas.openxmlformats.org'
    rels='<?xml version="1.0"?><Relationships xmlns="'+ns+'/package/2006/relationships"><Relationship Id="rId1" Type="'+ns+'/officeDocument/2006/relationships/officeDocument" Target="'+('word/document.xml' if kind=='docx' else 'xl/workbook.xml')+'"/></Relationships>'
    files={'_rels/.rels':rels}
    defaults='<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>'
    if kind=='docx':
        override='<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
        files['word/document.xml']='<?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="'+ns+'/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>SYNTHETIC DOCUMENT QA CODE: ORCHID-864</w:t></w:r></w:p><w:sectPr/></w:body></w:document>'
    else:
        override='<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
        files['xl/workbook.xml']='<?xml version="1.0"?><workbook xmlns="'+ns+'/spreadsheetml/2006/main" xmlns:r="'+ns+'/officeDocument/2006/relationships"><sheets><sheet name="SyntheticQA" sheetId="1" r:id="rId1"/></sheets></workbook>'
        files['xl/_rels/workbook.xml.rels']='<?xml version="1.0"?><Relationships xmlns="'+ns+'/package/2006/relationships"><Relationship Id="rId1" Type="'+ns+'/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>'
        files['xl/worksheets/sheet1.xml']='<?xml version="1.0"?><worksheet xmlns="'+ns+'/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>ValidationCode</t></is></c><c r="B1" t="inlineStr"><is><t>Value</t></is></c></row><row r="2"><c r="A2" t="inlineStr"><is><t>GINKGO-915</t></is></c><c r="B2"><v>915</v></c></row></sheetData></worksheet>'
    files['[Content_Types].xml']='<?xml version="1.0"?><Types xmlns="'+ns+'/package/2006/content-types">'+defaults+override+'</Types>'
    data=io.BytesIO()
    with zipfile.ZipFile(data,'w',compression=zipfile.ZIP_DEFLATED) as archive:
        for name,content in files.items():archive.writestr(name,content.encode())
    return data.getvalue()

class Proxy:
    def __init__(self,key,journal=None):
        self.journal=journal
        self.key=key;self.uploads=0;self.tool_calls=0;self.file_blocks=0;self.paths=[];self.deleted_ids=set();self.native_files=[];self.chat_file_ids=[]
        owner=self
        class Handler(http.server.BaseHTTPRequestHandler):
            def handle_request(self):
                body=self.rfile.read(int(self.headers.get('Content-Length','0')))
                headers={'Authorization':'Bearer '+owner.key}
                if self.headers.get('Content-Type'):headers['Content-Type']=self.headers['Content-Type']
                if self.path=='/files' and self.command=='POST':owner.uploads+=1
                if self.path=='/chat/completions':
                    request=json.loads(body)
                    ids=[b['file_id'] for m in request['messages'] if isinstance(m.get('content'),list) for b in m['content'] if isinstance(b,dict) and b.get('type')=='file']
                    owner.file_blocks+=len(ids);owner.chat_file_ids.append(ids)
                owner.paths.append(self.command+' '+self.path.split('?')[0])
                req=urllib.request.Request('https://api.deepseek.com'+self.path,data=body if self.command=='POST' else None,method=self.command,headers=headers)
                try:response=urllib.request.urlopen(req,timeout=300)
                except urllib.error.HTTPError as error:response=error
                self.send_response(response.status);self.send_header('Content-Type',response.headers.get('Content-Type','application/json'));self.send_header('Connection','close');self.end_headers()
                try:
                    if self.command=='POST' and self.path=='/files':
                        data=response.read(65536)
                        try:receipt=json.loads(data)
                        except (ValueError,UnicodeDecodeError):receipt={}
                        if 200 <= response.status < 300:
                            owner.native_files.append(receipt);owner.persist_journal()
                        self.wfile.write(data);self.wfile.flush();return
                    if self.command=='DELETE':
                        data=response.read(65536)
                        try:receipt=json.loads(data)
                        except (ValueError,UnicodeDecodeError):receipt={}
                        if 200 <= response.status < 300 and receipt.get('deleted') is True:
                            owner.deleted_ids.add(self.path.rsplit('/',1)[-1]);owner.persist_journal()
                        self.wfile.write(data);self.wfile.flush();return
                    while True:
                        data=response.read1(16384)
                        if not data:break
                        if b'"tool_calls"' in data:owner.tool_calls+=1
                        self.wfile.write(data);self.wfile.flush()
                except (BrokenPipeError,ConnectionResetError):pass
                finally:response.close();self.close_connection=True
            do_POST=handle_request;do_GET=handle_request;do_DELETE=handle_request
            def log_message(self,*args):pass
        self.server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler);self.thread=threading.Thread(target=self.server.serve_forever,daemon=True);self.thread.start()
        self.url=f'http://127.0.0.1:{self.server.server_port}/chat/completions'
    def persist_journal(self):
        if self.journal is None:return
        value={'synthetic':True,'files':[{k:item.get(k) for k in ('id','filename','purpose','bytes','created_at','expires_at')} for item in self.native_files],'deleted_ids':sorted(self.deleted_ids)}
        temp=self.journal.with_suffix('.tmp')
        fd=os.open(temp,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
        with os.fdopen(fd,'w') as stream:json.dump(value,stream)
        os.replace(temp,self.journal)
    def diagnose_pdf(self):
        file=next(item for item in self.native_files if item.get('purpose')=='rich_layout_recognition')
        payload={'model':'deepseek-flash','stream':False,'max_tokens':16384,'thinking':{'type':'enabled'},'reasoning_effort':'high','messages':[{'role':'user','content':[{'type':'text','text':'请直接读取此合成PDF，回答其图形形状、颜色和VALUE数字。不猜测，不用工具。'},{'type':'file','file_id':file['id']}]}]}
        req=urllib.request.Request('https://api.deepseek.com/chat/completions',data=json.dumps(payload).encode(),headers={'Authorization':'Bearer '+self.key,'Content-Type':'application/json'})
        with urllib.request.urlopen(req,timeout=180) as response:result=json.load(response)
        return result['choices'][0]['message'].get('content','')
    def close(self):self.server.shutdown();self.server.server_close();self.thread.join()

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--binary',required=True);parser.add_argument('--report',required=True);parser.add_argument('--office',action='store_true');args=parser.parse_args()
    key=os.environ.get('DEEPSEEK_API_KEY');assert key,'DEEPSEEK_API_KEY is required; never place it on command line'
    proxy=Proxy(key,Path(args.report).with_name("provider-cleanup-journal.json"));f=Fixture(args.binary);f.upstream=proxy.url;ids=[];report={'synthetic':True,'repository':'temporary fixture','result':'FAIL'}
    try:
        f.start();f.pair()
        def call(action,payload):
            status,value=f.request('POST','/v1/attachments/'+action,payload);assert status in (200,202),(status,value);return value
        items=[('shape.png','image/png',png()),('diagram.pdf','application/pdf',pdf())]
        if args.office:items += [('document.docx','application/vnd.openxmlformats-officedocument.wordprocessingml.document',office_document('docx')),('table.xlsx','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',office_document('xlsx'))]
        report['formats']=[name.rsplit('.',1)[-1] for name,_,_ in items]
        for name,mime,data in items:
            ident=str(uuid.uuid4());ids.append(ident)
            call('create',{'id':ident,'filename':name,'mimeType':mime,'byteCount':len(data),'sha256':sha(data),'apiVersion':1})
            for offset in range(0,len(data),262144):
                block=data[offset:offset+262144];call('chunk',{'id':ident,'offset':offset,'base64Data':base64.b64encode(block).decode(),'sha256':sha(block)})
            call('complete',{'id':ident});deadline=time.monotonic()+360
            while time.monotonic()<deadline:
                state=call('status',{'id':ident})
                if state['state']=='ready':break
                assert state['state'] not in ('failed','expired','removed'),state
                time.sleep(2)
            assert state['state']=='ready',state
        turn=str(uuid.uuid4())
        prompt='这是隔离合成验收。请先调用list_files只列出当前临时资料，再读取两个附件：说明PNG里的形状、颜色和数字，以及PDF中的形状、颜色和VALUE数字。不要生成任何草案，也不要输出附件编号。'
        if args.office:prompt+=' Also report the exact validation codes in the DOCX and XLSX, preserving hyphens.'
        status,receipt=f.request('POST','/v1/chat/send',{'text':prompt,'clientRequestID':turn,'apiVersion':1,'attachmentIDs':ids});assert status==202,receipt
        deadline=time.monotonic()+360;history={}
        while time.monotonic()<deadline:
            status,history=f.request('GET','/v1/chat/history');terminal=next((t for t in history.get('terminalTurns',[]) if t['turnID']==turn),None)
            if terminal:break
            time.sleep(2)
        assert terminal and terminal['status']=='completed',terminal
        answer='\n'.join(m['text'] for m in history['messages'] if m.get('turnID')==turn and m['role']=='assistant')
        report.update(answer=answer,uploads=proxy.uploads,file_blocks=proxy.file_blocks,tool_call_frames=proxy.tool_calls)
        report['native_files']=[{k:item.get(k) for k in ('purpose','bytes','created_at','expires_at')} for item in proxy.native_files]
        report['all_native_files_referenced_each_round']=all(all(item['id'] in refs for item in proxy.native_files) for refs in proxy.chat_file_ids)
        report['direct_pdf_diagnostic']=proxy.diagnose_pdf()
        assert report['all_native_files_referenced_each_round'],report
        assert len(proxy.native_files)==len(ids) and all(item.get('expires_at') for item in proxy.native_files),report
        direct=report['direct_pdf_diagnostic'].lower()
        assert re.search(r'(?<![0-9])73(?![0-9])',direct) and any(x in direct for x in ('蓝','blue')) and any(x in direct for x in ('三角','triangle')),direct
        visible=re.sub(r'(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b','[attachment-id]',answer)
        assert all(re.search(r'(?<![0-9])'+number+r'(?![0-9])',visible) for number in ['42','73']),answer
        lowered=answer.lower()
        for choices in [('红','red'),('蓝','blue'),('三角','triangle'),('方','square','rectangle')]:
            assert any(word in lowered for word in choices),('Missing visual evidence',choices,answer)
        if args.office:assert all(code in answer for code in ['ORCHID-864','GINKGO-915']),answer
        assert proxy.uploads==len(ids) and proxy.file_blocks>=len(ids) and proxy.tool_calls>0,report
        report['result']='PASS'
    finally:
        for ident in ids:
            try:f.request('POST','/v1/attachments/remove',{'id':ident})
            except Exception:pass
        deadline=time.monotonic()+20
        while time.monotonic()<deadline and len(proxy.deleted_ids)<len(ids):
            for ident in ids:
                try:f.request('POST','/v1/attachments/status',{'id':ident})
                except Exception:pass
            time.sleep(.5)
        report['provider_delete_requests']=sum(path.startswith('DELETE /files/') for path in proxy.paths)
        report['provider_delete_confirmed']=len(proxy.deleted_ids)
        report['cleanup']='PASS' if len(proxy.deleted_ids)==len(ids) else 'FAIL'
        if report['cleanup']!='PASS':
            report['result']='FAIL'
            report['cleanup_issue']='Not every uploaded native file has a confirmed successful deletion receipt.'
        Path(args.report).write_text(json.dumps(report,ensure_ascii=False,indent=2));f.close();proxy.close()
    print(json.dumps(report,ensure_ascii=False))
    assert report["result"]=="PASS",report
if __name__=='__main__':main()
