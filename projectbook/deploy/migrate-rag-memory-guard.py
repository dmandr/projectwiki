"""Recreate explicitly named RAG/Qdrant containers inside the shared Linux memory slice.
Only Qdrant is restarted. Workers require a deliberate start after inspection.
Old containers and all volumes are retained. Snapshot files may contain secrets.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time


def run(*args):
    return subprocess.check_output(args, text=True).strip()


assert run('systemctl', 'show', 'projectbookrag.slice', '-p', 'MemoryMax', '--value') == '1342177280'
image = os.environ['SAFE_RAG_IMAGE']
for name in sys.argv[1:]:
    if not re.fullmatch(r'(pb-[a-f0-9]+-[a-f0-9]+-(rag|qdrant)|projectbook-cloud-(rag|qdrant)-1)', name):
        raise ValueError('Only explicitly named ProjectBook search containers are supported')
    obj = json.loads(run('docker', 'inspect', name))[0]
    config, host = obj['Config'], obj['HostConfig']
    if host.get('CgroupParent') == 'projectbookrag.slice':
        print(name, 'already protected')
        continue
    networks = obj['NetworkSettings']['Networks']
    assert len(networks) == 1, 'Inspect multiple networks manually'
    network, details = next(iter(networks.items()))
    role = 'rag' if name.endswith(('-rag', '-rag-1')) else 'qdrant'
    limit = '896m' if role == 'rag' else '256m'
    args = ['docker', 'create', '--name', name, '--network', network,
            '--restart=no', '--memory', limit, '--memory-swap', limit,
            '--cpus', '1' if role == 'rag' else '0.5', '--cgroup-parent', 'projectbookrag.slice',
            '--log-opt', 'max-size=10m', '--log-opt', 'max-file=2']
    if host.get('Init'):
        args.append('--init')
    for alias in details.get('Aliases') or []:
        if alias != obj['Id'][:12]:
            args += ['--network-alias', alias]
    for key, value in (config.get('Labels') or {}).items():
        args += ['--label', key + '=' + value]
    for mount in obj['Mounts']:
        source = mount['Name'] if mount['Type'] == 'volume' else mount['Source']
        args += ['--mount', 'type=' + mount['Type'] + ',src=' + source + ',dst=' + mount['Destination'] + ('' if mount['RW'] else ',readonly')]
    env = dict(item.split('=', 1) for item in config.get('Env') or [])
    if role == 'rag':
        env.update(RAG_LOW_MEMORY='true', PDF_MEMORY_MB='128', BATCH_SIZE='1', MODEL_THREADS='1')
    for key, value in env.items():
        args += ['-e', key + '=' + value]
    if config.get('User'):
        args += ['--user', config['User']]
    if config.get('WorkingDir'):
        args += ['--workdir', config['WorkingDir']]
    entry = config.get('Entrypoint') or []
    if entry:
        args += ['--entrypoint', entry[0]]
    args += [image if role == 'rag' else config['Image'], *entry[1:], *(config.get('Cmd') or [])]
    backup = Path('/opt/projectbook/backups/memory-guard')
    backup.mkdir(parents=True, exist_ok=True)
    snapshot = backup / (name + '.json')
    fd = os.open(snapshot, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as f:
        json.dump(obj, f)
    old = name + '-pre-guard-' + str(int(time.time()))
    run('docker', 'update', '--restart=no', name)
    run('docker', 'stop', name)
    run('docker', 'rename', name, old)
    try:
        run(*args)
    except Exception:
        run('docker', 'rename', old, name)
        raise
    if role == 'qdrant':
        run('docker', 'start', name)
    print(name, 'protected; old container and volumes retained; worker stopped' if role == 'rag' else 'protected and running')
