import json
import os
from pathlib import Path
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from http.cookies import SimpleCookie
from urllib.parse import urlsplit, parse_qs

import jwt

from gateway import Gateway
from manager import Manager, Problem


class Auth:
    def __init__(self):
        self.mode = os.environ.get('MANAGER_AUTH', 'cloudflare')
        self.issuer = os.environ.get('ACCESS_ISSUER', '').rstrip('/')
        self.audiences = {kind: os.environ.get(kind.upper() + '_AUDIENCE', '') for kind in ('admin', 'mcp')}
        if self.mode not in ('local', 'cloudflare'):
            raise RuntimeError('MANAGER_AUTH must be local or cloudflare.')
        if self.mode == 'cloudflare':
            if not re.fullmatch(r'https://[a-z0-9-]+\.cloudflareaccess\.com', self.issuer) or not all(self.audiences.values()):
                raise RuntimeError('Cloudflare mode requires ACCESS_ISSUER, ADMIN_AUDIENCE and MCP_AUDIENCE.')
            if self.audiences['admin'] == self.audiences['mcp']:
                raise RuntimeError('Admin and MCP must use separate Access applications/audiences.')
            self.keys = jwt.PyJWKClient(self.issuer + '/cdn-cgi/access/certs', cache_jwk_set=True, lifespan=300, timeout=5)

    def principal(self, headers, kind):
        if self.mode == 'local':
            return 'local-owner'
        assertion = headers.get('Cf-Access-Jwt-Assertion', '')
        if not 1 <= len(assertion) <= 16384:
            raise Problem('Cloudflare authentication required.', 401)
        try:
            key = self.keys.get_signing_key_from_jwt(assertion)
            claims = jwt.decode(assertion, key.key, algorithms=['RS256'], issuer=self.issuer,
                                audience=self.audiences[kind], options={'require': ['iss', 'aud', 'exp', 'iat', 'sub', 'email']})
            if not isinstance(claims['email'], str) or not claims['email'].strip() or not claims['sub']:
                raise ValueError()
            return claims['email'].lower()
        except Exception:
            raise Problem('Invalid or expired Cloudflare assertion.', 401)


