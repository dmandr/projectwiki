"""Run inside the local Manager after starting tests/git_remote.py as git-fixture.

Touches only fixture books whose Git remote is https://git-fixture/*.git.
Leaves installations visible in Manager for inspection.
"""
import json
import base64
from pathlib import Path
import subprocess
import time
import requests

ADMIN = 'http://127.0.0.1:8070'
MCP = 'http://127.0.0.1:8071/mcp'
HEADERS = {'X-ProjectBook-Request': '1'}


def api(path, data=None):
    r = requests.get(ADMIN + path, timeout=10) if data is None else requests.post(ADMIN + path, json=data, headers=HEADERS, timeout=10)
    r.raise_for_status()
    return r.json()


def docker(*args):
    return subprocess.run(['docker', *args], check=True, capture_output=True, text=True).stdout.strip()


def rpc(method, params=None):
    r = requests.post(MCP, json={'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params or {}}, timeout=100)
    r.raise_for_status()
    value = r.json()
    assert 'error' not in value, value
    return value['result']


def tool(name, book_id=None, **args):
    if book_id:
        args['book_id'] = book_id
    result = rpc('tools/call', {'name': name, 'arguments': args})
    assert not result.get('isError'), result
    return json.loads(result['content'][0]['text'])


def wait(book_id, state, seconds=150):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        b = next(b for b in api('/api/books')['books'] if b['id'] == book_id)
        if b['state'] == state:
            return b
        if b['state'] == 'error' and state != 'error':
            raise AssertionError(b)
        time.sleep(1)
    raise AssertionError('Timed out waiting for ' + state)


books = api('/api/books')['books']
alpha = next((b for b in books if b['repo'] == 'https://git-fixture/alpha.git' and b['state'] != 'removed'), None)
if not alpha:
    alpha = api('/api/books', {'name': 'Manager test · Alpha', 'url': 'https://alpha.example.test', 'repo': 'https://git-fixture/alpha.git', 'indexing': True})
alpha = wait(alpha['id'], 'ready')
beta = api('/api/books', {'name': 'Manager test · Beta', 'url': 'https://beta.example.test', 'repo': 'https://git-fixture/beta.git', 'indexing': False})
beta = wait(beta['id'], 'ready')
print('PASS create two books with distinct ports', alpha['port'], beta['port'], flush=True)
assert alpha['port'] != beta['port']
registry = json.loads(Path('/data/registry.json').read_text())
prefix = 'pb-' + registry['owner'][:8] + '-' + beta['id']
container = prefix + '-wiki'
assert json.loads(docker('container', 'inspect', container))[0]['HostConfig']['PortBindings']['4567/tcp'][0]['HostPort'] == str(beta['port'])
docker('restart', container)
assert int(json.loads(docker('container', 'inspect', container))[0]['NetworkSettings']['Ports']['4567/tcp'][0]['HostPort']) == beta['port']
time.sleep(3)
print('PASS book origin port survives container restart', flush=True)
assert 'protocolVersion' in rpc('initialize', {'protocolVersion': '2025-06-18', 'capabilities': {}, 'clientInfo': {'name': 'test', 'version': '1'}})
catalog = rpc('tools/list')['tools']
assert any(t['name'] == 'save_document' and 'book_id' in t['inputSchema']['required'] for t in catalog)
assert len(tool('list_books')['books']) >= 2
assert tool('read_document', alpha['id'], path='Home.md')['title'] == 'Alpha'
assert tool('read_document', beta['id'], path='Home.md')['title'] == 'Beta'
print('PASS MCP discovery and cross-book routing', flush=True)
for b in (alpha, beta):
    resources = rpc('resources/list')['resources']
    uri = next(r['uri'] for r in resources if '/' + b['id'] + '/' in r['uri'])
    assert rpc('resources/read', {'uri': uri})['contents']
    attachment = tool('read_attachment', b['id'], path='sample.txt')
    # Ensure resources embedded in JSON point back to the gateway.
    encoded = json.dumps(attachment)
    assert 'projectbook-manager://' in encoded, attachment
    def uris(value):
        if isinstance(value, dict):
            return sum((uris(v) for v in value.values()), [])
        if isinstance(value, list):
            return sum((uris(v) for v in value), [])
        return [value] if isinstance(value, str) and value.startswith('projectbook-manager://') else []
    original = rpc('resources/read', {'uri': uris(attachment)[0]})['contents'][0]
    assert base64.b64decode(original['blob']).decode().startswith('Attachment from ')
print('PASS namespaced book resources and attachments', flush=True)
previous = rpc('tools/call', {'name': 'read_document', 'arguments': {'book_id': beta['id'], 'path': 'From-manager.md'}})
version = '' if previous.get('isError') else json.loads(previous['content'][0]['text'])['sha']
tool('save_document', beta['id'], path='From-manager.md', content='# Saved through shared MCP\n', expected_version=version, dry_run=False)
assert tool('read_document', beta['id'], path='From-manager.md')['title'] == 'Saved through shared MCP'
assert 'error' in requests.post(MCP, json={'jsonrpc':'2.0','id':2,'method':'tools/call','params':{'name':'read_document','arguments':{'path':'Home.md'}}}).json()
assert requests.post(ADMIN+'/api/books', json={}, headers={'Origin':'https://evil.example','X-ProjectBook-Request':'1'}).status_code == 403
assert requests.post(MCP.replace('/mcp','/api/books'), json={}).status_code == 404
print('PASS MCP write, missing-book rejection, CSRF and admin/MCP separation', flush=True)

# The helper must capture changes outside Git, including ignored Raw Notes.
docker('exec', container, 'sh', '-c', 'mkdir -p /wiki/raw-notes/test; printf "*\\n!.gitignore\\n" > /wiki/raw-notes/.gitignore; printf "local voice transcript '+beta['id']+'\\n" > /wiki/raw-notes/test/note.md; printf "# Uncommitted '+beta['id']+'\\n" > /wiki/Uncommitted.md')
docker('exec', 'projectbook-manager-git-fixture', 'touch', '/repos/reject-push')
api('/api/books/'+beta['id']+'/remove', {'confirm': beta['name']})
wait(beta['id'], 'error')
assert json.loads(docker('container', 'inspect', container))[0]['State']['Running'] is False
assert docker('volume', 'inspect', prefix+'-book')
print('PASS rejected push preserves stopped container and data', flush=True)
docker('exec', 'projectbook-manager-git-fixture', 'rm', '/repos/reject-push')
api('/api/books/'+beta['id']+'/retry', {})
removed = wait(beta['id'], 'removed')
assert docker('exec', 'projectbook-manager-git-fixture', 'git', '--git-dir=/repos/beta.git', 'show', 'main:Uncommitted.md') == '# Uncommitted '+beta['id']
assert docker('exec', 'projectbook-manager-git-fixture', 'git', '--git-dir=/repos/beta.git', 'show', 'main:raw-notes/test/note.md') == 'local voice transcript '+beta['id']
assert docker('exec', 'projectbook-manager-git-fixture', 'git', '--git-dir=/repos/beta.git', 'rev-parse', 'main') == removed['saved_revision']
assert subprocess.run(['docker', 'container', 'inspect', container], capture_output=True).returncode != 0
assert docker('volume', 'inspect', prefix+'-book')
print('PASS retry verifies remote commit, removes container and retains storage', flush=True)
for attempt in range(90):
    status = api('/api/books/'+alpha['id']+'/index')
    if status.get('state') == 'ready':
        break
    time.sleep(2)
assert status.get('state') == 'ready', status
search = tool('search_knowledge', alpha['id'], query='integration test', mode='hybrid', limit=3)
assert search, search
print('PASS automatic indexing and shared MCP semantic search', flush=True)
print('ALL INTEGRATION CHECKS PASSED', flush=True)
