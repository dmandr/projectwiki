import copy
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

import jwt
from cryptography.hazmat.primitives.asymmetric import rsa

from gateway import Gateway
from manager import Manager, Problem, Registry, validate_book
from server import Auth


class ValidationTests(unittest.TestCase):
    def test_repository_shortcut(self):
        b = validate_book({'name': 'Test', 'url': 'https://book.example.com/', 'repo': 'owner/repo'})
        self.assertEqual(b['repo'], 'https://github.com/owner/repo.git')
        self.assertEqual(b['url'], 'https://book.example.com')

    def test_reject_unsafe_inputs(self):
        base = {'name': 'Test', 'url': 'https://book.example.com', 'repo': 'owner/repo'}
        for field, value in [('repo', '--upload-pack=evil'), ('repo', 'file:///etc'),
                             ('repo', 'https://token@github.com/a/b'), ('repo', 'https://evil.com/a/b'),
                             ('url', 'http://book.example.com'), ('url', 'https://book.example.com/path'),
                             ('url', 'https://evil@book.example.com'), ('name', 'hello\nworld')]:
            with self.subTest(field=field, value=value), self.assertRaises(Problem):
                validate_book(dict(base, **{field: value}))

    def test_registry_persists_with_private_permissions(self):
        with tempfile.TemporaryDirectory() as d:
            r = Registry(d)
            self.assertEqual(r.data, Registry(d).data)
            self.assertEqual(r.path.stat().st_mode & 0o777, 0o600)


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.docker = Mock()
        self.m = Manager(self.temp.name, self.docker)
        self.book = {'id': 'a' * 12, 'name': 'Test', 'url': 'https://book.example.com',
                     'repo': 'https://github.com/a/b.git', 'state': 'ready', 'token': 'secret', 'indexing': False}
        self.m.registry.data['books'][self.book['id']] = self.book.copy()
        self.m.registry.flush()
        self.m.owned = Mock(return_value={'State': {'Running': True}})

    def test_delete_failure_does_not_remove_any_container(self):
        self.m.git = Mock(side_effect=Problem('Push rejected', 409))
        self.m.job(self.book['id'], 'remove')
        operations = [c.args[0] for c in self.docker.run.call_args_list]
        self.assertNotIn('rm', operations)
        b = self.m.registry.get(self.book['id'])
        self.assertEqual(b['state'], 'error')
        self.assertEqual(b['failed_action'], 'remove')

    def test_delete_verifies_git_before_removing_containers_and_retains_volumes(self):
        calls = []
        self.docker.run.side_effect = lambda *a, **k: calls.append(a)
        self.m.git = Mock(side_effect=lambda *a: calls.append(('verified-push',)) or {'revision': 'abc'})
        self.m.remove(self.book)
        first_remove = next(i for i, c in enumerate(calls) if c[0] == 'rm')
        self.assertLess(calls.index(('verified-push',)), first_remove)
        self.assertFalse(any(c[0] == 'volume' for c in calls))
        self.assertEqual(self.m.registry.get(self.book['id'])['state'], 'removed')

    def test_interrupted_operation_is_not_reported_ready(self):
        self.m.registry.update(self.book['id'], state='saving', action='remove')
        m = Manager(self.temp.name, self.docker)
        self.assertEqual(m.registry.get(self.book['id'])['failed_action'], 'remove')
        self.assertEqual(m.registry.get(self.book['id'])['state'], 'error')

    def test_ownership_check_prevents_removing_foreign_container(self):
        m = Manager(self.temp.name, self.docker)
        self.docker.inspect.return_value = {'Config': {'Labels': {'projectbook.manager': 'other'}}}
        with self.assertRaises(Problem):
            m.owned(self.book, 'foreign')

    def test_public_data_never_contains_token(self):
        self.assertNotIn('token', self.m.public(self.book))


class GatewayTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.m = Manager(self.temp.name, Mock())
        self.a, self.b = 'a' * 12, 'b' * 12
        for ident in (self.a, self.b):
            self.m.registry.data['books'][ident] = {'id': ident, 'state': 'ready', 'name': ident, 'url': 'https://example.com'}
        self.g = Gateway(self.m)
        self.acl = Path(self.temp.name) / 'access.json'
        self.env = patch.dict(os.environ, BOOK_ACCESS_FILE=str(self.acl))
        self.env.start()
        self.addCleanup(self.env.stop)
        self.tools = [
            {'name': 'read_document', 'inputSchema': {'type': 'object', 'properties': {'path': {'type': 'string'}}, 'required': ['path']}, 'annotations': {'readOnlyHint': True}},
            {'name': 'save_document', 'inputSchema': {'type': 'object', 'properties': {}}},
        ]
        self.m.rpc = Mock(return_value={'result': {'content': [{'type': 'text', 'text': '{"ok":true}'}]}})
        self.g.tools = lambda b: copy.deepcopy(self.tools)

    def call(self, params):
        return self.g.handle({'jsonrpc': '2.0', 'id': 7, 'method': 'tools/call', 'params': params}, 'reader@example.com')

    def test_explicit_book_routing_and_no_implicit_default(self):
        result = self.call({'name': 'read_document', 'arguments': {'book_id': self.b, 'path': 'Home.md'}})
        self.assertIn('result', result)
        args = self.m.rpc.call_args.args
        self.assertEqual(args[0]['id'], self.b)
        self.assertEqual(args[2]['arguments'], {'path': 'Home.md'})
        self.assertIn('error', self.call({'name': 'read_document', 'arguments': {'path': 'Home.md'}}))

    def test_acl_filters_discovery_and_enforces_write_on_call(self):
        self.acl.write_text(json.dumps({'books': {self.a: {'read': ['reader@example.com'], 'write': []}}}))
        self.assertEqual([b['id'] for b in self.g.books('reader@example.com')], [self.a])
        tools = self.g.dispatch('tools/list', {}, 'reader@example.com')['tools']
        self.assertEqual([t['name'] for t in tools], ['list_books', 'read_document'])
        self.assertIn('book_id', tools[1]['inputSchema']['required'])
        self.assertIn('error', self.call({'name': 'save_document', 'arguments': {'book_id': self.a}}))
        self.assertIn('error', self.call({'name': 'read_document', 'arguments': {'book_id': self.b}}))
        self.m.rpc.assert_not_called()

    def test_corrupt_acl_fails_closed(self):
        self.acl.write_text('{broken')
        self.assertEqual(self.g.books('reader@example.com'), [])

    def test_unavailable_book_rejects_writes(self):
        self.m.registry.update(self.a, state='saving')
        self.assertIn('error', self.call({'name': 'save_document', 'arguments': {'book_id': self.a}}))
        self.m.rpc.assert_not_called()

    def test_resources_are_namespaced_in_links_and_text(self):
        uri = 'projectbook://attachments/rev/path'
        response = self.g.rewrite({'content': [{'type': 'resource_link', 'uri': uri}, {'type': 'text', 'text': json.dumps({'resource_uri': uri})}]}, self.a)
        expected = self.g.resource_uri(self.a, uri)
        self.assertEqual(response['content'][0]['uri'], expected)
        self.assertEqual(json.loads(response['content'][1]['text'])['resource_uri'], expected)
        self.g.dispatch('resources/read', {'uri': expected}, 'reader@example.com')
        self.assertEqual(self.m.rpc.call_args.args[2], {'uri': uri})

    def test_malformed_requests_and_notifications(self):
        self.assertIn('error', self.g.handle([], 'reader'))
        self.assertIsNone(self.g.handle({'jsonrpc': '2.0', 'method': 'notifications/initialized'}, 'reader'))


class AuthTests(unittest.TestCase):
    def setUp(self):
        self.key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        with patch.dict(os.environ, MANAGER_AUTH='cloudflare', ACCESS_ISSUER='https://test.cloudflareaccess.com', ADMIN_AUDIENCE='admin', MCP_AUDIENCE='mcp'):
            self.auth = Auth()
        self.auth.keys = Mock()
        self.auth.keys.get_signing_key_from_jwt.return_value.key = self.key.public_key()
        self.claims = {'iss': self.auth.issuer, 'aud': 'mcp', 'sub': 'user', 'email': 'reader@example.com', 'iat': int(time.time()), 'exp': int(time.time()) + 60}

    def token(self, **changes):
        return {'Cf-Access-Jwt-Assertion': jwt.encode(dict(self.claims, **changes), self.key, algorithm='RS256')}

    def test_valid_assertion(self):
        self.assertEqual(self.auth.principal(self.token(), 'mcp'), 'reader@example.com')

    def test_admin_and_mcp_cannot_share_an_audience(self):
        with patch.dict(os.environ, MANAGER_AUTH='cloudflare', ACCESS_ISSUER='https://test.cloudflareaccess.com', ADMIN_AUDIENCE='same', MCP_AUDIENCE='same'):
            with self.assertRaises(RuntimeError):
                Auth()

    def test_mcp_token_cannot_administer(self):
        with self.assertRaises(Problem):
            self.auth.principal(self.token(), 'admin')

    def test_bad_audience_issuer_expiration_and_missing_auth(self):
        for headers in ({}, self.token(aud='other'), self.token(iss='https://evil.com'), self.token(exp=0), {'Cf-Access-Authenticated-User-Email': 'admin@example.com'}):
            with self.subTest(headers=bool(headers)), self.assertRaises(Problem):
                self.auth.principal(headers, 'mcp')

    def test_forged_signature(self):
        another = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        with self.assertRaises(Problem):
            self.auth.principal({'Cf-Access-Jwt-Assertion': jwt.encode(self.claims, another, algorithm='RS256')}, 'mcp')


if __name__ == '__main__':
    unittest.main()
