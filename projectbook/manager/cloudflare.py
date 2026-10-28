"""Cloudflare provisioning, restricted to one configured account/zone/tunnel.

Credentials are read from a secret file on each request; never returned to clients.
Remote operations are checkpointed in the book registry and recoverable after timeouts.
"""
import copy
import fnmatch
import os
from pathlib import Path
import re
import threading
from urllib.parse import urlsplit

import requests

from manager import Problem


APP_FIELDS = set('name type domain destinations session_duration allowed_idps auto_redirect_to_identity '
                 'app_launcher_visible allow_authenticate_via_warp '
                 'allow_iframe cors_headers custom_deny_message custom_deny_url '
                 'custom_non_identity_deny_url custom_pages enable_binding_cookie http_only_cookie_attribute '
                 'options_preflight_bypass path_cookie_attribute same_site_cookie_attribute '
                 'service_auth_401_redirect skip_interstitial tags oauth_configuration '
                 'read_service_tokens_from_header logo_url mfa_config scim_config '
                 'eager_redirect_cookie_setting use_clientless_isolation_app_launcher_url policies'.split())


def emails(value):
    if isinstance(value, str):
        value = re.split(r'[\s,;]+', value.strip())
    if not isinstance(value, list) or not 1 <= len(value) <= 100:
        raise Problem('Enter 1–100 email addresses.')
    result = set()
    for email in value:
        if not isinstance(email, str) or len(email) > 254 or not re.fullmatch(r"[A-Za-z0-9.!#$%&'+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,63}", email):
            raise Problem('Use individual email addresses; domains and wildcards are not allowed.')
        result.add(email.lower())
    return sorted(result)


