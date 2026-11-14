#!/usr/bin/env python3
"""Signed native-files lifecycle tests, exclusively using temporary repositories and loopback provider."""
import argparse, base64, hashlib, http.server, json, socket, sqlite3, threading, time, unittest, uuid
from cloud_acceptance import Fixture, LocalProvider, sha

class FilesProvider:
    def __init__(self):
        self.files=[]; self.uploads=[]; self.chats=[]; self.deleted=[]; self.drop_receipt=False;self.converted_bytes=None;self.page_size=None
        owner=self
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                body=self.rfile.read(int(self.headers.get('Content-Length','0')))
                if self.path == '/files':
                    owner.uploads.append(body)
                    header, data=body.split(b'filename="',1)
                    filename=data.split(b'"',1)[0].decode()
                    purpose=header.split(b'name="purpose"\r\n\r\n')[1].split(b'\r\n')[0].decode()
                    original=data.split(b'\r\n\r\n',1)[1].rsplit(b'\r\n--',1)[0]
                    file={'id':'file-api-'+str(uuid.uuid4()),'filename':filename,'purpose':purpose,'bytes':owner.converted_bytes if owner.converted_bytes is not None else len(original),'expires_at':int(time.time())+2592000}
                    owner.files.append(file)
                    if owner.drop_receipt:
                        owner.drop_receipt=False;self.close_connection=True;return
                    self.send(200,file)
                else:
                    owner.chats.append(json.loads(body))
                    self.send_response(200);self.send_header('Content-Type','text/event-stream');self.send_header('Connection','close');self.end_headers()
                    self.wfile.write(LocalProvider.frame({'content':'attachment answer'},'stop')+b'data: [DONE]\n\n');self.wfile.flush();self.close_connection=True
            def do_GET(self):
                if self.path.startswith('/files/'):
                    found=next((f for f in owner.files if f['id']==self.path.rsplit('/',1)[-1]),None);self.send(200 if found else 404,found or {})
                else:
                    offset=0
                    if '&after=' in self.path:
                        cursor=self.path.split('&after=',1)[1];offset=next(i+1 for i,f in enumerate(owner.files) if f['id']==cursor)
                    selected=owner.files[offset:offset+owner.page_size] if owner.page_size else owner.files
                    self.send(200,{'data':selected,'has_more':bool(owner.page_size and offset+len(selected)<len(owner.files)),'last_id':selected[-1]['id'] if selected else None})
            def do_DELETE(self):
                owner.deleted.append(self.path.rsplit('/',1)[-1]);self.send(200,{'deleted':True})
            def send(self,status,value):
                data=json.dumps(value).encode();self.send_response(status);self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
            def log_message(self,*args):pass
        self.server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
        self.thread=threading.Thread(target=self.server.serve_forever,daemon=True);self.thread.start()
        self.url=f'http://127.0.0.1:{self.server.server_port}/chat/completions'
    def close(self):self.server.shutdown();self.server.server_close();self.thread.join()

