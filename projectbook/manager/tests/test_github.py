import copy
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import Mock, patch
from urllib.parse import parse_qs, urlsplit

import requests

from github_auth import GitHub
from manager import Manager, Problem, Registry


class GitHubAPI:
    def __init__(self):
        self.login = 'owner'
        self.user_id = 42
        self.repos = {}
        self.calls = []
        self.exchanges = []
        self.rotate = 0
        self.status = None
        self.lose_create = False
        self.long_lived = False
        self.installation = {'id': 5, 'account': {'id': 42}, 'permissions': {'contents': 'write', 'repository_creation': 'write'}, 'repository_selection': 'all'}
        self.selected = []

    def post(self, url, data, **kwargs):
        self.exchanges.append(copy.deepcopy(data))
        self.rotate += 1
        value = {'access_token': 'ghu_fixture'+str(self.rotate), 'refresh_token': 'ghr_fixture'+str(self.rotate),
                 'expires_in': 28800, 'refresh_token_expires_in': 15897600}
        if self.long_lived:
            del value['expires_in']
        return Mock(status_code=200, json=lambda: value)

    def request(self, method, url, json=None, **kwargs):
        path = urlsplit(url).path
        self.calls.append((method, path, copy.deepcopy(json)))
        status = 200
        if self.status:
            return Mock(status_code=self.status, json=lambda: {'message': 'secret API output must not leak'})
        if path == '/user':
            value = {'login': self.login, 'id': self.user_id, 'type': 'User'}
        elif path == '/user/installations':
            value = {'installations': [self.installation] if self.installation else []}
        elif path == '/user/installations/5/repositories':
            value = {'repositories': [{'id': i} for i in self.selected]}
        elif path == '/user/repos' and method == 'POST':
            name = self.login+'/'+json['name']
            if name in self.repos:
                status, value = 422, {}
            else:
                value = dict(json, full_name=name, owner={'id': self.user_id}, id=100+len(self.repos), permissions={'push': True})
                self.repos[name] = value
                if self.lose_create:
                    self.lose_create = False
                    raise requests.Timeout('credential must not leak')
        elif path.startswith('/repos/'):
            value = self.repos.get(path[7:])
            if value is None:
                status = 404
        else:
            raise AssertionError((method,path))
        return Mock(status_code=status, json=lambda: copy.deepcopy(value))


class GitHubTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.env = patch.dict(os.environ, GITHUB_CLIENT_ID='fixture-client', GITHUB_OWNER='owner',
                              GITHUB_SECRET_DIR=self.temp.name+'/secrets', ADMIN_PUBLIC_URL='https://pb.example.com',
                              CF_ACCOUNT_ID='')
        self.env.start(); self.addCleanup(self.env.stop)
        Path(self.temp.name+'/secrets').mkdir()
        Path(self.temp.name+'/secrets/client-secret').write_text('fixture-client-secret')
        self.r = Registry(self.temp.name+'/state')
        self.fake = GitHubAPI()
        self.gh = GitHub(self.r,self.fake)
        self.principal = 'owner@example.com'

    def connect(self):
        url,cookie=self.gh.begin(self.principal)
        state=parse_qs(urlsplit(url).query)['state'][0]
        self.gh.finish(self.principal,state,cookie,'fixture-code')
        return state,cookie

    def book(self, repo_id=None):
        b={'id':'abcdef123456','state':'queued','repo':'https://github.com/owner/new-book.git',
           'github':{'principal':self.principal,'user_id':42,'login':'owner','repository_id':repo_id}}
        self.r.data['books'][b['id']]=copy.deepcopy(b); self.r.flush()
        return b

    def test_oauth_pkce_bound_to_browser_and_access_principal_one_use(self):
        url,cookie=self.gh.begin(self.principal); q=parse_qs(urlsplit(url).query); state=q['state'][0]
        self.assertEqual(q['code_challenge_method'],['S256']); self.assertEqual(q['scope'],['offline_access'])
        for who,browser in [('other@example.com',cookie),(self.principal,'wrong')]:
            with self.assertRaises(Problem): self.gh.finish(who,state,browser,'code')
        self.assertFalse(self.fake.exchanges)
        self.gh.finish(self.principal,state,cookie,'code')
        self.assertTrue(self.fake.exchanges[0]['code_verifier'])
        with self.assertRaises(Problem): self.gh.finish(self.principal,state,cookie,'code')
        self.assertEqual(self.gh.path(self.principal).stat().st_mode & 0o777,0o600)
        self.assertNotIn('ghu_',json.dumps(self.gh.status(self.principal)))
        self.assertNotIn('ghr_',self.r.path.read_text())

    def test_expired_flow_cancel_wrong_identity_and_long_lived_token(self):
        url,cookie=self.gh.begin(self.principal); state=parse_qs(urlsplit(url).query)['state'][0]
        self.gh.pending[state]['expires']=0
        with self.assertRaises(Problem): self.gh.finish(self.principal,state,cookie,'code')
        for attribute,value in [('login','other'),('long_lived',True)]:
            old=getattr(self.fake,attribute);setattr(self.fake,attribute,value)
            with self.assertRaises(Problem): self.connect()
            setattr(self.fake,attribute,old)
        self.assertFalse(self.gh.path(self.principal).exists())

    def test_rotation_persists_and_keeps_principal_identity(self):
        self.connect(); value=self.gh.read(self.principal);value['expires_at']=0;self.gh.write(self.principal,value)
        token,ident=self.gh.token(self.principal,42)
        self.assertEqual(ident,42);self.assertEqual(token,'ghu_fixture2')
        self.assertEqual(self.gh.read(self.principal)['refresh_token'],'ghr_fixture2')
        self.gh.token(self.principal,42);self.assertEqual(len(self.fake.exchanges),2)
        with self.assertRaises(Problem): self.gh.token(self.principal,43)
        value=self.gh.read(self.principal);value.update(expires_at=0,refresh_expires_at=0);self.gh.write(self.principal,value)
        with self.assertRaises(Problem): self.gh.token(self.principal)

    def test_create_private_and_retry_lost_response_without_duplicates(self):
        self.connect(); b=self.book();self.fake.lose_create=True
        with self.assertRaises(Problem):self.gh.ensure_repository(b)
        self.gh.ensure_repository(self.r.get(b['id']))
        self.assertEqual(len([x for x in self.fake.calls if x[0]=='POST']),1)
        obj=self.fake.repos['owner/new-book'];self.assertTrue(obj['private'])
        self.assertFalse(obj['auto_init']);self.assertEqual(self.r.get(b['id'])['github']['repository_id'],100)
        self.assertEqual(self.gh.git_token(self.r.get(b['id'])),'ghu_fixture1')

    def test_existing_repository_requires_write_access_and_stable_id(self):
        self.connect();b=self.book();self.gh.ensure_repository(b)
        obj=self.fake.repos['owner/new-book'];obj['permissions']['push']=False
        with self.assertRaises(Problem):self.gh.inspect(self.principal,b['repo'])
        with self.assertRaises(Problem):self.gh.git_token(b)
        obj['permissions']['push']=True;obj['id']=999
        with self.assertRaises(Problem):self.gh.git_token(b)
        del self.fake.repos['owner/new-book']
        with self.assertRaises(Problem):self.gh.ensure_repository(b)
        self.assertEqual(len([x for x in self.fake.calls if x[0]=='POST']),1)

    def test_404_is_not_reported_as_definitely_absent(self):
        self.connect()
        info=self.gh.inspect(self.principal,'https://github.com/owner/new-book.git')
        self.assertIn('not accessible',info['message']);self.assertFalse(info['exists'])
        self.assertFalse(any(x[0]=='POST' for x in self.fake.calls))

    def test_ambiguous_create_does_not_adopt_other_repo(self):
        self.connect(); b=self.book();self.fake.lose_create=True
        with self.assertRaises(Problem):self.gh.ensure_repository(b)
        self.fake.repos['owner/new-book']['description']='Someone else created this'
        with self.assertRaises(Problem):self.gh.ensure_repository(self.r.get(b['id']))

    def test_forbidden_paths_owner_redirects_and_secret_redaction(self):
        self.connect()
        for repo in ['https://github.com/other/book.git','git@github.com:owner/a.git','https://evil.com/owner/a.git','https://github.com/owner/..','https://github.com/owner/a?token=x']:
            with self.assertRaises(Problem):self.gh.inspect(self.principal,repo)
        for status in [301,401,403,422,500]:
            self.fake.status=status
            with self.assertRaises(Problem) as e:self.gh.inspect(self.principal,'https://github.com/owner/new-book.git')
            self.assertNotIn('secret API',str(e.exception));self.assertNotIn('ghu_',str(e.exception))

    def test_manager_creation_checks_identity_before_starting_job(self):
        m=Manager(self.temp.name+'/manager',Mock());m.github=self.gh;m.start=Mock()
        data={'name':'Book','url':'https://book.example.com','repo':'owner/new-book','indexing':False}
        with self.assertRaises(Problem):m.create(data,self.principal)
        self.assertFalse(m.registry.books());m.start.assert_not_called()
        self.connect(); book=m.create(data,self.principal)
        self.assertEqual(book['github']['user_id'],42);self.assertNotIn('access_token',json.dumps(book))
        m.start.assert_called_once()

    def test_git_helper_gets_only_short_lived_token_via_stdin(self):
        self.connect(); b=self.book();self.gh.ensure_repository(b);b['name']='Book'
        docker=Mock();docker.run.return_value='{"revision":"abc","branch":"main"}'
        m=Manager(self.temp.name+'/manager',docker);m.github=self.gh
        m.owned=Mock(side_effect=[None,{'State':{'ExitCode':0}}])
        m.git(b,'clone')
        commands=[call.args for call in docker.run.call_args_list]
        self.assertNotIn('ghu_',repr(commands));self.assertNotIn('ghr_',repr(docker.run.call_args_list))
        start=next(c for c in docker.run.call_args_list if c.args[:2]==('start','-ai'))
        self.assertEqual(json.loads(start.kwargs['stdin'])['token'],'ghu_fixture1')
        create=commands[0];self.assertIn('--tmpfs',create)
        self.assertFalse(any('/run/github' in str(x) or 'projectbook-manager-git,' in str(x) for x in create))

    def test_app_scope_checked_in_addition_to_user_rights(self):
        self.connect(); b=self.book();self.gh.ensure_repository(b)
        self.fake.installation['permissions']['contents']='read'
        with self.assertRaises(Problem):self.gh.git_token(b)
        self.fake.installation['permissions']['contents']='write'
        self.fake.installation['repository_selection']='selected'
        with self.assertRaises(Problem):self.gh.git_token(b)
        self.fake.selected=[b['github']['repository_id']]
        self.assertTrue(self.gh.git_token(b))
        self.fake.installation['permissions']['repository_creation']='read'
        with self.assertRaises(Problem):self.gh.inspect(self.principal,'https://github.com/owner/another.git')
        self.fake.installation['suspended_at']='now'
        with self.assertRaises(Problem):self.gh.git_token(b)
