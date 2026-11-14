"""Read-only resource overview; no credentials, environment or Docker controls exposed."""
import json
import os
import threading
import time
from pathlib import Path

_lock = threading.Lock()
_cache = None

def snapshot(manager):
    global _cache
    with _lock:
        if _cache and time.monotonic() - _cache[0] < 10:
            return _cache[1]
        memory = {}
        for line in Path('/proc/meminfo').read_text().splitlines():
            key, value = line.split(':', 1)
            if key in ('MemTotal', 'MemAvailable', 'SwapTotal', 'SwapFree'):
                memory[key] = int(value.split()[0]) * 1024
        info = json.loads(manager.docker.run('info', '--format', '{{json .}}'))
        books = manager.registry.books()
        groups = {manager.name(b, role): b['name'] for b in books for role in ('wiki','rag','qdrant')}
        rows = []
        raw = manager.docker.run('stats', '--no-stream', '--format', '{{json .}}', timeout=15)
        for line in raw.splitlines():
            item = json.loads(line)
            rows.append({'name': item['Name'], 'group': groups.get(item['Name'], 'Infrastructure / other'),
                         'cpu': item['CPUPerc'], 'memory': item['MemUsage'], 'memory_percent': item['MemPerc'],
                         'pids': item['PIDs']})
        result = {'updated_at': time.time(), 'memory': memory, 'cpus': info.get('NCPU'),
                  'limits_enabled': os.environ.get('RESOURCE_LIMITS_ENABLED', 'true') == 'true',
                  'containers': sorted(rows, key=lambda r: (r['group'],r['name']))}
        _cache = (time.monotonic(), result)
        return result