class AttachmentAcceptance(unittest.TestCase):
    binary=''
    def setUp(self):
        self.p=FilesProvider();self.f=Fixture(self.binary);self.f.upstream=self.p.url;self.f.start();self.f.pair()
    def tearDown(self):self.f.close();self.p.close()
    def call(self,action,payload,expected=200):
        status,value=self.f.request('POST','/v1/attachments/'+action,payload);self.assertEqual(status,expected,value);return value
    def create(self,data=b'example text',name='example.txt',mime='text/plain',ident=None):
        r={'id':ident or str(uuid.uuid4()),'filename':name,'mimeType':mime,'byteCount':len(data),'sha256':sha(data),'apiVersion':1}
        return self.call('create',r),r
    def upload(self,data=b'example text',name='example.txt',mime='text/plain'):
        a,_=self.create(data,name,mime)
        for offset in range(0,len(data),262144):
            chunk=data[offset:offset+262144];self.call('chunk',{'id':a['id'],'offset':offset,'base64Data':base64.b64encode(chunk).decode(),'sha256':sha(chunk)})
        return self.call('complete',{'id':a['id']},202)
    def ready(self,a):
        deadline=time.monotonic()+8
        while time.monotonic()<deadline:
            a=self.call('status',{'id':a['id']})
            if a['state']=='ready':return a
            time.sleep(.05)
        self.fail(a)
    def terminal(self,turn):
        for _ in range(100):
            value=self.f.request('GET','/v1/chat/history')[1]
            if any(t['turnID']==turn for t in value.get('terminalTurns',[])):return value
            time.sleep(.03)
        self.fail('missing terminal')
    def send(self,ids,text=''):
        turn=str(uuid.uuid4());status,value=self.f.request('POST','/v1/chat/send',{'text':text,'clientRequestID':turn,'apiVersion':1,'attachmentIDs':ids});self.assertEqual(status,202,value);return turn
    def test_chunk_resume_hash_dedup_and_native_file_context(self):
        data=('测试 UTF-8\n'*40000).encode();a,r=self.create(data)
        self.assertEqual(self.call('create',r)['id'],a['id'])
        bad=dict(r,filename='changed.txt');self.call('create',bad,422)
        first=data[:262144];chunk={'id':a['id'],'offset':0,'base64Data':base64.b64encode(first).decode(),'sha256':sha(first)}
        self.call('chunk',dict(chunk,sha256='0'*64),422)
        self.assertEqual(self.call('chunk',chunk)['uploadedBytes'],262144)
        self.assertEqual(self.call('chunk',chunk)['uploadedBytes'],262144)
        self.f.stop(kill=True);self.f.start();self.assertEqual(self.call('status',{'id':a['id']})['uploadedBytes'],262144)
        for offset in range(262144,len(data),262144):
            block=data[offset:offset+262144];self.call('chunk',{'id':a['id'],'offset':offset,'base64Data':base64.b64encode(block).decode(),'sha256':sha(block)})
        a=self.ready(self.call('complete',{'id':a['id']},202));turn=self.send([a['id']]);history=self.terminal(turn)
        message=next(m for m in history['messages'] if m['id']==turn+'/user');self.assertEqual(message['attachments'][0]['id'],a['id'])
        blocks=self.p.chats[-1]['messages'][-1]['content'];self.assertEqual(blocks[0]['type'],'text');self.assertIn('example.txt',blocks[0]['text']);self.assertEqual(blocks[1]['type'],'file')
        received=bytearray();offset=0
        while True:
            part=self.call('read',{'id':a['id'],'offset':offset,'limit':262144});block=base64.b64decode(part['base64Data']);self.assertEqual(sha(block),part['sha256']);received.extend(block)
            if part.get('nextOffset') is None:break
            offset=part['nextOffset']
        self.assertEqual(bytes(received),data)
        self.assertFalse(any(p.suffix != '.md' and not p.name.startswith('.') for p in self.f.repo.rglob('*') if p.is_file()))
        with sqlite3.connect(self.f.state/'cloud.sqlite') as db:self.assertEqual(db.execute('SELECT COUNT(*) FROM attachments').fetchone()[0],1)
    def test_unknown_receipt_reconciles_without_second_upload(self):
        self.p.drop_receipt=True;a=self.ready(self.upload());self.assertEqual(a['state'],'ready');self.assertEqual(len(self.p.uploads),1)
        self.f.stop(kill=True);self.f.start();self.ready(a);self.assertEqual(len(self.p.uploads),1)
    def test_limits_signature_format_and_not_ready_rejected(self):
        status,_=self.f.request('POST','/v1/attachments/create',{},auth=False);self.assertEqual(status,401)
        a,r=self.create();self.call('create',dict(r,id=str(uuid.uuid4()),byteCount=0),422)
        self.call('create',dict(r,id=str(uuid.uuid4()),byteCount=21*1024*1024,filename='a.png',mimeType='image/png'),422)
        self.call('create',dict(r,id=str(uuid.uuid4()),filename='../x.txt'),422)
        self.call('create',dict(r,id=str(uuid.uuid4()),mimeType='text/plain\r\nInjected: yes'),422)
        status,_=self.f.request('POST','/v1/chat/send',{'text':'','clientRequestID':str(uuid.uuid4()),'apiVersion':1,'attachmentIDs':[a['id']]});self.assertEqual(status,409)
        data=b'\xff\x00fake';bad,_=self.create(data)
        self.call('chunk',{'id':bad['id'],'offset':0,'base64Data':base64.b64encode(data).decode(),'sha256':sha(data)})
        self.call('complete',{'id':bad['id']},422)
    def test_expiry_removal_provider_delete_and_metadata_history(self):
        a=self.ready(self.upload());turn=self.send([a['id']]);self.terminal(turn)
        self.call('remove',{'id':a['id']});self.call('read',{'id':a['id'],'offset':0,'limit':100},410)
        for _ in range(100):
            self.call('status',{'id':a['id']})
            if self.p.deleted:break
            time.sleep(.03)
        self.assertTrue(self.p.deleted)
        history=self.f.request('GET','/v1/chat/history')[1];message=next(m for m in history['messages'] if m['id']==turn+'/user');self.assertEqual(message['attachments'][0]['state'],'removed')
        self.assertFalse((self.f.state/'attachments/objects'/a['sha256']).exists())
    def test_duplicate_objects_expiry_and_crash_reconciliation(self):
        data=b'same bytes';a=self.ready(self.upload(data));b=self.ready(self.upload(data))
        self.assertEqual(len(list((self.f.state/'attachments/objects').iterdir())),1)
        self.call('remove',{'id':a['id']});self.assertTrue((self.f.state/'attachments/objects'/a['sha256']).exists())
        self.f.stop(kill=True)
        with sqlite3.connect(self.f.state/'cloud.sqlite') as db:
            record=json.loads(db.execute('SELECT body FROM attachments WHERE id=?',(b['id'],)).fetchone()[0])
            record['attachment']['state']='processing';record['providerFileID']=None;record['uploadStarted']=True
            db.execute('UPDATE attachments SET body=? WHERE id=?',(json.dumps(record,separators=(',',':'),sort_keys=True),b['id']))
        self.f.start();self.ready(b);self.assertEqual(len(self.p.uploads),2,'Restart must query existing provider file, never create another')
        self.f.stop(kill=True)
        with sqlite3.connect(self.f.state/'cloud.sqlite') as db:
            record=json.loads(db.execute('SELECT body FROM attachments WHERE id=?',(b['id'],)).fetchone()[0])
            record['attachment']['expiresAt']=0
            db.execute('UPDATE attachments SET body=? WHERE id=?',(json.dumps(record,separators=(',',':'),sort_keys=True),b['id']))
        self.f.start();self.assertEqual(self.call('status',{'id':b['id']})['state'],'expired')
        self.call('read',{'id':b['id'],'offset':0,'limit':100},410)
        self.assertFalse((self.f.state/'attachments/objects'/a['sha256']).exists())
    def test_pdf_native_purpose_limits_and_office_type_validation(self):
        a=self.ready(self.upload(b'%PDF-1.7\nfixture PDF','期中图解.PDF','application/pdf'))
        self.assertEqual(a['filename'],'期中图解.PDF')
        self.assertEqual(self.p.files[-1]['purpose'],'rich_layout_recognition')
        self.assertIn(b'name="expires_after[anchor]"\r\n\r\ncreated_at',self.p.uploads[-1])
        self.assertIn(b'name="expires_after[seconds]"\r\n\r\n2592000',self.p.uploads[-1])
        status,value=self.f.request('POST','/v1/chat/send',{'text':'','clientRequestID':str(uuid.uuid4()),'apiVersion':1,'attachmentIDs':[a['id']]*11});self.assertEqual(status,422,value)
        import io,zipfile
        buffer=io.BytesIO()
        with zipfile.ZipFile(buffer,'w') as archive:archive.writestr('random.txt','not a word document')
        data=buffer.getvalue();bad,_=self.create(data,'bad.docx','application/vnd.openxmlformats-officedocument.wordprocessingml.document')
        self.call('chunk',{'id':bad['id'],'offset':0,'base64Data':base64.b64encode(data).decode(),'sha256':sha(data)})
        self.call('complete',{'id':bad['id']},422)
    def test_history_attachment_can_be_referenced_by_tool_without_reupload(self):
        a=self.ready(self.upload());self.terminal(self.send([a['id']]))
        self.f.stop();self.f.upstream=None
        self.f.model_responses([{'role':'assistant','content':'','tool_calls':[{'id':'reference-old','type':'function','function':{'name':'reference_attachment','arguments':json.dumps({'id':a['id']})}}]}, {'role':'assistant','content':'Referenced old attachment.'}])
        self.f.start();turn=self.send([],text='Explain the earlier file');history=self.terminal(turn)
        requests=json.loads(self.f.model_fixture.with_name(self.f.model_fixture.name+'.requests.json').read_text())
        blocks=requests[-1][-1]['content'];self.assertTrue(any(b.get('file_id')==self.p.files[0]['id'] for b in blocks))
        receipt=json.loads(next(m['content'] for m in requests[-1] if m.get('tool_call_id')=='reference-old'))
        self.assertEqual(receipt['contentDelivery'],'native_file_block');self.assertEqual(receipt['attachment']['id'],a['id']);self.assertIn('不表示附件为空',receipt['note'])
        self.assertEqual(len(self.p.uploads),1)
        self.assertEqual(next(m for m in history['messages'] if m['id']==turn+'/user')['attachments'][0]['id'],a['id'])
    def test_cancel_between_store_admission_and_task_registration_does_not_contact_provider(self):
        import concurrent.futures
        self.f.stop();self.f.upstream=None;self.f.model_responses([{'role':'assistant','content':'must never execute'}])
        data=json.loads(self.f.model_fixture.read_text());data[0]['_test_admission_delay_ms']=700;self.f.model_fixture.write_text(json.dumps(data));self.f.start()
        turn=str(uuid.uuid4())
        with concurrent.futures.ThreadPoolExecutor() as pool:
            sending=pool.submit(self.f.request,'POST','/v1/chat/send',{'text':'race','clientRequestID':turn,'apiVersion':1})
            for _ in range(100):
                history=self.f.request('GET','/v1/chat/history')[1]
                if any(m['id']==turn+'/user' for m in history['messages']):break
                time.sleep(.005)
            status,receipt=self.f.request('POST','/v1/chat/interrupt',{'turnID':turn,'operationID':str(uuid.uuid4()),'apiVersion':1})
            self.assertEqual(status,200,receipt);self.assertEqual(receipt['status'],'interrupted');self.assertEqual(sending.result()[0],202)
        time.sleep(.1)
        self.assertFalse(self.f.model_fixture.with_name(self.f.model_fixture.name+'.requests.json').exists(),'A terminal turn must never reach provider')
        self.assertEqual(self.terminal(turn)['terminalTurns'][0]['status'],'interrupted')
    def test_corrupt_sqlite_attachment_cannot_traverse_on_restart(self):
        a=self.ready(self.upload());profile=self.f.repo/'PROFILE.md';original=profile.read_bytes()
        self.f.stop(kill=True)
        with sqlite3.connect(self.f.state/'cloud.sqlite') as db:
            record=json.loads(db.execute('SELECT body FROM attachments WHERE id=?',(a['id'],)).fetchone()[0])
            record['attachment']['sha256']='../../../repository/PROFILE.md';record['attachment']['expiresAt']=0
            db.execute('UPDATE attachments SET body=? WHERE id=?',(json.dumps(record,separators=(',',':'),sort_keys=True),a['id']))
        with self.assertRaisesRegex(AssertionError,'server exited at startup'):self.f.start()
        self.assertEqual(profile.read_bytes(),original)
    def test_blob_symlink_cannot_read_or_delete_repository_file(self):
        a=self.ready(self.upload());profile=self.f.repo/'PROFILE.md';original=profile.read_bytes()
        blob=self.f.state/'attachments/objects'/a['sha256'];blob.unlink();blob.symlink_to(profile)
        self.call('read',{'id':a['id'],'offset':0,'limit':10},500)
        self.call('remove',{'id':a['id']},500)
        self.assertEqual(profile.read_bytes(),original)
    def test_restored_provider_id_cannot_delete_another_attachment(self):
        a=self.ready(self.upload(b'first file'));b=self.ready(self.upload(b'second file'))
        wrong=self.p.files[-1]['id'];self.f.stop(kill=True)
        with sqlite3.connect(self.f.state/'cloud.sqlite') as db:
            record=json.loads(db.execute('SELECT body FROM attachments WHERE id=?',(a['id'],)).fetchone()[0])
            record['providerFileID']=wrong;record['attachment']['expiresAt']=0
            db.execute('UPDATE attachments SET body=? WHERE id=?',(json.dumps(record,separators=(',',':'),sort_keys=True),a['id']))
        self.f.start()
        for _ in range(10):self.call('status',{'id':a['id']});time.sleep(.03)
        self.assertNotIn(wrong,self.p.deleted)
        self.assertIn('身份与本地记录不符',self.call('status',{'id':a['id']}).get('issue',''))
        self.assertEqual(self.call('status',{'id':b['id']})['state'],'ready')
    def test_json_streaming_syntax_validation(self):
        for data in (b'{"a": [true, false, null, -1.5e+2], "x":"escaped\\ntext"}', b'123', b'[]', b'{}'):
            self.ready(self.upload(data,'valid.json','application/json'))
        for data in (b'[0,]',b'{"x":}',b'01',b'1e',b'"\\x"',b'['*129+b'0'+b']'*129):
            bad,_=self.create(data,'bad.json','application/json')
            self.call('chunk',{'id':bad['id'],'offset':0,'base64Data':base64.b64encode(data).decode(),'sha256':sha(data)})
            self.call('complete',{'id':bad['id']},422)
    def test_native_conversion_receipt_bytes_preserve_original_and_cleanup(self):
        self.p.converted_bytes=168;self.p.drop_receipt=True
        original=b'synthetic native conversion original data'
        a=self.ready(self.upload(original))
        self.assertEqual(a['byteCount'],len(original));self.assertEqual(a['sha256'],sha(original));self.assertEqual(len(self.p.uploads),1)
        chunk=self.call('read',{'id':a['id'],'offset':0,'limit':262144});self.assertEqual(base64.b64decode(chunk['base64Data']),original)
        with sqlite3.connect(self.f.state/'cloud.sqlite') as db:
            record=json.loads(db.execute('SELECT body FROM attachments WHERE id=?',(a['id'],)).fetchone()[0])
        self.assertEqual(record['providerByteCount'],168)
        self.call('remove',{'id':a['id']})
        for _ in range(100):
            if self.p.deleted:break
            self.call('status',{'id':a['id']});time.sleep(.03)
        self.assertEqual(self.p.deleted,[self.p.files[0]['id']])
    def test_provider_size_safe_integer_never_drives_original_allocation(self):
        self.p.converted_bytes=2**53-1
        a=self.ready(self.upload(b'tiny original'))
        self.assertEqual(a['byteCount'],13)
        self.assertEqual(base64.b64decode(self.call('read',{'id':a['id'],'offset':0,'limit':262144})['base64Data']),b'tiny original')
        self.call('remove',{'id':a['id']})
        for _ in range(100):
            if self.p.deleted:break
            self.call('status',{'id':a['id']});time.sleep(.03)
        self.assertEqual(self.p.deleted,[self.p.files[0]['id']])
    def test_removed_unknown_converted_upload_binds_receipt_before_delete(self):
        self.p.converted_bytes=168;self.p.drop_receipt=True
        a=self.upload(b'converted pending data')
        for _ in range(100):
            with sqlite3.connect(self.f.state/'cloud.sqlite') as db:
                record=json.loads(db.execute('SELECT body FROM attachments WHERE id=?',(a['id'],)).fetchone()[0])
            if record['attachment']['state']=='unknown':break
            time.sleep(.02)
        self.assertEqual(record['attachment']['state'],'unknown')
        self.call('remove',{'id':a['id']})
        for _ in range(100):
            if self.p.deleted:break
            self.call('status',{'id':a['id']});time.sleep(.03)
        self.assertEqual(len(self.p.uploads),1)
        self.assertEqual(self.p.deleted,[self.p.files[0]['id']])
    def test_unknown_receipt_rejects_duplicate_names_across_pages(self):
        self.p.drop_receipt=True;self.p.page_size=1
        a=self.upload()
        for _ in range(100):
            with sqlite3.connect(self.f.state/'cloud.sqlite') as db:
                record=json.loads(db.execute('SELECT body FROM attachments WHERE id=?',(a['id'],)).fetchone()[0])
            if record['attachment']['state']=='unknown':break
            time.sleep(.02)
        self.assertEqual(record['attachment']['state'],'unknown')
        self.p.files.append(dict(self.p.files[0],id='file-api-'+str(uuid.uuid4())))
        for _ in range(100):
            state=self.call('status',{'id':a['id']})
            if '重复模型文件' in state.get('issue',''):break
            time.sleep(.03)
        self.assertEqual(state['state'],'unknown');self.assertIn('重复模型文件',state.get('issue',''));self.assertEqual(len(self.p.uploads),1)
    def test_targeted_cancel_requires_identity_and_terminal_survives_new_turn(self):
        self.f.stop();self.f.upstream=None;self.f.model_responses([{'role':'assistant','content':'late old answer'}])
        data=json.loads(self.f.model_fixture.read_text());data[0]['_test_delay_ms']=30000;self.f.model_fixture.write_text(json.dumps(data));self.f.start()
        old=self.send([],text='old');self.f.request('POST','/v1/chat/interrupt',{'turnID':'active','operationID':str(uuid.uuid4()),'apiVersion':1})
        self.assertEqual(self.f.request('POST','/v1/chat/interrupt',{'turnID':'active','operationID':str(uuid.uuid4()),'apiVersion':1})[0],422)
        cancel={'turnID':old,'operationID':str(uuid.uuid4()),'apiVersion':1};status,receipt=self.f.request('POST','/v1/chat/interrupt',cancel);self.assertEqual(status,200,receipt);self.assertEqual(receipt['status'],'interrupted')
        newer=self.send([],text='new');self.assertEqual(self.f.request('POST','/v1/chat/interrupt',cancel),(status,receipt))
        history=self.f.request('GET','/v1/chat/history')[1];self.assertEqual(next(m for m in history['messages'] if m['turnID']==newer)['status'],'inProgress')
        self.assertFalse(any(m['text']=='late old answer' for m in history['messages']))
        self.f.request('POST','/v1/chat/interrupt',{'turnID':newer,'operationID':str(uuid.uuid4()),'apiVersion':1})

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--binary',required=True);args,rest=parser.parse_known_args();AttachmentAcceptance.binary=args.binary;unittest.main(argv=[__file__,*rest],verbosity=2)
