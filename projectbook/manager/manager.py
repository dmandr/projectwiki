"""Container lifecycle and durable installation registry. No user-supplied shell commands."""
import copy
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import threading
import time
from urllib.parse import urlsplit
import uuid

import requests


class Problem(Exception):
    def __init__(self, message, status=400):
        super().__init__(message)
        self.status = status


def validate_book(data):
    name = str(data.get('name', '')).strip()
    if not name or len(name) > 100 or any(ord(c) < 32 for c in name):
        raise Problem('Enter a book name (1–100 characters).')
    url = str(data.get('url', '')).strip().rstrip('/')
    parsed = urlsplit(url)
    if (parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password
            or parsed.path or parsed.query or parsed.fragment or parsed.port not in (None, 443)):
        raise Problem('Web address must be an HTTPS origin, for example https://boat.example.com.')
    if not re.fullmatch(r'[a-zA-Z0-9.-]+', parsed.hostname):
        raise Problem('Use a DNS hostname for the web address.')
    repo = str(data.get('repo', '')).strip()
    if re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repo):
        repo = 'https://github.com/' + repo.removesuffix('.git') + '.git'
    hosts = os.environ.get('GIT_HOSTS', 'github.com').split(',')
    https = urlsplit(repo)
    ssh = re.fullmatch(r'git@([A-Za-z0-9.-]+):([A-Za-z0-9_./-]+)', repo)
    valid_https = (https.scheme == 'https' and https.hostname in hosts and not https.username
                   and not https.password and not https.query and not https.fragment
                   and https.port in (None, 443) and re.fullmatch(r'/[A-Za-z0-9_./-]+', https.path))
    if not (valid_https or (ssh and ssh[1] in hosts)):
        raise Problem('Use owner/repository, HTTPS or git@host:path from an allowed Git host. No embedded credentials.')
    return {'name': name, 'url': url, 'repo': repo, 'indexing': data.get('indexing', True) is True}


class Registry:
    def __init__(self, folder):
        self.folder = Path(folder)
        self.folder.mkdir(parents=True, exist_ok=True)
        self.path = self.folder / 'registry.json'
        self.lock = threading.RLock()
        if self.path.exists():
            self.data = json.loads(self.path.read_text())
        else:
            self.data = {'owner': uuid.uuid4().hex, 'books': {}}
            self.flush()

    def flush(self):
        temporary = self.path.with_suffix('.tmp')
        with temporary.open('w') as stream:
            os.chmod(temporary, 0o600)
            json.dump(self.data, stream, ensure_ascii=False, indent=2)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, self.path)

    def books(self):
        with self.lock:
            return copy.deepcopy(list(self.data['books'].values()))

    def get(self, book_id):
        with self.lock:
            if book_id not in self.data['books']:
                raise Problem('Book not found.', 404)
            return copy.deepcopy(self.data['books'][book_id])

    def update(self, book_id, **fields):
        with self.lock:
            self.data['books'][book_id].update(fields, updated_at=time.time())
            self.flush()
        return self.get(book_id)


