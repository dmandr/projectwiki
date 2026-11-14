"""Explicit wiki-only image replacement, keeping configuration and a rollback container.
Run on the Docker host. Inspection snapshots contain secrets and remain mode 0600.
"""
import http.client, socket, json, os, time, sys, re
from pathlib import Path
class Docker(http.client.HTTPConnection):
 def __init__(self): super().__init__('localhost')
 def connect(self):
  self.sock=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);self.sock.connect('/var/run/docker.sock')
def api(method,path,data=None):
 c=Docker();c.request(method,'/v1.47'+path,body=None if data is None else json.dumps(data),headers={'Content-Type':'application/json'});r=c.getresponse();body=r.read();c.close()
 if r.status>=300:raise RuntimeError('Docker operation failed, HTTP '+str(r.status))
 return json.loads(body) if body else None
name,image=sys.argv[1:]
assert re.fullmatch(r'pb-[a-f0-9]+-[a-f0-9]+-wiki',name)
old=api('GET','/containers/'+name+'/json');api('GET','/images/'+image+'/json')
backup=name+'-before-update-'+str(int(time.time()))
folder=Path('/opt/projectbook/backups/wiki-updates');folder.mkdir(parents=True,exist_ok=True)
fd=os.open(folder/(backup+'.json'),os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
with os.fdopen(fd,'w') as f:json.dump(old,f)
config=old['Config'].copy();config['Image']=image
networks={network:{'Aliases':[a for a in details.get('Aliases') or [] if a not in [old['Id'],old['Id'][:12]]]} for network,details in old['NetworkSettings']['Networks'].items()}
config.update(HostConfig=old['HostConfig'],NetworkingConfig={'EndpointsConfig':networks})
api('POST','/containers/'+name+'/update',{'RestartPolicy':{'Name':'no'}})
api('POST','/containers/'+name+'/stop?t=30');api('POST','/containers/'+name+'/rename?name='+backup)
try:
 api('POST','/containers/create?name='+name,config);api('POST','/containers/'+name+'/start')
 for _ in range(30):
  state=api('GET','/containers/'+name+'/json')['State']
  if state.get('Health',{}).get('Status')=='healthy':break
  if not state['Running']:raise RuntimeError('Container stopped')
  time.sleep(4)
 else:raise RuntimeError('Health check failed')
 print('Healthy: '+name+'; rollback: '+backup)
except Exception:
 try:api('DELETE','/containers/'+name+'?force=true')
 except Exception:pass
 api('POST','/containers/'+backup+'/rename?name='+name)
 api('POST','/containers/'+name+'/update',{'RestartPolicy':old['HostConfig']['RestartPolicy']})
 api('POST','/containers/'+name+'/start');raise
