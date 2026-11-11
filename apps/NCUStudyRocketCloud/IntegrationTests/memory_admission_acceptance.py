#!/usr/bin/env python3
"""Synthetic memory admission boundaries; no production data or provider."""
import argparse
import json
from pathlib import Path
import time
import uuid
from unittest.mock import patch
import cloud_acceptance as qa

parser=argparse.ArgumentParser();parser.add_argument('--binary',required=True);args=parser.parse_args()

def tool(name,arguments,identifier):
    return {'role':'assistant','content':None,'tool_calls':[{'id':identifier,'type':'function','function':{'name':name,'arguments':json.dumps(arguments)}}]}

def start(f,available,current):
    original=qa.subprocess.Popen
    def launch(command,*pos,**kw):
        if len(command)>1 and command[1]=='serve':
            command=list(command)+['--allow-test-failpoints','--test-memory-available-mib',str(available),'--test-memory-current-mib',str(current)]
        return original(command,*pos,**kw)
    with patch.object(qa.subprocess,'Popen',launch):f.start()

def await_run(f,identifier):
    for _ in range(300):
        value=f.request('GET','/v1/operations/'+identifier)[1]
        if value['state']!='running':return
        time.sleep(.02)
    raise AssertionError('model fixture did not complete')

for available,current,denied in [(349,100,True),(1000,280,True),(350,279,False)]:
    f=qa.Fixture(args.binary)
    try:
        f.model_responses([tool('read_file',{'path':'笔记/a.md'},'read'),tool('propose_changes',{'path':'笔记/a.md','baseHash':qa.sha('original A\n'),'content':'memory fixture confirmed\n','reason':'synthetic'},'propose'),{'role':'assistant','content':'Synthetic preview ready.'}])
        start(f,1000,100);f.pair()
        previous={'text':'Synthetic original turn','clientRequestID':str(uuid.uuid4()),'apiVersion':1}
        assert f.request('POST','/v1/chat/send',previous)[0]==202
        await_run(f,previous['clientRequestID'])
        saved=f.request('GET','/v1/proposals')[1]['proposals'];assert len(saved)==1
        f.stop();start(f,available,current)
        assert f.request('POST','/v1/chat/send',previous)[0]==202,'Original idempotent receipt must survive pressure'
        assert f.request('GET','/v1/snapshot')[0]==200
        new={'text':'Synthetic new turn','clientRequestID':str(uuid.uuid4()),'apiVersion':1}
        status,value=f.request('POST','/v1/chat/send',new)
        if denied:
            assert status==503 and value['code']=='memory_pressure' and value['retryable'] is True,(status,value)
            assert f.request('GET','/v1/operations/'+new['clientRequestID'])[0]==404
            assert all(m.get('turnID')!=new['clientRequestID'] for m in f.request('GET','/v1/chat/history')[1]['messages'])
        else:
            assert status==202,(status,value);await_run(f,new['clientRequestID'])
        # A pending, explicitly confirmed proposal still commits under memory pressure.
        token=f.request('GET','/v1/proposals/challenge')[1]['challenge']
        request={'proposalIDs':[saved[0]['id']],'authorization':token+'|'+f.identity.sign(('studyrocket-face-id-v1\n'+token).encode()),'metadata':{'baseRevision':f.manifest()['revision'],'idempotencyKey':str(uuid.uuid4()),'apiVersion':1}}
        assert f.request('POST','/v1/proposals/apply',request)[0]==200
        assert (f.repo/'笔记/a.md').read_text()=='memory fixture confirmed\n'
        print(f'PASS available={available}MiB current={current}MiB denied={denied}: replay/read/confirmation remain available')
    finally:f.close()
