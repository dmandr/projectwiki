"""Run only inside cloudflare_preview.py's disposable local Docker fixture."""
import json
import time
import requests

ADMIN='http://127.0.0.1:8070'
MCP='http://127.0.0.1:8071/mcp'
HEADERS={'X-ProjectBook-Request':'1'}

def api(path, data=None, status=200):
    r=requests.get(ADMIN+path, timeout=15) if data is None else requests.post(ADMIN+path, json=data, headers=HEADERS, timeout=15)
    assert r.status_code==status, (r.status_code,r.text)
    return r.json()

def wait(ident, state='ready'):
    for _ in range(150):
        b=next(b for b in api('/api/books')['books'] if b['id']==ident)
        if b['state']==state:return b
        assert b['state']!='error',b
        time.sleep(1)
    raise AssertionError('timeout')

def rpc(name, arguments=None):
    r=requests.post(MCP,json={'jsonrpc':'2.0','id':1,'method':'tools/call','params':{'name':name,'arguments':arguments or {}}},timeout=60)
    assert r.status_code==200,r.text
    return r.json()

def listed():return json.loads(rpc('list_books')['result']['content'][0]['text'])['books']

def access(b, users):
    api('/api/books/'+b['id']+'/users',{'users':users,'expected_users':b['users']},202)
    return wait(b['id'])

assert api('/api/books')['auth_mode']=='local'
assert api('/api/books')['cloudflare']['base_domain']=='dmandr.net'
api('/api/cloudflare/check',{'subdomain':'boatwiki'},409)
api('/api/cloudflare/check',{'subdomain':'bad.other'},400)
alpha=next(b for b in api('/api/books')['books'] if b['name']=='Cloudflare demo · Alpha')
alpha=wait(alpha['id'])
api('/api/people',{'name':'duplicate','email':'OWNER@example.com'},409)
reader=next(p for p in api('/api/people')['people'] if p['email']=='owner@example.com')
api('/api/people/'+reader['id']+'/remove',{},409)
api('/api/books/'+alpha['id']+'/users',{'users':['unknown@example.com'],'expected_users':alpha['users']},400)
api('/api/books/'+alpha['id']+'/users',{'users':[],'expected_users':alpha['users']},400)
beta=api('/api/books',{'name':'Cloudflare demo · Beta','subdomain':'pb-test-beta','repo':'https://git-fixture/beta.git','indexing':False,'users':['alex@example.com']},202)
beta=wait(beta['id'])
assert [b['book_id'] for b in listed()]==[alpha['id']]
assert 'error' in rpc('read_document',{'book_id':beta['id'],'path':'Home.md'})
assert 'result' in rpc('read_document',{'book_id':alpha['id'],'path':'Home.md'})
print('PASS real books with distinct Cloudflare policies and isolated MCP access',flush=True)
alpha=access(alpha,['alex@example.com'])
assert listed()==[]
assert 'error' in rpc('read_document',{'book_id':alpha['id'],'path':'Home.md'})
alpha=access(alpha,['owner@example.com','maria@example.com'])
assert [b['book_id'] for b in listed()]==[alpha['id']]
print('PASS removing/restoring a selected person changes real MCP access',flush=True)
api('/api/books/'+beta['id']+'/remove',{'confirm':beta['name']},202)
beta=wait(beta['id'],'removed')
assert beta['cloudflare']['state']=='retired'
assert beta['saved_revision']
api('/api/cloudflare/check',{'subdomain':'pb-test-beta'},409) # retired Access guard reserves name
print('PASS save/push then unpublish, preserving old Access protection',flush=True)
print('PASS people directory, duplicate prevention, used-person deletion guard, hostname conflict checks',flush=True)
