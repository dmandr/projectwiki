"""Local preview: real Manager/Git, simulated GitHub OAuth/API and Cloudflare API."""
import json
import os
from pathlib import Path
import threading
from http.server import ThreadingHTTPServer
from urllib.parse import parse_qs,urlsplit,urlencode
import requests
from manager import Manager
from gateway import Gateway
from server import Auth,handler
from test_github import GitHubAPI
from test_cloudflare import FakeAPI

os.environ.update(MANAGER_AUTH='local',GITHUB_CLIENT_ID='fixture',GITHUB_OWNER='owner',GITHUB_SECRET_DIR='/data/github-secrets',
                  CF_ACCOUNT_ID='fixture',CF_ZONE_ID='zone',CF_TUNNEL_ID='tunnel',CF_MCP_APP_ID='mcp',CF_BASE_DOMAIN='dmandr.net',
                  ACCESS_ISSUER='https://fixture.cloudflareaccess.com',CF_API_TOKEN_FILE='/tmp/cf-fixture')
Path('/data/github-secrets').mkdir(exist_ok=True);Path('/data/github-secrets/client-secret').write_text('fixture-client-secret')
Path('/tmp/cf-fixture').write_text('fixture-only')
m=Manager('/data');api=GitHubAPI();saved=Path('/data/github-fixture.json')
if saved.exists():api.repos=json.loads(saved.read_text())
original_request=api.request
def request(method,url,json=None,**kwargs):
    result=original_request(method,url,json=json,**kwargs)
    if method=='POST' and url.endswith('/user/repos') and result.status_code==200:
        requests.post('https://github.com/__fixture/create',json={'name':json['name']},timeout=10,verify='/etc/ssl/certs/ca-certificates.crt').raise_for_status()
        saved.write_text(__import__('json').dumps(api.repos))
    return result
api.request=request;m.github.session=api
original_begin=m.github.begin
def begin(principal):
    url,cookie=original_begin(principal);state=parse_qs(urlsplit(url).query)['state'][0]
    return m.github.callback+'?'+urlencode({'state':state,'code':'fixture-code'}),cookie
m.github.begin=begin
m.cloudflare.session=FakeAPI();m.cloudflare.session.data['apps']['mcp'].update(domain='127.0.0.1:8075/mcp',destinations=[{'type':'public','uri':'127.0.0.1:8075/mcp'}])
# Rehydrate the local Cloudflare fixture for installed books.
for b in m.registry.books():
    cf=b.get('cloudflare',{});fake=m.cloudflare.session
    if not cf.get('app_id'):continue
    fake.data['policies'][cf['policy_id']]=dict(m.cloudflare.policy_body(b),id=cf['policy_id'])
    fake.data['apps'][cf['app_id']]={'id':cf['app_id'],'name':m.cloudflare.tag(b),'domain':urlsplit(b['url']).hostname,'aud':cf['audience'],'policies':[{'id':cf['policy_id']}]}
    if cf.get('state')=='active':
        fake.configuration['config']['ingress'].insert(-1,cf['route'])
        fake.data['dns_records'][cf['dns_id']]={'id':cf['dns_id'],'name':cf['route']['hostname'],'content':m.cloudflare.tunnel+'.cfargotunnel.com','comment':m.cloudflare.tag(b)}
        fake.data['apps']['mcp']['policies'].append({'id':cf['policy_id']})
if not m.people():m.add_person({'name':'Owner (local fixture)','email':'owner@example.com'})
auth=Auth();auth.principal=lambda headers,kind:'owner@example.com';g=Gateway(m)
admin=ThreadingHTTPServer(('0.0.0.0',8070),handler(m,g,auth,'admin'));mcp=ThreadingHTTPServer(('0.0.0.0',8071),handler(m,g,auth,'mcp'))
threading.Thread(target=mcp.serve_forever,daemon=True).start();print('LOCAL SIMULATION: GitHub OAuth/API and Cloudflare API are fixtures',flush=True);admin.serve_forever()