def handler(manager, gateway, auth, kind):
    public_url = os.environ.get('ADMIN_PUBLIC_URL' if kind == 'admin' else 'MCP_PUBLIC_URL',
                                'http://127.0.0.1:8070' if kind == 'admin' else 'http://127.0.0.1:8071/mcp')
    parsed = urlsplit(public_url)
    origin = parsed.scheme + '://' + parsed.netloc
    allowed_hosts = {parsed.netloc, '127.0.0.1:8070' if kind == 'admin' else '127.0.0.1:8071'}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def send(self, code, data=None, content_type='application/json', headers=None):
            raw = data if isinstance(data, bytes) else (json.dumps(data, ensure_ascii=False).encode() if data is not None else b'')
            self.send_response(code)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(raw)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.send_header('Referrer-Policy', 'no-referrer')
            self.send_header('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'")
            for key, value in (headers or {}).items():
                self.send_header(key, value)
            self.end_headers()
            self.wfile.write(raw)

        def access(self):
            if self.headers.get('Host') not in allowed_hosts:
                raise Problem('Unexpected Host.', 421)
            if self.headers.get('Origin') and self.headers['Origin'] != origin:
                raise Problem('Unexpected request origin.', 403)
            return auth.principal(self.headers, kind)

        def body(self):
            if self.headers.get_content_type() != 'application/json':
                raise Problem('JSON content type required.', 415)
            size = int(self.headers.get('Content-Length', '0'))
            if not 0 < size <= 4 * 1024 * 1024:
                raise Problem('Empty or oversized request.', 413)
            return json.loads(self.rfile.read(size))

        def do_GET(self):
            try:
                if self.path == '/health':
                    self.send(200, {'alive': True})
                    return
                principal = self.access()
                if kind == 'mcp':
                    self.send(405, {'error': 'Use POST /mcp. This server is stateless.'}, headers={'Allow': 'POST'})
                    return
                if urlsplit(self.path).path == '/auth/github/callback':
                    query = parse_qs(urlsplit(self.path).query)
                    cookie = SimpleCookie(self.headers.get('Cookie', ''))
                    browser = cookie.get('pb_github_flow')
                    try:
                        manager.github.finish(principal, query.get('state', [''])[0],
                                              browser.value if browser else '', query.get('code', [''])[0])
                        location = '/?github=connected'
                    except Problem:
                        location = '/?github=failed'
                    self.send(303, headers={'Location': location, 'Set-Cookie': 'pb_github_flow=; Path=/auth/github/callback; HttpOnly; SameSite=Lax; Max-Age=0'})
                    return
                if self.path == '/api/github':
                    self.send(200, manager.github.status(principal))
                    return
                if self.path == '/api/books':
                    books = manager.registry.books()
                    self.send(200, {'books': [manager.public(b) for b in books], 'auth_mode': auth.mode,
                                    'mcp_url': os.environ.get('MCP_PUBLIC_URL', 'http://127.0.0.1:8071/mcp'),
                                    'cloudflare': manager.cloudflare.status()})
                elif self.path == '/api/people':
                    self.send(200, {'people': manager.people(), 'limit': 50})
                elif re.fullmatch(r'/api/books/[a-f0-9]{12}/index', self.path):
                    self.send(200, manager.index_status(manager.registry.get(self.path.split('/')[3])))
                elif urlsplit(self.path).path in ('/', '/app.js', '/style.css'):
                    path = urlsplit(self.path).path
                    filename = {'/': 'index.html', '/app.js': 'app.js', '/style.css': 'style.css'}[path]
                    mime = {'/': 'text/html; charset=utf-8', '/app.js': 'text/javascript', '/style.css': 'text/css'}[path]
                    self.send(200, (Path(__file__).parent / 'static' / filename).read_bytes(), mime)
                else:
                    self.send(404, {'error': 'Not found.'})
            except Problem as error:
                self.send(error.status, {'error': str(error)})
            except Exception:
                self.send(500, {'error': 'Service unavailable.'})

        def do_POST(self):
            try:
                principal = self.access()
                if kind == 'mcp':
                    if self.path != '/mcp':
                        raise Problem('Not found.', 404)
                    result = gateway.handle(self.body(), principal)
                    self.send(200 if result is not None else 202, result)
                    return
                # Browser forms and cross-site fetch cannot supply this without a preflight.
                if self.headers.get('X-ProjectBook-Request') != '1':
                    raise Problem('Missing request protection header.', 403)
                data = self.body()
                if not isinstance(data, dict):
                    raise Problem('Expected an object.')
                if self.path == '/api/github/connect':
                    url, cookie = manager.github.begin(principal)
                    self.send(200, {'url': url}, headers={'Set-Cookie': 'pb_github_flow=' + cookie +
                        '; Path=/auth/github/callback; HttpOnly; SameSite=Lax; Max-Age=600' + ('; Secure' if parsed.scheme == 'https' else '')})
                    return
                if self.path == '/api/github/check':
                    from manager import validate_book
                    repo = validate_book({'name': 'Check', 'url': 'https://check.invalid', 'repo': data.get('repo')})['repo']
                    self.send(200, manager.github.inspect(principal, repo))
                    return
                if self.path == '/api/books':
                    self.send(202, manager.create(data, principal))
                    return
                if self.path == '/api/cloudflare/check':
                    with manager.cloudflare.guard:
                        self.send(200, manager.cloudflare.check(data.get('subdomain')))
                    return
                if self.path == '/api/people':
                    self.send(201, manager.add_person(data))
                    return
                person_match = re.fullmatch(r'/api/people/([a-f0-9]{12})/remove', self.path)
                if person_match:
                    manager.remove_person(person_match[1])
                    self.send(200, {'removed': True})
                    return
                users_match = re.fullmatch(r'/api/books/([a-f0-9]{12})/users', self.path)
                if users_match:
                    self.send(202, manager.change_users(users_match[1], data.get('users'), data.get('expected_users')))
                    return
                match = re.fullmatch(r'/api/books/([a-f0-9]{12})/(remove|retry)', self.path)
                if not match:
                    raise Problem('Not found.', 404)
                b = manager.registry.get(match[1])
                if match[2] == 'remove':
                    if data.get('confirm') != b['name']:
                        raise Problem('Type the book name to confirm removal.')
                    action = 'remove'
                else:
                    if b['state'] != 'error':
                        raise Problem('Retry is available only after an error.', 409)
                    action = b.get('failed_action', 'install')
                manager.start(b['id'], action)
                self.send(202, manager.public(manager.registry.get(b['id'])))
            except Problem as error:
                self.send(error.status, {'error': str(error)})
            except (ValueError, TypeError):
                self.send(400, {'error': 'Invalid JSON request.'})
            except Exception:
                self.send(500, {'error': 'Service unavailable; data retained.'})

    return Handler


if __name__ == '__main__':
    auth = Auth()
    manager = Manager(os.environ.get('MANAGER_DATA', '/data'))
    gateway = Gateway(manager)
    admin = ThreadingHTTPServer(('0.0.0.0', 8070), handler(manager, gateway, auth, 'admin'))
    mcp = ThreadingHTTPServer(('0.0.0.0', 8071), handler(manager, gateway, auth, 'mcp'))
    threading.Thread(target=mcp.serve_forever, daemon=True).start()
    print('Project Book Manager: admin :8070, MCP :8071; auth=' + auth.mode, flush=True)
    admin.serve_forever()
