"""Pinned GHCR releases and rollback-safe Wiki replacement."""
import copy
import http.client
import json
import socket
import os
import re
import threading
import time
import requests
from manager import Problem

REPOSITORY = 'dmandr/projectbook'
_cache = {}
_guard = threading.Lock()

def latest(role="wiki"):
    if role not in ("wiki","rag"):raise Problem("Unknown update component.")
    repository="dmandr/projectbook" if role=="wiki" else "dmandr/projectbook-rag"
    global _cache
    with _guard:
        if role in _cache and time.monotonic()-_cache[role][0]<120:return _cache[role][1]
        session=requests.Session()
        r=session.get('https://api.github.com/repos/dmandr/projectwiki/actions/workflows/projectbook-images.yml/runs',params={'status':'success','branch':'master','per_page':1},timeout=15);r.raise_for_status()
        runs=r.json().get('workflow_runs',[])
        if not runs:raise Problem('No successfully published release is available yet.',503)
        revision=runs[0]['head_sha'];tag='sha-'+revision
        r=session.get('https://ghcr.io/token',params={'scope':'repository:'+repository+':pull'},timeout=15);r.raise_for_status()
        headers={'Authorization':'Bearer '+r.json()['token'],'Accept':'application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'}
        r=session.get('https://ghcr.io/v2/'+repository+'/manifests/'+tag,headers=headers,timeout=15);r.raise_for_status()
        index=r.json();digest=r.headers['Docker-Content-Digest'];configs={}
        for item in index.get('manifests',[]):
            platform=item.get('platform',{})
            if platform.get('os')!='linux' or platform.get('architecture') not in ('amd64','arm64'):continue
            m=session.get('https://ghcr.io/v2/'+repository+'/manifests/'+item['digest'],headers=headers,timeout=15);m.raise_for_status();configs[platform['architecture']]=m.json()['config']['digest']
        if not configs:raise Problem('Release has no supported platform manifests.',503)
        value={'revision':revision,'version':revision[:12],'image':'ghcr.io/'+repository+'@'+digest,'configs':configs}
        value['qdrant_image']='qdrant/qdrant:v1.20.0' if role=='rag' else None
        if role=='rag':
            # Dependency is part of the published RAG artifact, never user input.
            m=session.get('https://ghcr.io/v2/'+repository+'/blobs/'+next(iter(configs.values())),headers=headers,timeout=15);m.raise_for_status()
            value['qdrant_image']=(m.json().get('config',{}).get('Labels') or {}).get('io.projectbook.qdrant.image','qdrant/qdrant:v1.20.0')
            if not re.fullmatch(r'qdrant/qdrant:v[0-9]+\.[0-9]+\.[0-9]+',value['qdrant_image']):raise Problem('Invalid Qdrant dependency in RAG release.',503)
        _cache[role]=(time.monotonic(),value);return value

class Connection(http.client.HTTPConnection):
    def connect(self):
        self.sock=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);self.sock.connect('/var/run/docker.sock')

def docker_api(method,path,body=None):
    c=Connection('localhost',timeout=60)
    c.request(method,path,json.dumps(body) if body is not None else None,{'Content-Type':'application/json'})
    r=c.getresponse();data=r.read()
    if r.status>=300:raise Problem('Docker replacement failed (HTTP '+str(r.status)+').',503)
    return json.loads(data) if data else {}

def version(manager,b,release,role="wiki"):
    obj=manager.owned(b,manager.name(b,role))
    if not obj:return {'current':'Not installed','latest':release['version'],'available':False}
    image=manager.docker.inspect(obj['Image'],'image')
    arch=image.get('Architecture');label=image.get('Config',{}).get('Labels') or {}
    current=label.get('org.opencontainers.image.revision') or b.get('installed_revision' if role=='wiki' else 'rag_installed_revision') or obj['Config']['Image']
    return {'current':current[:12] if len(current)==40 else current,'latest':release['version'],
            'available':release['configs'].get(arch)!=obj['Image'],'target':release['image']}

