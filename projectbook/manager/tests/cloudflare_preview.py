"""Local Docker preview with a simulated Cloudflare API. Never use in production."""
import os
from pathlib import Path
import threading
from http.server import ThreadingHTTPServer

from gateway import Gateway
from manager import Manager
from server import Auth, handler
from test_cloudflare import FakeAPI

os.environ.update(CF_ACCOUNT_ID='fixture-account', CF_ZONE_ID='fixture-zone', CF_TUNNEL_ID='fixture-tunnel',
                  CF_MCP_APP_ID='mcp', CF_BASE_DOMAIN='dmandr.net', ACCESS_ISSUER='https://fixture.cloudflareaccess.com',
                  CF_API_TOKEN_FILE='/tmp/cloudflare-fixture-token', MANAGER_AUTH='local')
Path('/tmp/cloudflare-fixture-token').write_text('fixture-only')
manager = Manager('/data')
manager.cloudflare.session = FakeAPI()
# Fixture's shared MCP destination matches this local preview's configured MCP URL.
manager.cloudflare.session.data['apps']['mcp'].update(domain='127.0.0.1:8073/mcp',
    destinations=[{'type': 'public', 'uri': '127.0.0.1:8073/mcp'}])
# Reconstruct successful fixture resources on restart. No real Cloudflare calls.
fake = manager.cloudflare.session
for book in manager.registry.books():
    cf = book.get('cloudflare', {})
    if not cf.get('policy_id') or not cf.get('app_id'):
        continue
    fake.data['policies'][cf['policy_id']] = dict(manager.cloudflare.policy_body(book), id=cf['policy_id'])
    fake.data['apps'][cf['app_id']] = {'id': cf['app_id'], 'name': manager.cloudflare.tag(book),
        'type': 'self_hosted', 'domain': book['url'].removeprefix('https://'),
        'aud': cf['audience'], 'policies': [{'id': cf['policy_id'], 'precedence': 1}]}
    if book['state'] == 'ready' and cf.get('state') == 'active':
        fake.configuration['config']['ingress'].insert(-1, cf['route'])
        fake.data['dns_records'][cf['dns_id']] = {'id': cf['dns_id'], 'name': cf['route']['hostname'],
            'type': 'CNAME', 'content': manager.cloudflare.tunnel + '.cfargotunnel.com',
            'comment': manager.cloudflare.tag(book), 'proxied': True}
        fake.data['apps']['mcp']['policies'].append({'id': cf['policy_id'], 'precedence': len(fake.data['apps']['mcp']['policies']) + 1})
if not manager.people():
    manager.add_person({'name': 'Owner (test)', 'email': 'owner@example.com'})
    manager.add_person({'name': 'Alex (test)', 'email': 'alex@example.com'})
    manager.add_person({'name': 'Maria (test)', 'email': 'maria@example.com'})
auth = Auth()
auth.principal = lambda headers, kind: 'owner@example.com'
gateway = Gateway(manager)
admin = ThreadingHTTPServer(('0.0.0.0', 8070), handler(manager, gateway, auth, 'admin'))
mcp = ThreadingHTTPServer(('0.0.0.0', 8071), handler(manager, gateway, auth, 'mcp'))
threading.Thread(target=mcp.serve_forever, daemon=True).start()
print('LOCAL CLOUDFLARE SIMULATION — no external API requests', flush=True)
admin.serve_forever()
