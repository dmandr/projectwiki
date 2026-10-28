import copy
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch
from urllib.parse import urlsplit

import requests

from cloudflare import Cloudflare, emails
from gateway import Gateway
from manager import Manager, Problem, Registry


class FakeAPI:
    """Stateful contract fixture. No calls ever leave this process."""
    def __init__(self):
        self.calls = []
        self.data = {'apps': {'mcp': {'id': 'mcp', 'name': 'Project Book MCP', 'type': 'self_hosted',
                     'domain': 'pb.dmandr.net/mcp*', 'destinations': [{'type': 'public', 'uri': 'pb.dmandr.net/mcp*'}],
                     'policies': [{'id': 'owner', 'precedence': 1}],
                     'oauth_configuration': {'enabled': True, 'dynamic_client_registration': {'enabled': True}},
                     'session_duration': '24h', 'allowed_idps': ['google']}},
                     'policies': {'owner': {'id': 'owner', 'name': 'Owner', 'include': [{'email': {'email': 'owner@example.com'}}]}}, 'dns_records': {}}
        self.configuration = {'version': 1, 'config': {'ingress': [{'hostname': 'boatwiki.dmandr.net', 'service': 'http://localhost:8092'}, {'service': 'http_status:404'}], 'originRequest': {'connectTimeout': 10}}}
        self.fail_after = None
        self.reject = None
        self.paginate = False

    def request(self, method, url, json=None, params=None, **kwargs):
        path = urlsplit(url).path.removeprefix('/client/v4')
        self.calls.append((method, path, copy.deepcopy(json)))
        response = Mock(status_code=200)
        if self.reject == (method, path):
            response.status_code = 403
            response.json.return_value = {'success': False, 'errors': [{'message': 'sensitive-error-token'}]}
            return response
        if path.endswith('/configurations'):
            if method == 'PUT':
                self.configuration = {'version': self.configuration['version'] + 1, 'config': copy.deepcopy(json['config'])}
            result = self.configuration
        elif path.endswith('/revoke_tokens'):
            result = {}
        else:
            pieces = path.split('/')
            collection = next(c for c in self.data if c in pieces)
            ident = pieces[-1] if pieces[-1] != collection else None
            records = self.data[collection]
            if method == 'GET':
                if ident:
                    result = records.get(ident)
                    if not result:
                        response.status_code = 404
                else:
                    result = list(records.values())
                    if params and 'name' in params:
                        result = [r for r in result if r.get('name') == params['name']]
            elif method == 'POST':
                ident = collection + '-' + str(len(records) + 1)
                result = dict(copy.deepcopy(json), id=ident)
                if collection == 'apps':
                    result['aud'] = 'aud-' + ident
                records[ident] = result
            elif method == 'PUT':
                records[ident] = result = dict(copy.deepcopy(json), id=ident)
            elif method == 'DELETE':
                records.pop(ident, None)
                result = {'id': ident}
            else:
                raise AssertionError(method)
        if self.fail_after == (method, path):
            self.fail_after = None
            raise requests.Timeout('secret must never appear')
        info = {'total_pages': 1}
        if self.paginate and isinstance(result, list):
            info['total_pages'] = max(1, len(result))
            page = (params or {}).get('page', 1)
            result = result[page - 1:page]
        response.json.return_value = {'success': response.status_code == 200, 'result': copy.deepcopy(result), 'result_info': info}
        return response


class CloudflareTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        token = Path(self.temp.name) / 'token'
        token.write_text('fixture-secret')
        env = patch.dict(os.environ, CF_ACCOUNT_ID='account', CF_ZONE_ID='zone', CF_TUNNEL_ID='tunnel',
                         CF_MCP_APP_ID='mcp', CF_BASE_DOMAIN='dmandr.net', CF_API_TOKEN_FILE=str(token),
                         ACCESS_ISSUER='https://team.cloudflareaccess.com',
                         MCP_PUBLIC_URL='https://pb.dmandr.net/mcp', ADMIN_PUBLIC_URL='https://pb.dmandr.net',
                         BOOK_ACCESS_FILE=str(Path(self.temp.name) / 'missing-acl'))
        env.start()
        self.addCleanup(env.stop)
        self.manager = Manager(self.temp.name, Mock())
        self.manager.add_person({'name': 'Reader', 'email': 'reader@example.com'})
        self.manager.add_person({'name': 'New', 'email': 'new@example.com'})
        self.cf = self.manager.cloudflare
        self.fake = FakeAPI()
        self.cf.session = self.fake
        self.book = {'id': 'a' * 12, 'name': 'Test', 'subdomain': 'test', 'url': 'https://test.dmandr.net',
                     'repo': 'https://github.com/a/b.git', 'port': 23456, 'users': ['reader@example.com'],
                     'state': 'ready', 'cloudflare': {}}
        self.manager.registry.data['books'][self.book['id']] = copy.deepcopy(self.book)
        self.manager.registry.flush()

    def provision(self):
        self.cf.protect(self.book)
        self.cf.publish(self.book)
        self.book = self.manager.registry.get(self.book['id'])

    def test_only_subdomains_and_explicit_emails(self):
        for value in ('', 'a.b', '*.x', 'UPPER', '-bad', 'a/evil', 'a' * 64, 'pb'):
            with self.subTest(value=value), self.assertRaises(Problem):
                self.cf.hostname(value)
        self.assertEqual(emails('A@example.com, b@example.com\na@example.com'), ['a@example.com', 'b@example.com'])
        for value in ('*@example.com', [], ['x'], {'email': 'a@example.com'}, 'a@example.com\n*'):
            with self.subTest(value=value), self.assertRaises(Problem):
                emails(value)

    def test_occupied_dns_access_wildcard_tunnel_and_no_mutation(self):
        cases = [('dns_records', {'id': 'busy', 'name': 'test.dmandr.net', 'type': 'TXT'}),
                 ('dns_records', {'id': 'busy', 'name': '*.dmandr.net'}),
                 ('apps', {'id': 'busy', 'domain': 'test.dmandr.net/private'}),
                 ('apps', {'id': 'busy', 'destinations': [{'type': 'public', 'uri': '*.dmandr.net'}]})]
        for collection, record in cases:
            self.fake.data[collection]['busy'] = record
            with self.assertRaises(Problem):
                self.cf.check('test', self.book)
            del self.fake.data[collection]['busy']
        self.fake.configuration['config']['ingress'].insert(0, {'hostname': 'test.dmandr.net', 'service': 'http://elsewhere'})
        with self.assertRaises(Problem):
            self.cf.check('test', self.book)
        self.assertTrue(all(c[0] == 'GET' for c in self.fake.calls))

    def test_protect_before_publish_and_preserve_other_routes_and_oauth(self):
        before = copy.deepcopy(self.fake.configuration['config'])
        oauth = copy.deepcopy(self.fake.data['apps']['mcp']['oauth_configuration'])
        self.provision()
        calls = self.fake.calls
        policy_index = next(i for i,c in enumerate(calls) if c[0]=='POST' and c[1]==self.cf.policies)
        app_index = next(i for i,c in enumerate(calls) if c[0]=='POST' and c[1]==self.cf.apps)
        dns_index = next(i for i,c in enumerate(calls) if c[0]=='POST' and c[1]==self.cf.dns)
        self.assertLess(policy_index, app_index)
        self.assertLess(app_index, dns_index)
        config = self.fake.configuration['config']
        self.assertEqual(config['ingress'][0], before['ingress'][0])
        self.assertEqual(config['ingress'][-1], before['ingress'][-1])
        self.assertEqual(config['originRequest'], before['originRequest'])
        self.assertTrue(config['ingress'][1]['originRequest']['access']['required'])
        self.assertEqual(self.fake.data['apps']['mcp']['oauth_configuration'], oauth)
        self.assertEqual(self.fake.data['apps']['mcp']['policies'][0]['id'], 'owner')
        self.assertEqual(self.book['cloudflare']['state'], 'active')

    def test_lost_post_and_put_response_retry_without_duplicate(self):
        for operation in [('POST', self.cf.policies), ('POST', self.cf.apps), ('PUT', self.cf.config), ('POST', self.cf.dns)]:
            self.fake.fail_after = operation
            with self.assertRaises(Problem):
                self.provision()
        self.provision()
        self.assertEqual(len(self.fake.data['apps']), 2)
        self.assertEqual(len(self.fake.data['policies']), 2)
        self.assertEqual(len(self.fake.data['dns_records']), 1)
        self.assertEqual(len(self.fake.configuration['config']['ingress']), 3)

    def test_rejected_api_does_not_echo_remote_secrets_or_publish(self):
        self.fake.reject = ('POST', self.cf.apps)
        with self.assertRaises(Problem) as raised:
            self.provision()
        self.assertNotIn('sensitive', str(raised.exception))
        self.assertEqual(self.fake.data['dns_records'], {})
        self.assertEqual(len(self.fake.configuration['config']['ingress']), 2)

    def test_paginated_conflicts_are_not_missed(self):
        self.fake.paginate = True
        self.fake.data['apps']['last'] = {'id':'last','domain':'test.dmandr.net'}
        with self.assertRaises(Problem):
            self.cf.check('test', self.book)

    def test_per_book_mcp_permissions_and_legacy_fail_closed(self):
        self.provision()
        g = Gateway(self.manager)
        self.assertTrue(g.permission('reader@example.com', self.book['id']))
        self.assertFalse(g.permission('other@example.com', self.book['id']))
        self.manager.registry.data['books']['b'*12] = {'id':'b'*12,'state':'ready','name':'Legacy','url':'https://old.dmandr.net'}
        self.assertFalse(g.permission('reader@example.com', 'b'*12))
        self.manager.registry.update(self.book['id'], users=['new@example.com'])
        self.assertFalse(g.permission('reader@example.com', self.book['id']))

    def test_edit_users_revoke_sessions_and_preserve_mcp_policy(self):
        self.provision()
        self.book['users'] = ['new@example.com']
        self.cf.update_users(self.book)
        policy = self.fake.data['policies'][self.book['cloudflare']['policy_id']]
        self.assertEqual(policy['include'], [{'email': {'email': 'new@example.com'}}])
        self.assertTrue(any(c[1].endswith('/revoke_tokens') for c in self.fake.calls))
        self.assertEqual(self.fake.data['policies']['owner']['name'], 'Owner')

    def test_stale_user_form_conflict(self):
        self.provision()
        self.manager.start = Mock()
        with self.assertRaises(Problem):
            self.manager.change_users(self.book['id'], ['new@example.com'], ['stale@example.com'])
        self.manager.start.assert_not_called()
        self.assertEqual(self.manager.registry.get(self.book['id'])['users'], ['reader@example.com'])

    def test_remove_only_owned_routing_and_retain_access_guard(self):
        self.provision()
        self.cf.unpublish(self.book)
        self.assertEqual(self.fake.data['dns_records'], {})
        self.assertEqual(len(self.fake.configuration['config']['ingress']), 2)
        self.assertEqual(self.fake.configuration['config']['ingress'][0]['hostname'], 'boatwiki.dmandr.net')
        self.assertEqual(self.fake.data['apps']['mcp']['policies'], [{'id': 'owner', 'precedence': 1}])
        self.assertIn(self.book['cloudflare']['app_id'], self.fake.data['apps'])
        self.cf.unpublish(self.book)  # Retry after a crash is harmless.

    def test_external_dns_change_prevents_removal(self):
        self.provision()
        self.fake.data['dns_records'][self.book['cloudflare']['dns_id']]['content'] = 'elsewhere'
        with self.assertRaises(Problem):
            self.cf.unpublish(self.book)
        self.assertEqual(len(self.fake.configuration['config']['ingress']), 3)

    def test_people_persist_duplicates_unknown_and_used_deletion(self):
        person = self.manager.add_person({'name': 'Alex', 'email': 'Alex@example.com'})
        self.assertEqual(person['email'], 'alex@example.com')
        with self.assertRaises(Problem):
            self.manager.add_person({'name': 'Again', 'email': 'alex@example.com'})
        with self.assertRaises(Problem):
            self.manager.selected_people(['unlisted@example.com'])
        restored = Registry(self.temp.name)
        self.assertEqual(restored.data['people'][person['id']], person)
        reader = next(p for p in self.manager.people() if p['email'] == 'reader@example.com')
        with self.assertRaises(Problem):
            self.manager.remove_person(reader['id'])
        self.manager.remove_person(person['id'])
        self.assertNotIn(person['id'], self.manager.registry.data['people'])

    def test_people_limit(self):
        for i in range(48):
            self.manager.add_person({'name': str(i), 'email': f'user{i}@example.com'})
        with self.assertRaises(Problem):
            self.manager.add_person({'name': 'Extra', 'email': 'extra@example.com'})

    def test_access_edit_does_not_resurrect_failed_removal(self):
        self.provision()
        self.manager.registry.update(self.book['id'], state='error', failed_action='remove')
        with self.assertRaises(Problem):
            self.manager.change_users(self.book['id'], ['new@example.com'], ['reader@example.com'])

    def test_failed_access_update_denies_mcp_until_retry(self):
        self.provision()
        self.manager.registry.update(self.book['id'], users=['new@example.com'])
        self.fake.reject = ('POST', self.cf.apps + '/' + self.book['cloudflare']['app_id'] + '/revoke_tokens')
        self.manager.job(self.book['id'], 'access')
        self.assertEqual(Gateway(self.manager).books('new@example.com'), [])
        self.assertEqual(Gateway(self.manager).books('reader@example.com'), [])
        self.fake.reject = None
        self.manager.job(self.book['id'], 'access')
        self.assertEqual(len(Gateway(self.manager).books('new@example.com')), 1)
        self.assertEqual(Gateway(self.manager).books('reader@example.com'), [])

    def test_missing_secret_cannot_check_or_create(self):
        self.cf.secret.unlink()
        self.assertFalse(self.cf.status()['configured'])
        with self.assertRaises(Problem):
            self.cf.check('free')
        self.assertEqual(self.fake.calls, [])


if __name__ == '__main__':
    unittest.main()