def update(manager,b):
    role=b.get('update_role','wiki');target=b.get('update_target');release=latest() if role=='wiki' else latest(role)
    if target!=release['image']:raise Problem('The release changed. Check versions and start again.',409)
    name=manager.name(b,role);old=manager.owned(b,name)
    if not old:raise Problem('Wiki container is missing.',409)
    backup=name+'-rollback-'+str(int(time.time()))
    manager.registry.update(b['id'],state='updating',update_phase='pulling')
    manager.docker.run('pull',target,timeout=900)
    replacement=copy.deepcopy(old['Config']);replacement.update(Image=target,Hostname='',HostConfig=copy.deepcopy(old['HostConfig']))
    # Persist recovery information before stopping a working container.
    manager.registry.update(b['id'],update_backup=backup,update_previous_image=old['Image'])
    stopped=False;renamed=False;created=False
    try:
        manager.docker.run('stop','--time','30',name);stopped=True
        if role=='wiki':manager.git(b,'sync')
        if role=='rag':prepare_dependency(manager,b,release)
        docker_api('POST','/containers/'+name+'/rename?name='+backup);renamed=True
        docker_api('POST','/containers/create?name='+name,replacement);created=True
        docker_api('POST','/containers/'+name+'/start')
        deadline=time.monotonic()+120
        while time.monotonic()<deadline:
            obj=manager.owned(b,name)
            health=obj['State'].get('Health',{}).get('Status')
            if not obj['State']['Running'] or health=='unhealthy':raise Problem('Updated Wiki failed its health check.',503)
            try:
                if role=='rag':
                    if health=='healthy':break
                else:
                    result=manager.rpc(b,'tools/call',{'name':'get_book_context','arguments':{}})
                    if health=='healthy' and 'result' in result and not result['result'].get('isError'):break
            except Exception:pass
            time.sleep(2)
        else:raise Problem('Updated Wiki readiness timed out.',503)
        fields={'installed_revision' if role=='wiki' else 'rag_installed_revision':release['revision']}
        manager.registry.update(b['id'],state='ready',error='',update_phase='complete',**fields)
    except Exception as error:
        if created:manager.docker.run('rm','-f',name)
        if renamed:docker_api('POST','/containers/'+backup+'/rename?name='+name)
        if role=='rag':restore_dependency(manager,b)
        if stopped:manager.docker.run('start',name)
        manager.registry.update(b['id'],state='ready',update_phase='rolled_back',error='Update failed; previous Wiki restored.')
        return


def recover(manager,b):
    """Restore the previous container after an interrupted replacement."""
    role=b.get('update_role','wiki');name=manager.name(b,role);backup=b.get('update_backup')
    if backup and manager.owned(b,backup):
        if manager.owned(b,name):manager.docker.run('rm','-f',name)
        docker_api('POST','/containers/'+backup+'/rename?name='+name)
    if role=='rag':restore_dependency(manager,b)
    if manager.owned(b,name):manager.docker.run('start',name)
    manager.registry.update(b['id'],state='ready',update_phase='rolled_back',error='Interrupted update; previous Wiki restored.')


def prepare_dependency(manager,b,release):
    name=manager.name(b,'qdrant');old=manager.owned(b,name)
    target=release['qdrant_image'];manager.docker.run('pull',target,timeout=600)
    image=manager.docker.inspect(target,'image')
    if old and old['Image']==image['Id']:return
    if not old:raise Problem('Qdrant dependency is missing.',409)
    backup=name+'-rollback-'+str(int(time.time()))
    mounts=copy.deepcopy(old['HostConfig'].get('Mounts',[]))
    source=next((x for x in mounts if x.get('Target')=='/qdrant/storage'),None)
    if not source or source.get('Type')!='volume':raise Problem('Qdrant requires a managed storage volume.',409)
    cloned=source['Source']+'-upgrade-'+str(int(time.time()))
    manager.registry.update(b['id'],dependency_backup=backup,dependency_volume=cloned)
    manager.docker.run('stop','--time','30',name)
    manager.docker.run('volume','create',*manager.labels(b['id']),cloned)
    # A new volume prevents a newer database from changing rollback data.
    manager.docker.run('run','--rm','--network','none','--entrypoint','python',
        '--mount','type=volume,src='+source['Source']+',dst=/old,readonly',
        '--mount','type=volume,src='+cloned+',dst=/new',
        os.environ.get('MANAGER_IMAGE','projectbook-manager:local'),'-c',
        'import shutil;shutil.copytree("/old","/new",dirs_exist_ok=True)',timeout=600)
    source['Source']=cloned
    body=copy.deepcopy(old['Config']);host=copy.deepcopy(old['HostConfig']);host['Mounts']=mounts
    body.update(Image=image['Id'],Hostname='',HostConfig=host)
    docker_api('POST','/containers/'+name+'/rename?name='+backup)
    docker_api('POST','/containers/create?name='+name,body)
    docker_api('POST','/containers/'+name+'/start')
    deadline=time.monotonic()+60
    while time.monotonic()<deadline:
        try:
            r=requests.get('http://'+name+':6333/readyz',timeout=3)
            if r.status_code==200:return
        except requests.RequestException:pass
        time.sleep(2)
    raise Problem('Compatible Qdrant failed readiness.',503)

def restore_dependency(manager,b):
    name=manager.name(b,'qdrant');backup=manager.registry.get(b['id']).get('dependency_backup')
    if backup and manager.owned(b,backup):
        if manager.owned(b,name):manager.docker.run('rm','-f',name)
        docker_api('POST','/containers/'+backup+'/rename?name='+name)
    if manager.owned(b,name):manager.docker.run('start',name)
