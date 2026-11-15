"""Opt-in release polling; updates use the editor fence and existing rollback paths."""
import os
import re
import time
from pathlib import Path
from manager import Problem

def manager_version(manager):
    from updates import latest
    release=latest('manager')
    obj=manager.docker.inspect(os.environ.get('HOSTNAME',''))
    image=manager.docker.inspect(obj['Image'],'image')
    result = {'current':os.environ.get('PROJECTBOOK_VERSION','development'),'latest':release['version'],'target':release['image'],'available':not (obj['Config']['Image']==release['image'] or release['image'] in image.get('RepoDigests',[]) or obj['Image']==release['configs'].get(image.get('Architecture')))}
    current=os.environ.get('PROJECTBOOK_VERSION','')
    if current == release['revision']: result['available'] = False
    if result['available'] and re.fullmatch(r'[a-f0-9]{40}',current) and current!=release['revision']:
        from updates import newer_release
        result['available']=newer_release(current,release['revision'])
    return result

def launch_manager(manager, target):
    with manager.guard:
        if manager.active or getattr(manager, 'self_updating', False):
            raise Problem('Wait for current operations to finish.',409)
        current = manager_version(manager)
        if target != current['target'] or not current['available']:
            raise Problem('Refresh available Manager version.',409)
        manager.self_updating = True
    try:
        manager.docker.run('pull',target,timeout=900)
        obj=manager.docker.inspect(os.environ.get('HOSTNAME',''))
        mounts=['--mount','type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock']
        state=next((m for m in obj['Mounts'] if m['Destination']=='/data' and m['Type']=='bind'),None)
        if state:mounts+=['--mount','type=bind,src='+str(Path(state['Source']).parent)+',dst=/deployment']
        manager.docker.run('run','-d','--name','projectbook-manager-updater-'+str(time.time_ns()),*mounts,'--entrypoint','python',obj['Image'],'-m','manager_update',obj['Id'],target)
    except Exception:
        manager.self_updating = False
        raise

def setting(manager, enabled=None):
    with manager.registry.lock:
        if enabled is not None:
            if type(enabled) is not bool:raise Problem('Expected a boolean.')
            manager.registry.data['auto_update'] = enabled
            manager.registry.flush()
        return {'enabled': manager.registry.data.get('auto_update',False),
                'status':getattr(manager,'auto_update_status','Off' if not manager.registry.data.get('auto_update') else 'Waiting for next release check')}

def tick(manager):
    from updates import latest, version
    if not setting(manager)['enabled']:return
    if manager.active or getattr(manager,'self_updating',False):return
    manager.auto_update_status = 'Checking releases'
    releases = {role:latest(role) for role in ('wiki','rag')}
    for b in manager.registry.books():
        if b['state'] != 'ready' or b.get('update_phase') == 'rolled_back':continue
        roles=['wiki']+(['rag'] if b.get('indexing') else [])
        if not any(version(manager,b,releases[role],role)['available'] for role in roles):continue
        # Missing/legacy guard is deliberately fail-closed. Initial deployment is manual.
        try:manager.editing(b,'prepare')
        except Exception:
            manager.auto_update_status = 'Waiting for editors: '+b['name'];return
        manager.registry.update(b['id'],update_targets={role:releases[role]['image'] for role in roles},automatic_update=True)
        try:manager.start(b['id'],'update_book')
        except Exception:
            manager.editing(b,'resume');raise
        manager.auto_update_status='Updating '+b['name'];return
    current=manager_version(manager)
    if current['available']:
        for b in manager.registry.books():
            if b['state'] != 'ready':continue
            if manager.editing(b,'status')['active_editors']:
                manager.auto_update_status='Waiting for editors: '+b['name'];return
        launch_manager(manager,current['target'])
        manager.auto_update_status='Updating Manager'
    else:manager.auto_update_status='Up to date'

def loop(manager):
    while True:
        try:tick(manager)
        except Exception:manager.auto_update_status='Update check unavailable; retrying later'
        time.sleep(120)
