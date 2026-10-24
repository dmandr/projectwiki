"""Run after index readiness. Full report stays in the private generated state volume."""
import json
import statistics
import time
import urllib.request
from pathlib import Path


def call(path, data=None):
    request = urllib.request.Request('http://localhost:8090' + path,
        data=json.dumps(data).encode() if data is not None else None,
        headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(request, timeout=120) as response:
        return json.load(response)


status = call('/status')
if status['state'] != 'ready':
    raise SystemExit('Index not ready: ' + status['state'])
queries = ['охлаждение двигателя и замена крыльчатки', 'engine oil maintenance',
           'how to connect a PL259 coaxial connector', 'настройки солнечного контроллера зарядки',
           'VHF radio distress call', 'управление аккумуляторами через Cerbo']
results = []
for mode in ('semantic', 'hybrid', 'keyword'):
    for query in queries:
        started = time.perf_counter()
        result = call('/search', {'query': query, 'mode': mode, 'limit': 5})
        results.append({'mode': mode, 'query': query, 'wall_seconds': round(time.perf_counter() - started, 4),
                        'items': [{k: item.get(k) for k in ('path', 'page', 'heading', 'score')} for item in result['items']]})
report = {'index': status, 'queries': results}
Path('/state/benchmark.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
print(json.dumps({'index_seconds': status['report']['total_seconds'],
    'query_timings': {mode: {'median_seconds': round(statistics.median(r['wall_seconds'] for r in results if r['mode'] == mode), 4),
                            'max_seconds': max(r['wall_seconds'] for r in results if r['mode'] == mode)} for mode in ('semantic', 'hybrid', 'keyword')},
    'full_report': '/state/benchmark.json'}, indent=2))
