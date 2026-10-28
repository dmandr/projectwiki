"""Run only inside the isolated github-preview manager; no real GitHub account."""
import json
import subprocess
import time
from urllib.parse import urlsplit
import requests

base='http://127.0.0.1:8070';s=requests.Session()
s.headers.update({'X-ProjectBook-Request':'1','Origin':'http://127.0.0.1:8074'})
def api(path,data=None,status=200):
    r=s.get(base+path) if data is None else s.post(base+path,json=data)
    assert r.status_code==status,(path,r.status_code,r.text)
    return r.json()
def docker(*args):
    return subprocess.run(['docker',*args],check=True,capture_output=True,text=True).stdout

def wait(ident,target):
    end=time.monotonic()+150
    while time.monotonic()<end:
        b=next(x for x in api('/api/books')['books'] if x['id']==ident)
        if b['state']==target:return b
        if b['state']=='error' and target!='error':raise AssertionError(b['error'])
        time.sleep(1)
    raise AssertionError('Timed out')

flow=api('/api/github/connect',{})
callback=urlsplit(flow['url'])
bad=requests.get(base+callback.path+'?'+callback.query,allow_redirects=False)
assert bad.status_code==303 and bad.headers['Location']=='/?github=failed'
r=s.get(base+callback.path+'?'+callback.query,allow_redirects=False)
assert r.status_code==303 and r.headers['Location']=='/?github=connected'
assert api('/api/github')['connected']
name='oauth-book-'+str(int(time.time()))
check=api('/api/github/check',{'repo':'owner/'+name})
assert not check['exists']
api('/api/github/check',{'repo':'other/no-access'},400)
b=api('/api/books',{'name':'OAuth integration book','repo':'owner/'+name,'subdomain':name,'users':['owner@example.com'],'indexing':False},202)
b=wait(b['id'],'ready')
assert b['github']['private'] and b['github']['repository_id']
assert api('/api/github/check',{'repo':'owner/'+name})['exists']
remote='/repos/owner/'+name+'.git'
initial=docker('exec','projectbook-github-remote','git','--git-dir='+remote,'show',b['branch']+':Home.md')
assert '# OAuth integration book' in initial
# A genuine push rejection must retain the book, routes and container for retry.
containers=docker('ps','--filter','label=projectbook.book='+b['id'],'--format','{{.Names}}').splitlines()
wiki=next(x for x in containers if x.endswith('-wiki'))
docker('exec',wiki,'sh','-c','printf "Saved through OAuth\\n" > /wiki/OAuth-test.md')
docker('exec','projectbook-github-remote','touch','/repos/reject-push')
try:
    api('/api/books/'+b['id']+'/remove',{'confirm':b['name']},202)
    failed=wait(b['id'],'error');assert failed['failed_action']=='remove'
    assert failed['cloudflare']['state']=='active'
finally:
    docker('exec','projectbook-github-remote','rm','-f','/repos/reject-push')
api('/api/books/'+b['id']+'/retry',{},202)
removed=wait(b['id'],'removed');assert removed['saved_revision'] and removed['cloudflare']['state']=='retired'
assert 'Saved through OAuth' in docker('exec','projectbook-github-remote','git','--git-dir='+remote,'show',b['branch']+':OAuth-test.md')
# Secrets were transient input, never container config or application registry.
assert 'ghu_fixture' not in open('/data/registry.json').read()
print('PASS: browser-bound OAuth callback, private creation, authenticated HTTPS clone/initial push, denied owner, failed push retention and successful retry/removal')
