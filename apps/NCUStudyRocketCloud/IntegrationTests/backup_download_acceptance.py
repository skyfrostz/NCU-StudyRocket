import importlib.util,json,hashlib,base64,datetime,argparse
from pathlib import Path
parser=argparse.ArgumentParser();parser.add_argument('--binary',required=True);args=parser.parse_args()
root=Path(__file__).resolve().parent.parent
spec=importlib.util.spec_from_file_location('qa',root/'IntegrationTests/cloud_acceptance.py');qa=importlib.util.module_from_spec(spec);spec.loader.exec_module(qa)
f=qa.Fixture(args.binary)
try:
 f.start();f.pair()
 assert f.request('GET','/v1/backups/latest')[0]==404
 out=f.base/'backups'/'20261111T120000Z-12345678';out.parent.mkdir()
 f.cli('backup','--repository',str(f.repo),'--state',str(f.state),'--output',str(out))
 entries=[{'path':p.relative_to(out).as_posix(),'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'bytes':p.stat().st_size} for p in out.rglob('*') if p.is_file()]
 (out/'verified-backup.json').write_text(json.dumps({'version':1,'createdAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),'files':entries}))
 assert f.request('GET','/v1/backups/latest',auth=False)[0]==401
 status,m=f.request('GET','/v1/backups/latest');assert status==200,(status,m)
 for e in m['files']:
  data=b'';offset=0
  while True:
   status,c=f.request('POST','/v1/backups/read',{'backupID':m['id'],'path':e['path'],'offset':offset,'limit':1024});assert status==200,(status,c)
   assert c['offset']==offset and c['totalBytes']==e['byteCount']
   data+=base64.b64decode(c['base64Data'])
   if c.get('nextOffset') is None:break
   offset=c['nextOffset']
  assert len(data)==e['byteCount'] and hashlib.sha256(data).hexdigest()==e['sha256']
 assert f.request('POST','/v1/backups/read',{'backupID':'..','path':'cloud.sqlite','offset':0,'limit':1024})[0]==403
 assert f.request('POST','/v1/backups/read',{'backupID':m['id'],'path':'../state/cloud.sqlite','offset':0,'limit':1024})[0]==422
 meta=out/'manifest.json';original=meta.read_text();wrong=json.loads(original);meta.write_text(original.replace(wrong['repositoryID'],'00000000-0000-0000-0000-000000000000'))
 assert f.request('GET','/v1/backups/latest')[0]==404
 meta.write_text(original)
 path=out/'repository/PROFILE.md';path.unlink();path.symlink_to(f.repo/'PROFILE.md')
 assert f.request('GET','/v1/backups/latest')[0]==404
 print('PASS backup download auth, chunk hashes/sizes, traversal, symlink, wrong-repository, no-completed-backup')
finally:f.close()
