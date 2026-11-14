#!/usr/bin/env python3
"""100MiB bounded multipart/IO and message budget regression. Only synthetic temporary data."""
import argparse,base64,hashlib,http.server,json,threading,time,unittest,uuid
from cloud_acceptance import Fixture

class AttachmentResourceAcceptance(unittest.TestCase):
    binary=''
    def test_maximum_document_streaming_and_combined_message_limit(self):
        size=100*1024*1024;prefix=b'%PDF-1.7\n';block=b'0'*262144
        digest=hashlib.sha256();digest.update(prefix)
        remaining=size-len(prefix)
        while remaining:part=block[:min(remaining,len(block))];digest.update(part);remaining-=len(part)
        upload_sizes=[]
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                length=int(self.headers['Content-Length']);first=self.rfile.read(min(length,8192));remaining=length-len(first)
                filename=first.split(b'filename="',1)[1].split(b'"',1)[0].decode()
                purpose=first.split(b'name="purpose"\r\n\r\n',1)[1].split(b'\r\n')[0].decode()
                while remaining:
                    chunk=self.rfile.read(min(remaining,262144));assert chunk;remaining-=len(chunk)
                upload_sizes.append(length)
                body=json.dumps({'id':'file-api-'+str(uuid.uuid4()),'filename':filename,'purpose':purpose,'bytes':size if filename.endswith('.pdf') else (32*1024*1024-1 if filename.endswith('.json') else 1),'expires_at':int(time.time())+2592000}).encode()
                self.send_response(200);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
            def do_DELETE(self):
                body=b'{"deleted":true}';self.send_response(200);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
            def log_message(self,*args):pass
        provider=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler);thread=threading.Thread(target=provider.serve_forever,daemon=True);thread.start()
        self.addCleanup(provider.server_close);self.addCleanup(provider.shutdown)
        f=Fixture(self.binary);self.addCleanup(f.close);f.upstream=f'http://127.0.0.1:{provider.server_port}/chat/completions';f.start();f.pair()
        def call(action,payload):
            status,result=f.request('POST','/v1/attachments/'+action,payload);self.assertIn(status,(200,202),result);return result
        identity=str(uuid.uuid4());call('create',{'id':identity,'filename':'synthetic-100MiB.pdf','mimeType':'application/pdf','byteCount':size,'sha256':digest.hexdigest(),'apiVersion':1})
        offset=0
        while offset<size:
            part=(prefix+block[:262144-len(prefix)]) if offset==0 else block[:min(262144,size-offset)]
            call('chunk',{'id':identity,'offset':offset,'base64Data':base64.b64encode(part).decode(),'sha256':hashlib.sha256(part).hexdigest()});offset+=len(part)
        call('complete',{'id':identity});deadline=time.monotonic()+20
        while time.monotonic()<deadline:
            result=call('status',{'id':identity})
            if result['state']=='ready':break
            time.sleep(.05)
        self.assertEqual(result['state'],'ready',result);self.assertEqual(len(upload_sizes),1);self.assertGreater(upload_sizes[0],size)
        # A dense 32MiB JSON array would allocate millions of nodes in an AST parser.
        path=f.base/'dense.json';pairs=(32*1024*1024-4)//2
        with path.open('wb') as output:
            output.write(b'[')
            while pairs:
                n=min(pairs,131072);output.write(b'0,'*n);pairs-=n
            output.write(b'0]')
        h=hashlib.sha256()
        with path.open('rb') as source:
            while part:=source.read(262144):h.update(part)
        json_id=str(uuid.uuid4());call('create',{'id':json_id,'filename':'dense.json','mimeType':'application/json','byteCount':path.stat().st_size,'sha256':h.hexdigest(),'apiVersion':1})
        with path.open('rb') as source:
            offset=0
            while part:=source.read(262144):
                call('chunk',{'id':json_id,'offset':offset,'base64Data':base64.b64encode(part).decode(),'sha256':hashlib.sha256(part).hexdigest()});offset+=len(part)
        call('complete',{'id':json_id});deadline=time.monotonic()+20
        while time.monotonic()<deadline:
            state=call('status',{'id':json_id})
            if state['state']=='ready':break
            time.sleep(.05)
        self.assertEqual(state['state'],'ready',state);call('remove',{'id':json_id})
        other=str(uuid.uuid4());call('create',{'id':other,'filename':'extra.txt','mimeType':'text/plain','byteCount':1,'sha256':hashlib.sha256(b'a').hexdigest(),'apiVersion':1})
        call('chunk',{'id':other,'offset':0,'base64Data':'YQ==','sha256':hashlib.sha256(b'a').hexdigest()});call('complete',{'id':other})
        # Combined budget is checked before readiness, so 100MiB+1 byte is always rejected.
        status,response=f.request('POST','/v1/chat/send',{'text':'','attachmentIDs':[identity,other],'clientRequestID':str(uuid.uuid4()),'apiVersion':1})
        self.assertEqual(status,413,response)
        call('remove',{'id':identity});call('remove',{'id':other})
        self.assertFalse((f.state/'attachments/objects'/digest.hexdigest()).exists())

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--binary',required=True);args=parser.parse_args();AttachmentResourceAcceptance.binary=args.binary;unittest.main(argv=[__file__],verbosity=2)
