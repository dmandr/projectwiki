"""Cloud validation: force OOM in an isolated child slice; retain all real book data."""
import json
from pathlib import Path
import subprocess
import sys
import time

image = sys.argv[1]
parent = 'projectbookrag.slice'
child = 'projectbookrag-validation.slice'
unit = Path('/run/systemd/system') / child
names = ['pb-memory-validation-' + role for role in ('sentinel', 'a', 'b')]

def run(*args):
    return subprocess.check_output(args, text=True).strip()

try:
    assert run('systemctl', 'show', parent, '-p', 'MemoryMax', '--value') == '1342177280'
    unit.write_text('[Slice]\nMemoryMax=96M\nMemorySwapMax=0\n')
    run('systemctl', 'daemon-reload')
    run('systemctl', 'start', child)
    for i, name in enumerate(names):
        code = 'import time; time.sleep(60)' if i == 0 else 'import time; x=bytearray(65*1024**2); time.sleep(30)'
        run('docker', 'run', '-d', '--name', name, '--restart=no', '--memory', '64m' if i == 0 else '128m',
            '--memory-swap', '64m' if i == 0 else '128m', '--cgroup-parent', parent if i == 0 else child,
            '--entrypoint', 'python', image, '-c', code)
    for _ in range(20):
        data = json.loads(run('docker', 'inspect', *names))
        if any(c['State']['OOMKilled'] for c in data[1:]):
            break
        time.sleep(1)
    assert data[0]['State']['Running'], 'Sentinel was affected'
    assert any(c['State']['OOMKilled'] and c['State']['ExitCode'] == 137 for c in data[1:]), 'Expected group OOM was not observed'
    assert all(c['HostConfig']['RestartPolicy']['Name'] == 'no' for c in data)
    events = Path('/sys/fs/cgroup/projectbookrag.slice/projectbookrag-validation.slice/memory.events').read_text()
    assert any(line.startswith('oom_kill ') and int(line.split()[1]) > 0 for line in events.splitlines())
    print('PASS aggregate cgroup OOM contained; sentinel running; automatic restarts disabled')
    print(events.strip())
finally:
    subprocess.run(['docker', 'rm', '-f', *names], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(['systemctl', 'stop', child], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    unit.unlink(missing_ok=True)
    subprocess.run(['systemctl', 'daemon-reload'])
