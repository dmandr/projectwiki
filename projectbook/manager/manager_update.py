"""Manager replacement runs in an independent, short-lived helper."""
import copy
import os
from pathlib import Path
import sys
import time
from updates import docker_api

def perform(ident,target):
    old=docker_api('GET','/containers/'+ident+'/json');name=old['Name'].lstrip('/');backup=name+'-rollback-'+str(int(time.time()))
    body=copy.deepcopy(old['Config']);body.update(Image=target,Hostname='',HostConfig=old['HostConfig'])
    body['Env']=[('MANAGER_IMAGE='+target if v.startswith('MANAGER_IMAGE=') else v) for v in body['Env']]
    stopped=False;renamed=False;created=False
    try:
        docker_api('POST','/containers/'+ident+'/stop?t=30');stopped=True
        docker_api('POST','/containers/'+ident+'/rename?name='+backup);renamed=True
        docker_api('POST','/containers/create?name='+name,body);created=True
        docker_api('POST','/containers/'+name+'/start')
        deadline=time.monotonic()+120
        while time.monotonic()<deadline:
            d=docker_api('GET','/containers/'+name+'/json')
            if d['State'].get('Health',{}).get('Status')=='healthy':break
            if not d['State']['Running']:raise RuntimeError('Manager exited')
            time.sleep(2)
        else:raise RuntimeError('Manager readiness timed out')
        p=Path('/deployment/.env')
        if p.exists():p.write_text('\n'.join('MANAGER_IMAGE='+target if l.startswith('MANAGER_IMAGE=') else l for l in p.read_text().splitlines())+'\n')
    except Exception:
        if created:docker_api('DELETE','/containers/'+name+'?force=1')
        if renamed:docker_api('POST','/containers/'+backup+'/rename?name='+name)
        if stopped:docker_api('POST','/containers/'+name+'/start')
        raise
    finally:
        import subprocess
        subprocess.run(['docker','exec','projectbook-manager-proxy-1','nginx','-s','reload'],capture_output=True)

if __name__=='__main__':perform(sys.argv[1],sys.argv[2])