class Docker:
    def run(self, *args, timeout=120, stdin=None, check=True):
        try:
            p = subprocess.run(['docker', *args], input=stdin, capture_output=True,
                               text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            raise Problem('Docker operation timed out. Resources retained; retry after inspection.', 503)
        if check and p.returncode:
            # Never echo command lines, environment secrets or arbitrary container output.
            raise Problem('Docker ' + args[0] + ' failed. Check image availability, ports and daemon access.', 503)
        return p.stdout.strip() if check else p

    def inspect(self, name, kind='container'):
        p = self.run(kind, 'inspect', name, check=False)
        if p.returncode:
            return None
        return json.loads(p.stdout)[0]


class Manager:
    def __init__(self, folder='/data', docker=None):
        self.registry = Registry(folder)
        self.docker = docker or Docker()
        self.active = set()
        self.guard = threading.RLock()
        self.book_locks = {}
        self.network = os.environ.get('BOOK_NETWORK', 'projectbook-manager-books')
        from cloudflare import Cloudflare
        self.cloudflare = Cloudflare(self.registry)
        from github_auth import GitHub
        self.github = GitHub(self.registry)
        # Interrupted work is recoverable and never silently treated as successful.
        for b in self.registry.books():
            if b['state'] not in ('ready', 'removed', 'error'):
                self.registry.update(b['id'], state='error', error='Manager restarted during operation. Retry to continue.',
                                     failed_action=b.get('action', 'install'))

    def lock(self, book_id):
        with self.guard:
            return self.book_locks.setdefault(book_id, threading.RLock())

    def labels(self, book_id):
        return ['--label', 'projectbook.manager=' + self.registry.data['owner'],
                '--label', 'projectbook.book=' + book_id]

    def name(self, b, role):
        return 'pb-' + self.registry.data['owner'][:8] + '-' + b['id'] + '-' + role

    def owned(self, b, name, kind='container'):
        obj = self.docker.inspect(name, kind)
        if obj:
            labels = obj.get('Labels', {}) if kind != 'container' else obj['Config'].get('Labels', {})
            if labels.get('projectbook.manager') != self.registry.data['owner'] or labels.get('projectbook.book') != b['id']:
                raise Problem('Resource ownership mismatch; operation refused.', 409)
        return obj

    def volume(self, b, role):
        name = self.name(b, role)
        if not self.owned(b, name, 'volume'):
            self.docker.run('volume', 'create', *self.labels(b['id']), name)
        return name

    def create(self, data, principal=None):
        if self.cloudflare.enabled:
            with self.cloudflare.guard:
                checked = self.cloudflare.check(data.get('subdomain'))
                data = dict(data, url=checked['url'])
        fields = validate_book(data)
        if self.github.enabled:
            if not principal:
                raise Problem('GitHub requires an authenticated administrator.', 401)
            checked = self.github.inspect(principal, fields['repo'])
            fields['repo'] = 'https://github.com/' + checked['full_name'] + '.git'
            fields['github'] = {k: checked[k] for k in ('user_id', 'login', 'repository_id')}
            fields['github']['principal'] = principal
        with self.registry.lock:
            if self.cloudflare.enabled:
                fields.update(subdomain=data['subdomain'], users=self.selected_people(data.get('users')), cloudflare={})
            for b in self.registry.books():
                if b['state'] != 'removed' and (b['url'] == fields['url'] or b['repo'] == fields['repo']):
                    raise Problem('This URL or Git repository already has an active installation.', 409)
            book_id = uuid.uuid4().hex[:12]
            b = dict(fields, id=book_id, state='queued', action='install', port=None,
                     token=secrets.token_urlsafe(32), created_at=time.time(), updated_at=time.time(), error='')
            self.registry.data['books'][book_id] = b
            self.registry.flush()
        self.start(book_id, 'install')
        return self.public(self.registry.get(book_id))

    def public(self, b):
        return {k: v for k, v in b.items() if k != 'token'}

    def people(self):
        with self.registry.lock:
            return copy.deepcopy(list(self.registry.data.get('people', {}).values()))

    def add_person(self, data):
        from cloudflare import emails
        email = emails([data.get('email')])[0]
        name = str(data.get('name', '')).strip()
        if not name or len(name) > 100 or any(ord(c) < 32 for c in name):
            raise Problem('Enter a display name (1–100 characters).')
        with self.registry.lock:
            people = self.registry.data.setdefault('people', {})
            if any(p['email'] == email for p in people.values()):
                raise Problem('This email is already in the people list.', 409)
            if len(people) >= 50:
                raise Problem('The configured people list is limited to 50 entries.', 409)
            person = {'id': uuid.uuid4().hex[:12], 'name': name, 'email': email}
            people[person['id']] = person
            self.registry.flush()
            return copy.deepcopy(person)

    def remove_person(self, person_id):
        with self.registry.lock:
            people = self.registry.data.get('people', {})
            person = people.get(person_id)
            if not person:
                raise Problem('Person not found.', 404)
            for b in self.registry.books():
                if b['state'] != 'removed' and person['email'] in b.get('users', []):
                    raise Problem('Remove this person from their books before deleting them from the list.', 409)
            del people[person_id]
            self.registry.flush()

    def selected_people(self, value):
        from cloudflare import emails
        selected = emails(value)
        known = {person['email'] for person in self.people()}
        if not set(selected) <= known:
            raise Problem('Select people from the saved list. Add new people there first.')
        return selected

    def start(self, book_id, action):
        with self.guard:
            b = self.registry.get(book_id)
            if book_id in self.active:
                raise Problem('An operation is already running for this book.', 409)
            if action == 'remove' and b['state'] == 'removed':
                return
            if action == 'install' and b['state'] == 'removed':
                raise Problem('This installation has been removed. Create a new one to clone Git again.', 409)
            self.active.add(book_id)
            self.registry.update(book_id, state='queued', action=action, error='')
            threading.Thread(target=self.job, args=(book_id, action), daemon=True).start()

    def job(self, book_id, action):
        try:
            with self.lock(book_id):
                getattr(self, action)(self.registry.get(book_id))
        except Exception as error:
            message = str(error) if isinstance(error, Problem) else 'Operation failed: ' + type(error).__name__
            self.registry.update(book_id, state='error', failed_action=action, error=message)
        finally:
            with self.guard:
                self.active.discard(book_id)

    def git(self, b, action):
        token = self.github.git_token(b) if b.get('github') else None
        helper = self.name(b, 'git')
        old = self.owned(b, helper)
        if old and old['State']['Running']:
            raise Problem('Git helper is still running. Wait for it to finish, then retry.', 409)
        if old:
            self.docker.run('rm', helper)
        command = ['create', '--name', helper, *self.labels(b['id']), '--network', self.network,
                   '--mount', 'type=volume,src=' + self.name(b, 'book') + ',dst=/book',
                   *(['-i', '--tmpfs', '/run/git:rw,noexec,nosuid,size=1m,mode=0700', '-e', 'GIT_OAUTH_STDIN=1'] if token else
                     ['--mount', 'type=volume,src=' + os.environ.get('GIT_CREDENTIAL_VOLUME', 'projectbook-manager-git') + ',dst=/run/git,readonly']),
                   '-e', 'GIT_HOSTS=' + os.environ.get('GIT_HOSTS', 'github.com'),
                   '-e', 'GIT_INITIAL_PUSH=' + ('1' if action == 'clone' and b.get('github', {}).get('creation_marker') else '0'),
                   '-e', 'BOOK_TITLE=' + b['name'], '--entrypoint', 'python',
                   os.environ.get('MANAGER_IMAGE', 'projectbook-manager:local'), '/app/git_worker.py', action]
        if action == 'clone':
            command.append(b['repo'])
        self.docker.run(*command)
        if token:
            # Docker stdin is not part of container Config/Env, arguments or logs.
            self.docker.run('start', '-ai', helper, stdin=json.dumps({'token': token, 'repo': b['repo']}), timeout=900, check=False)
        else:
            self.docker.run('start', helper)
            self.docker.run('wait', helper, timeout=900)
        obj = self.owned(b, helper)
        output = self.docker.run('logs', helper)
        try:
            result = json.loads(output.splitlines()[-1])
        except (ValueError, IndexError):
            raise Problem('Git helper failed; data retained.', 503)
        if obj['State']['ExitCode'] != 0:
            raise Problem(result.get('error', 'Git helper failed; data retained.'), 409)
        self.docker.run('rm', helper)
        return result

    def ensure_container(self, b, role, image, mounts, env, port=None, extra=None, attempts=10):
        name = self.name(b, role)
        obj = self.owned(b, name)
        created = obj is None
        if not obj:
            args = ['create', '--name', name, *self.labels(b['id']), '--network', self.network,
                    '--restart', 'unless-stopped', '--init', '--log-opt', 'max-size=10m', '--log-opt', 'max-file=2']
            if port is not None:
                # Explicit port is persisted in Docker HostConfig and survives restarts.
                chosen_port = port or (18000 + secrets.randbelow(20000))
                args += ['-p', '127.0.0.1:' + str(chosen_port) + ':4567']
            for source, target, readonly in mounts:
                args += ['--mount', 'type=volume,src=' + source + ',dst=' + target + (',readonly' if readonly else '')]
            for key, value in env.items():
                args += ['-e', key + '=' + str(value)]
            args += extra or []
            args.append(image)
            self.docker.run(*args)
        try:
            self.docker.run('start', name)
        except Problem:
            failed = self.owned(b, name)
            error = failed.get('State', {}).get('Error', '').lower() if failed else ''
            if created and port == 0 and attempts > 1 and ('port is already allocated' in error or 'address already in use' in error):
                self.docker.run('rm', name)
                return self.ensure_container(b, role, image, mounts, env, port, extra, attempts - 1)
            raise
        return self.owned(b, name)

    def install(self, b):
        if b.get('github'):
            self.registry.update(b['id'], state='preparing_repository')
            self.github.ensure_repository(b)
        if 'cloudflare' in b:
            self.registry.update(b['id'], state='protecting')
            self.cloudflare.protect(b)
        self.registry.update(b['id'], state='cloning')
        for role in ('book', 'settings'):
            self.volume(b, role)
        # Retry never reclones over an existing repository.
        result = self.git(b, 'clone')
        self.registry.update(b['id'], **result, state='starting')
        env = {'APP_ENV': 'production', 'GOLLUM_REF': result['branch'], 'PROJECTBOOK_PUBLIC_URL': b['url'],
               'PROJECTBOOK_MCP_TOKEN': b['token'], 'PROJECTBOOK_SETTINGS_ADMIN': 'true',
               'PROJECTBOOK_RAW_UPLOADS': '/var/lib/projectbook/raw-uploads'}
        if b['indexing']:
            self.start_index(b, result['branch'])
            env['PROJECTBOOK_RAG_URL'] = 'http://' + self.name(b, 'rag') + ':8090'
        obj = self.ensure_container(b, 'wiki', os.environ.get('BOOK_IMAGE', 'projectwiki:local'),
                                   [(self.name(b, 'book'), '/wiki', False), (self.name(b, 'settings'), '/var/lib/projectbook', False)],
                                   env, port=b.get('port') or 0,
                                   extra=['--memory', os.environ.get('BOOK_MEMORY', '768m')])
        port = int(obj['NetworkSettings']['Ports']['4567/tcp'][0]['HostPort'])
        self.registry.update(b['id'], port=port)
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            try:
                response = self.rpc(b, 'tools/call', {'name': 'get_book_context', 'arguments': {}})
            except (Problem, requests.RequestException):
                response = {}
            if 'result' in response and not response['result'].get('isError'):
                if 'cloudflare' in b:
                    self.registry.update(b['id'], state='publishing')
                    b = self.registry.get(b['id'])
                    self.cloudflare.publish(b)
                self.registry.update(b['id'], state='ready', error='', failed_action='')
                return
            time.sleep(2)
        raise Problem('Book started but MCP readiness timed out. Retry after checking the container.', 503)

    def start_index(self, b, branch):
        for role in ('vectors', 'models', 'rag-state'):
            self.volume(b, role)
        self.ensure_container(b, 'qdrant', os.environ.get('QDRANT_IMAGE', 'qdrant/qdrant:v1.20.0'),
                              [(self.name(b, 'vectors'), '/qdrant/storage', False)], {}, extra=['--memory', '512m'])
        self.ensure_container(b, 'rag', os.environ.get('RAG_IMAGE', 'projectbook-rag:local'),
                              [(self.name(b, 'book'), '/book', True), (self.name(b, 'models'), '/models', False),
                               (self.name(b, 'rag-state'), '/state', False)],
                              {'BOOK_DIR': '/book', 'BOOK_REF': branch, 'QDRANT_URL': 'http://' + self.name(b, 'qdrant') + ':6333',
                               'RAG_ENABLED': 'true', 'RAG_LOW_MEMORY': 'true', 'BATCH_SIZE': '1',
                               'MODEL_THREADS': '1', 'POLL_SECONDS': '60'},
                              extra=['--memory', os.environ.get('RAG_MEMORY', '1536m'), '--cpus', '1'])

    def remove(self, b):
        self.registry.update(b['id'], state='saving')
        # Stop web writes as well as MCP calls before staging the complete book.
        for role in ('wiki', 'rag'):
            if self.owned(b, self.name(b, role)):
                self.docker.run('stop', '--time', '30', self.name(b, role))
        result = self.git(b, 'save')
        self.registry.update(b['id'], saved_revision=result['revision'], state='removing')
        if 'cloudflare' in b:
            self.cloudflare.unpublish(b)
        for role in ('wiki', 'rag', 'qdrant'):
            name = self.name(b, role)
            if self.owned(b, name):
                self.docker.run('stop', '--time', '30', name)
                self.docker.run('rm', name)
        # Volumes deliberately remain recoverable, including settings and ignored files.
        self.registry.update(b['id'], state='removed', error='', removed_at=time.time())

    def change_users(self, book_id, users, expected_users):
        with self.guard, self.registry.lock:
            users = self.selected_people(users)
            b = self.registry.get(book_id)
            if book_id in self.active or b['state'] not in ('ready', 'error') or 'cloudflare' not in b:
                raise Problem('Access can only be edited on an idle Cloudflare-managed book.', 409)
            if b['state'] == 'error' and b.get('failed_action') != 'access':
                raise Problem('Retry the failed operation before changing access.', 409)
            if b.get('users') != expected_users:
                raise Problem('Users changed since this form was opened. Refresh and try again.', 409)
            if not b['cloudflare'].get('app_id') or not b['cloudflare'].get('dns_id'):
                raise Problem('Finish installation before editing access.', 409)
            self.registry.update(book_id, users=users, state='queued', action='access')
            self.start(book_id, 'access')
        return self.public(self.registry.get(book_id))

    def access(self, b):
        self.registry.update(b['id'], state='updating_access')
        self.cloudflare.update_users(b)
        self.registry.update(b['id'], state='ready', error='', failed_action='')

    def rpc(self, b, method, params=None, request_id=1):
        headers = {'Authorization': 'Bearer ' + b['token'], 'Content-Type': 'application/json',
                   'Accept': 'application/json, text/event-stream', 'Host': urlsplit(b['url']).netloc}
        payload = {'jsonrpc': '2.0', 'id': request_id, 'method': method, 'params': params or {}}
        response = requests.post('http://' + self.name(b, 'wiki') + ':4567/mcp', json=payload,
                                 headers=headers, timeout=(4, 90), allow_redirects=False)
        if response.status_code != 200:
            raise Problem('Book MCP is unavailable (HTTP ' + str(response.status_code) + ').', 503)
        if 'text/event-stream' in response.headers.get('Content-Type', ''):
            for block in response.text.replace('\r\n', '\n').split('\n\n'):
                body = '\n'.join(line[5:].lstrip() for line in block.splitlines() if line.startswith('data:'))
                if body:
                    parsed = json.loads(body)
                    if parsed.get('id') == request_id:
                        return parsed
            raise Problem('Book returned no MCP response.', 503)
        return response.json()

    def index_status(self, b):
        if not b['indexing']:
            return {'state': 'disabled'}
        try:
            r = requests.get('http://' + self.name(b, 'rag') + ':8090/status', timeout=2)
            data = r.json()
            return {k: data[k] for k in ('state', 'phase', 'processed_files', 'indexed_revision') if k in data}
        except (requests.RequestException, ValueError):
            return {'state': 'unavailable'}