class Cloudflare:
    def __init__(self, registry, session=None):
        self.registry = registry
        self.session = session or requests.Session()
        self.guard = threading.RLock()
        self.account = os.environ.get('CF_ACCOUNT_ID', '')
        self.zone = os.environ.get('CF_ZONE_ID', '')
        self.tunnel = os.environ.get('CF_TUNNEL_ID', '')
        self.mcp_app = os.environ.get('CF_MCP_APP_ID', '')
        self.base = os.environ.get('CF_BASE_DOMAIN', 'dmandr.net').lower()
        self.secret = Path(os.environ.get('CF_API_TOKEN_FILE', '/run/cloudflare/api-token'))
        self.team = urlsplit(os.environ.get('ACCESS_ISSUER', '')).hostname or ''
        self.team = self.team.removesuffix('.cloudflareaccess.com')
        self.root = '/accounts/' + self.account
        self.apps = self.root + '/access/apps'
        self.policies = self.root + '/access/policies'
        self.dns = '/zones/' + self.zone + '/dns_records'
        self.config = self.root + '/cfd_tunnel/' + self.tunnel + '/configurations'

    @property
    def enabled(self):
        return bool(self.account)

    def require(self):
        if (not all((self.account, self.zone, self.tunnel, self.mcp_app, self.team))
                or not re.fullmatch(r'[a-z0-9.-]+', self.base) or not self.secret.is_file()):
            raise Problem('Cloudflare setup is incomplete. Install the server API token and account/zone/tunnel settings.', 503)

    def status(self):
        try:
            self.require()
            return {'enabled': True, 'configured': True, 'base_domain': self.base}
        except Problem:
            return {'enabled': self.enabled, 'configured': False, 'base_domain': self.base}

    def request(self, method, path, body=None, params=None, missing=False):
        self.require()
        try:
            token = self.secret.read_text().strip()
            if not token:
                raise Problem('Cloudflare API token file is empty.', 503)
            response = self.session.request(method, 'https://api.cloudflare.com/client/v4' + path,
                                            headers={'Authorization': 'Bearer ' + token}, json=body, params=params,
                                            timeout=(5, 30), allow_redirects=False)
            if missing and response.status_code == 404:
                return None
            data = response.json()
            if response.status_code >= 300 or not data.get('success'):
                raise Problem('Cloudflare API refused ' + method + ' (HTTP ' + str(response.status_code) + '). Check token permissions and retry.', 503)
            return data
        except (requests.RequestException, ValueError, OSError):
            raise Problem('Cloudflare API unavailable. Progress retained; retry after checking the connection.', 503)

    def api(self, method, path, body=None, missing=False):
        data = self.request(method, path, body, missing=missing)
        return data.get('result') if data else None

    def listing(self, path, **params):
        result = []
        for page in range(1, 1001):
            data = self.request('GET', path, params=dict(params, page=page, per_page=50))
            batch = data.get('result')
            if not isinstance(batch, list):
                raise Problem('Unexpected Cloudflare list response.', 503)
            result.extend(batch)
            info = data.get('result_info', {})
            if page >= info.get('total_pages', page if len(batch) < 50 else page + 1):
                return result
        raise Problem('Cloudflare pagination limit exceeded; cannot verify availability.', 503)

    def hostname(self, subdomain):
        if not isinstance(subdomain, str) or not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', subdomain):
            raise Problem('Use one subdomain label: lowercase letters, digits and hyphens (1–63 characters).')
        host = subdomain + '.' + self.base
        protected = {urlsplit(os.environ.get(key, '')).hostname for key in ('ADMIN_PUBLIC_URL', 'MCP_PUBLIC_URL')}
        if host in protected:
            raise Problem('This address belongs to Project Book Manager.', 409)
        return host

    @staticmethod
    def destinations(app):
        values = [app.get('domain', ''), *app.get('self_hosted_domains', [])]
        values += [d.get('uri', '') for d in app.get('destinations', []) if d.get('type') == 'public']
        return {v.removeprefix('https://').removeprefix('http://').split('/')[0].lower() for v in values if isinstance(v, str) and v}

    def tag(self, b):
        return 'Project Book ' + self.registry.data['owner'] + ' ' + b['id']

    def save(self, b, **fields):
        state = dict(self.registry.get(b['id']).get('cloudflare', {}), **fields)
        self.registry.update(b['id'], cloudflare=state)
        b['cloudflare'] = state
        return state

    def check(self, subdomain, book=None):
        self.require()
        host = self.hostname(subdomain)
        cf = (book or {}).get('cloudflare', {})
        for b in self.registry.books():
            if b['id'] != (book or {}).get('id') and b['state'] != 'removed' and urlsplit(b['url']).hostname == host:
                raise Problem('Address already reserved by another book.', 409)
        records = self.listing(self.dns, name=host) + self.listing(self.dns, name='*.' + self.base)
        for record in records:
            if not (record.get('id') == cf.get('dns_id') and record.get('comment') == self.tag(book)
                    and record.get('name') == host and record.get('content') == self.tunnel + '.cfargotunnel.com'):
                raise Problem('Address is occupied by an existing DNS record (including wildcard records).', 409)
        for app in self.listing(self.apps):
            if any(fnmatch.fnmatchcase(host, pattern) for pattern in self.destinations(app)):
                if app.get('id') != cf.get('app_id') or app.get('name') != self.tag(book):
                    raise Problem('Address is already covered by a Cloudflare Access application.', 409)
        config = self.api('GET', self.config)
        expected = cf.get('route')
        for route in config['config'].get('ingress', []):
            pattern = route.get('hostname')
            if pattern and fnmatch.fnmatchcase(host, pattern) and route != expected:
                raise Problem('Address is occupied by an existing tunnel route.', 409)
        return {'available': True, 'hostname': host, 'url': 'https://' + host}

    def recover(self, b):
        """Resolve a POST whose outcome was lost before its ID was checkpointed."""
        cf = b.get('cloudflare', {})
        for key, path in (('policy_id', self.policies), ('app_id', self.apps)):
            if cf.get(key):
                continue
            matches = [item for item in self.listing(path) if item.get('name') == self.tag(b)]
            if len(matches) > 1:
                raise Problem('Duplicate Cloudflare resources; manual inspection required.', 409)
            if matches:
                cf = self.save(b, **{key: matches[0]['id']})
        if not cf.get('dns_id'):
            host = urlsplit(b['url']).hostname
            matches = [d for d in self.listing(self.dns, name=host) if d.get('comment') == self.tag(b)]
            if len(matches) == 1:
                self.save(b, dns_id=matches[0]['id'])

    def owned(self, b, key, path):
        ident = b.get('cloudflare', {}).get(key)
        obj = self.api('GET', path + '/' + ident, missing=True) if ident else None
        if not obj or obj.get('name') != self.tag(b):
            raise Problem('Cloudflare resource missing or ownership changed; refusing to overwrite.', 409)
        return obj

    def policy_body(self, b):
        return {'name': self.tag(b), 'decision': 'allow',
                'include': [{'email': {'email': email}} for email in b['users']], 'exclude': [], 'require': []}

    def link_mcp(self, b, remove=False):
        app = self.api('GET', self.apps + '/' + self.mcp_app)
        public = urlsplit(os.environ.get('MCP_PUBLIC_URL', ''))
        expected = public.netloc + public.path
        destinations = [app.get('domain', '')] + [d.get('uri', '') for d in app.get('destinations', [])]
        if app.get('type') != 'self_hosted' or not any(v.rstrip('*') == expected for v in destinations):
            raise Problem('Configured MCP application destination does not match MCP_PUBLIC_URL.', 409)
        links = app.get('policies', [])
        if not all(isinstance(p, dict) and p.get('id') and p.get('reusable', True) for p in links):
            raise Problem('MCP application must use reusable policies.', 409)
        ids = [p['id'] for p in links]
        ident = b['cloudflare']['policy_id']
        if (ident in ids) == (not remove):
            return
        wanted = [i for i in ids if i != ident] + ([] if remove else [ident])
        # Keep all supported settings, including Managed OAuth; never reset to defaults.
        body = {k: copy.deepcopy(v) for k, v in app.items() if k in APP_FIELDS}
        body['policies'] = [{'id': ident, 'precedence': i + 1} for i, ident in enumerate(wanted)]
        if self.api('GET', self.apps + '/' + self.mcp_app) != app:
            raise Problem('MCP application changed concurrently. Retry with its latest settings.', 409)
        self.api('PUT', self.apps + '/' + self.mcp_app, body)
        actual = self.api('GET', self.apps + '/' + self.mcp_app)
        if [p['id'] for p in actual.get('policies', [])] != wanted or actual.get('oauth_configuration') != app.get('oauth_configuration'):
            raise Problem('MCP policy update could not be verified; inspect Cloudflare before retrying.', 503)

    def protect(self, b):
        with self.guard:
            self.recover(b)
            self.check(b['subdomain'], b)
            cf = b.get('cloudflare', {})
            if not cf.get('policy_id'):
                policy = self.api('POST', self.policies, self.policy_body(b))
                self.save(b, policy_id=policy['id'])
            else:
                self.owned(b, 'policy_id', self.policies)
            if not b['cloudflare'].get('app_id'):
                app = self.api('POST', self.apps, {'name': self.tag(b), 'type': 'self_hosted',
                    'domain': urlsplit(b['url']).hostname,
                    'destinations': [{'type': 'public', 'uri': urlsplit(b['url']).hostname}],
                    'session_duration': '24h', 'policies': [{'id': b['cloudflare']['policy_id'], 'precedence': 1}]})
                self.save(b, app_id=app['id'])
            app = self.owned(b, 'app_id', self.apps)
            if self.destinations(app) != {urlsplit(b['url']).hostname} or not app.get('aud'):
                raise Problem('Book application destination/audience changed.', 409)
            if [p.get('id') for p in app.get('policies', [])] != [b['cloudflare']['policy_id']]:
                raise Problem('Book application policies changed outside Manager.', 409)
            self.save(b, audience=app['aud'], state='protected')

    def publish(self, b):
        with self.guard:
            self.recover(b)
            self.check(b['subdomain'], b)
            self.link_mcp(b)
            route = {'hostname': urlsplit(b['url']).hostname, 'service': 'http://localhost:' + str(b['port']),
                     'originRequest': {'access': {'required': True, 'teamName': self.team, 'audTag': [b['cloudflare']['audience']]}}}
            self.save(b, route=route)  # Allows recovery if PUT succeeds but response is lost.
            current = self.api('GET', self.config)
            config = copy.deepcopy(current['config'])
            ingress = config.get('ingress', [])
            if route not in ingress:
                if not ingress or ingress[-1].get('hostname'):
                    raise Problem('Tunnel requires a final catch-all rule.', 409)
                if any(r.get('hostname') == route['hostname'] for r in ingress):
                    raise Problem('Tunnel route changed during creation.', 409)
                config['ingress'] = ingress[:-1] + [route, ingress[-1]]
                # Detect edits since read; API has no conditional compare-and-swap.
                if self.api('GET', self.config).get('version') != current.get('version'):
                    raise Problem('Tunnel changed concurrently. Retry with its latest configuration.', 409)
                self.api('PUT', self.config, {'config': config})
                if self.api('GET', self.config)['config'] != config:
                    raise Problem('Tunnel configuration verification failed.', 503)
            if not b['cloudflare'].get('dns_id'):
                # Check again immediately before DNS publication; never update existing records.
                if self.listing(self.dns, name=route['hostname']):
                    raise Problem('DNS address became occupied during installation.', 409)
                record = self.api('POST', self.dns, {'type': 'CNAME', 'name': route['hostname'],
                    'content': self.tunnel + '.cfargotunnel.com', 'proxied': True, 'ttl': 1, 'comment': self.tag(b)})
                self.save(b, dns_id=record['id'])
            self.save(b, state='active', applied_users=b['users'])

    def update_users(self, b):
        with self.guard:
            policy = self.owned(b, 'policy_id', self.policies)
            if policy.get('app_count', 2) > 2:
                raise Problem('Book policy is shared with an unexpected application.', 409)
            existing = policy.get('include', [])
            old = [{'email': {'email': email}} for email in b['cloudflare'].get('applied_users', [])]
            desired = self.policy_body(b)
            if (policy.get('decision') != 'allow' or policy.get('exclude') or policy.get('require')
                    or existing not in (old, desired['include'])):
                raise Problem('Policy was edited outside Manager; review it in Cloudflare before retrying.', 409)
            app = self.owned(b, 'app_id', self.apps)
            if self.destinations(app) != {urlsplit(b['url']).hostname} or [p.get('id') for p in app.get('policies', [])] != [policy['id']]:
                raise Problem('Book Access application was changed outside Manager.', 409)
            # Preserve policy settings such as MFA and session length; edit membership only.
            for key in ('session_duration', 'approval_groups', 'approval_required', 'connection_rules',
                        'isolation_required', 'purpose_justification_prompt', 'purpose_justification_required', 'mfa_config'):
                if key in policy:
                    desired[key] = policy[key]
            self.api('PUT', self.policies + '/' + policy['id'], desired)
            # Previously issued browser sessions must be re-evaluated after a removal.
            self.api('POST', self.apps + '/' + b['cloudflare']['app_id'] + '/revoke_tokens')
            self.link_mcp(b)
            self.save(b, state='active', applied_users=b['users'])

    def unpublish(self, b):
        """Remove routing before releasing the port. Retain Access protection as a tombstone."""
        with self.guard:
            cf = b.get('cloudflare', {})
            if not cf:
                return
            if cf.get('dns_id'):
                record = self.api('GET', self.dns + '/' + cf['dns_id'], missing=True)
                if record:
                    if (record.get('comment') != self.tag(b) or record.get('name') != urlsplit(b['url']).hostname
                            or record.get('content') != self.tunnel + '.cfargotunnel.com'):
                        raise Problem('DNS ownership changed; removal stopped.', 409)
                    self.api('DELETE', self.dns + '/' + cf['dns_id'])
            route = cf.get('route')
            if route:
                current = self.api('GET', self.config)
                config = copy.deepcopy(current['config'])
                matches = [r for r in config['ingress'] if r.get('hostname') == route['hostname']]
                if matches and matches != [route]:
                    raise Problem('Tunnel route changed; removal stopped.', 409)
                if matches:
                    config['ingress'].remove(route)
                    if self.api('GET', self.config).get('version') != current.get('version'):
                        raise Problem('Tunnel changed concurrently. Retry removal.', 409)
                    self.api('PUT', self.config, {'config': config})
                    if self.api('GET', self.config)['config'] != config:
                        raise Problem('Tunnel removal could not be verified.', 503)
            if cf.get('policy_id'):
                self.link_mcp(b, remove=True)
            # Retain application/policy so a delayed DNS cache never exposes a reused origin.
            self.save(b, state='retired')
