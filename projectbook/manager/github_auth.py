"""GitHub App user OAuth and repository provisioning. Secrets never enter the registry."""
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import threading
import time
from urllib.parse import urlencode, urlsplit

import requests

from manager import Problem


class GitHub:
    def __init__(self, registry, session=None):
        self.registry = registry
        self.session = session or requests.Session()
        self.guard = threading.RLock()
        self.pending = {}
        self.client_id = os.environ.get('GITHUB_CLIENT_ID', '')
        self.owner = os.environ.get('GITHUB_OWNER', '').lower()
        self.folder = Path(os.environ.get('GITHUB_SECRET_DIR', '/run/github'))
        self.callback = os.environ.get('ADMIN_PUBLIC_URL', '').rstrip('/') + '/auth/github/callback'

    @property
    def enabled(self):
        return bool(self.client_id)

    def require(self):
        parsed = urlsplit(self.callback)
        local = os.environ.get('MANAGER_AUTH') == 'local' and parsed.hostname in ('127.0.0.1', 'localhost')
        if (not self.enabled or not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,38})', self.owner)
                or not (self.folder / 'client-secret').is_file()
                or (parsed.scheme != 'https' and not local)):
            raise Problem('GitHub App setup is incomplete. Configure the client ID, owner and server client secret.', 503)

    def path(self, principal):
        return self.folder / ('user-' + hashlib.sha256(principal.encode()).hexdigest() + '.json')

    def read(self, principal):
        try:
            return json.loads(self.path(principal).read_text())
        except FileNotFoundError:
            raise Problem('Connect your GitHub account before creating this book.', 401)
        except (ValueError, OSError):
            raise Problem('GitHub connection cannot be read. Reconnect GitHub.', 503)

    def write(self, principal, value):
        self.folder.mkdir(mode=0o700, parents=True, exist_ok=True)
        path = self.path(principal)
        temporary = path.with_suffix('.tmp')
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, 'w') as stream:
            os.fchmod(stream.fileno(), 0o600)
            json.dump(value, stream)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)

    def status(self, principal):
        result = {'enabled': self.enabled, 'configured': False, 'connected': False, 'owner': self.owner}
        if not self.enabled:
            return result
        try:
            self.require()
            result['configured'] = True
            value = self.read(principal)
            result.update(login=value['login'], expires_at=value['expires_at'],
                          connected=value['expires_at'] > time.time() or value['refresh_expires_at'] > time.time())
        except (Problem, KeyError):
            pass
        return result

    def begin(self, principal):
        self.require()
        with self.guard:
            now = time.time()
            self.pending = {k: v for k, v in self.pending.items() if v['expires'] > now}
            # One browser flow per administrator; bound both to Access identity and an HttpOnly cookie.
            self.pending = {k: v for k, v in self.pending.items() if v['principal'] != principal}
            state, browser, verifier = (secrets.token_urlsafe(32) for _ in range(3))
            self.pending[state] = {'principal': principal, 'browser': browser, 'verifier': verifier, 'expires': now + 600}
            challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip('=')
            return 'https://github.com/login/oauth/authorize?' + urlencode({
                'client_id': self.client_id, 'redirect_uri': self.callback, 'state': state,
                'code_challenge': challenge, 'code_challenge_method': 'S256', 'scope': 'offline_access',
                'login': self.owner, 'allow_signup': 'false'}), browser

    def exchange(self, fields):
        self.require()
        try:
            response = self.session.post('https://github.com/login/oauth/access_token',
                data=dict(fields, client_id=self.client_id, client_secret=(self.folder / 'client-secret').read_text().strip()),
                headers={'Accept': 'application/json'}, timeout=(5, 30), allow_redirects=False)
            data = response.json()
            if response.status_code != 200 or data.get('error'):
                raise Problem('GitHub authorization failed. Reconnect GitHub.', 401)
            # Refuse long-lived OAuth/PAT credentials, even if an app was configured incorrectly.
            if (not str(data.get('access_token', '')).startswith('ghu_')
                    or not str(data.get('refresh_token', '')).startswith('ghr_')
                    or not isinstance(data.get('expires_in'), int) or not 0 < data['expires_in'] <= 28800
                    or not isinstance(data.get('refresh_token_expires_in'), int)
                    or not 0 < data['refresh_token_expires_in'] <= 16000000):
                raise Problem('GitHub must issue an expiring user token. Enable GitHub App token expiration.', 503)
            return {'access_token': data['access_token'], 'refresh_token': data['refresh_token'],
                    'expires_at': time.time() + data['expires_in'],
                    'refresh_expires_at': time.time() + data['refresh_token_expires_in']}
        except (requests.RequestException, ValueError, OSError):
            raise Problem('GitHub authorization unavailable. Reconnect GitHub; no credential was displayed.', 503)

    def request(self, method, path, token, body=None, missing=False):
        try:
            response = self.session.request(method, 'https://api.github.com' + path,
                headers={'Authorization': 'Bearer ' + token, 'Accept': 'application/vnd.github+json',
                         'X-GitHub-Api-Version': '2026-03-10'}, json=body, timeout=(5, 30), allow_redirects=False)
            if missing and response.status_code == 404:
                return None
            if response.status_code == 401:
                raise Problem('GitHub authorization expired or was revoked. Reconnect GitHub.', 401)
            if response.status_code >= 300:
                raise Problem('GitHub refused the operation (HTTP ' + str(response.status_code) +
                              '). Check account, repository permissions and App installation; existing repositories are never overwritten.', 409)
            return response.json()
        except (requests.RequestException, ValueError):
            raise Problem('GitHub API unavailable. Progress retained; retry to recheck the repository.', 503)

    def identity(self, token, expected_id=None):
        user = self.request('GET', '/user', token)
        if (user.get('type') != 'User' or str(user.get('login', '')).lower() != self.owner
                or not isinstance(user.get('id'), int) or (expected_id is not None and user['id'] != expected_id)):
            raise Problem('Sign in with the configured GitHub owner account. The connected identity does not match.', 403)
        return user

    def finish(self, principal, state, browser, code):
        with self.guard:
            flow = self.pending.get(state)
            if (not flow or flow['expires'] <= time.time() or flow['principal'] != principal
                    or not browser or not secrets.compare_digest(flow['browser'], browser)):
                raise Problem('GitHub sign-in expired or belongs to another browser. Start Connect GitHub again.', 403)
            del self.pending[state]
            if not isinstance(code, str) or not 1 <= len(code) <= 512:
                raise Problem('GitHub authorization was cancelled. Start Connect GitHub again.', 400)
            value = self.exchange({'code': code, 'redirect_uri': self.callback, 'code_verifier': flow['verifier']})
            user = self.identity(value['access_token'])
            # Existing books stay bound to an immutable GitHub account ID, not just a renameable login.
            for b in self.registry.books():
                gh = b.get('github', {})
                if gh.get('principal') == principal and gh.get('user_id') != user['id']:
                    raise Problem('This GitHub account differs from the account attached to existing books.', 403)
            self.write(principal, dict(value, login=user['login'], user_id=user['id']))

    def token(self, principal, expected_id=None):
        self.require()
        with self.guard:
            value = self.read(principal)
            if expected_id is not None and value.get('user_id') != expected_id:
                raise Problem('GitHub account changed. Reconnect the original book owner.', 403)
            if value['expires_at'] <= time.time() + 120:
                if value['refresh_expires_at'] <= time.time():
                    raise Problem('GitHub connection expired. Connect GitHub again.', 401)
                rotated = self.exchange({'grant_type': 'refresh_token', 'refresh_token': value['refresh_token']})
                value.update(rotated)
                # Persist rotation before any API call that can fail; the old refresh token is single-use.
                self.write(principal, value)
            return value['access_token'], value['user_id']

    def repository_name(self, repo):
        match = re.fullmatch(r'https://github\.com/([A-Za-z0-9-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?', repo)
        if not match or match[1].lower() != self.owner or match[2] in ('.', '..') or len(match[2]) > 100:
            raise Problem('Use a repository owned by ' + self.owner + ': ' + self.owner + '/book-name.', 400)
        return self.owner + '/' + match[2]

    def inspect(self, principal, repo):
        name = self.repository_name(repo)
        token, ident = self.token(principal)
        user = self.identity(token, ident)
        obj = self.request('GET', '/repos/' + name, token, missing=True)
        self.installation_access(token, ident, obj['id'] if obj else None)
        if obj:
            self.validate_repository(obj, name, ident)
        return {'full_name': name, 'login': user['login'], 'user_id': ident,
                'exists': bool(obj), 'repository_id': obj['id'] if obj else None,
                'private': obj.get('private') if obj else True,
                'message': 'Repository exists; your account has write access.' if obj else
                           'Repository not found or not accessible. Creation will be attempted privately; GitHub will reject an occupied name.'}

    def listing(self, token, path, key):
        for page in range(1, 1001):
            data = self.request('GET', path + '?per_page=100&page=' + str(page), token)
            items = data.get(key)
            if not isinstance(items, list):
                raise Problem('Unexpected GitHub permissions response.', 503)
            yield from items
            if len(items) < 100:
                return
        raise Problem('GitHub permissions pagination limit exceeded.', 503)

    def installation_access(self, token, owner_id, repo_id=None):
        installations = list(self.listing(token, '/user/installations', 'installations'))
        matches = [i for i in installations if i.get('account', {}).get('id') == owner_id and not i.get('suspended_at')]
        if len(matches) != 1:
            raise Problem('Install the Project Book GitHub App on your account before creating books.', 403)
        installation = matches[0]
        permissions = installation.get('permissions', {})
        if permissions.get('contents') != 'write':
            raise Problem('The GitHub App needs Contents read/write permission for clone and push.', 403)
        if repo_id is None:
            if permissions.get('repository_creation') != 'write' and permissions.get('administration') != 'write':
                raise Problem('The GitHub App needs Repository creation permission to create a missing repository.', 403)
        elif installation.get('repository_selection') != 'all':
            repos = self.listing(token, '/user/installations/' + str(installation['id']) + '/repositories', 'repositories')
            if not any(r.get('id') == repo_id for r in repos):
                raise Problem('Select this repository in the GitHub App installation, then retry. Its contents were not changed.', 403)

    @staticmethod
    def validate_repository(obj, name, owner_id, repo_id=None):
        if (str(obj.get('full_name', '')).lower() != name.lower() or obj.get('owner', {}).get('id') != owner_id
                or not obj.get('permissions', {}).get('push') or obj.get('archived') or obj.get('disabled')
                or not isinstance(obj.get('id'), int) or (repo_id is not None and obj['id'] != repo_id)):
            raise Problem('Repository identity or write permission does not match. No Git operation was started.', 403)

    def ensure_repository(self, b):
        gh = b['github']
        with self.guard:
            token, ident = self.token(gh['principal'], gh['user_id'])
            self.identity(token, ident)
            name = self.repository_name(b['repo'])
            obj = self.request('GET', '/repos/' + name, token, missing=True)
            self.installation_access(token, ident, obj['id'] if obj else None)
            if not obj:
                if gh.get('repository_id'):
                    raise Problem('The original repository is no longer accessible. It will not be recreated.', 403)
                marker = 'Project Book ' + self.registry.data['owner'] + ' ' + b['id']
                if not gh.get('creation_marker'):
                    gh = dict(gh, creation_marker=marker)
                    self.registry.update(b['id'], github=gh)
                    b['github'] = gh
                obj = self.request('POST', '/user/repos', token, {'name': name.split('/')[1], 'private': True,
                                   'auto_init': False, 'description': marker, 'has_issues': False,
                                   'has_projects': False, 'has_wiki': False})
                # Re-read actual rights; a creation response need not include `permissions`.
                obj = self.request('GET', '/repos/' + name, token)
                self.installation_access(token, ident, obj['id'])
            self.validate_repository(obj, name, ident, gh.get('repository_id'))
            if gh.get('creation_marker') and not gh.get('repository_id'):
                if obj.get('description') != gh['creation_marker'] or not obj.get('private'):
                    raise Problem('Repository creation outcome is ambiguous. Inspect GitHub before retrying.', 409)
            gh = dict(gh, repository_id=obj['id'], full_name=obj['full_name'], private=obj['private'])
            self.registry.update(b['id'], github=gh)
            b['github'] = gh

    def git_token(self, b):
        gh = b['github']
        token, ident = self.token(gh['principal'], gh['user_id'])
        self.identity(token, ident)
        obj = self.request('GET', '/repos/' + self.repository_name(b['repo']), token)
        self.installation_access(token, ident, obj['id'])
        self.validate_repository(obj, self.repository_name(b['repo']), ident, gh['repository_id'])
        return token
