import tempfile
import unittest
from unittest.mock import Mock, patch
from manager import Manager, Problem
import auto_update

class AutoUpdateTest(unittest.TestCase):
    def setUp(self):
        self.directory=tempfile.TemporaryDirectory();self.addCleanup(self.directory.cleanup)
        self.m=Manager(self.directory.name,docker=Mock())
    def test_default_off_and_persistence(self):
        self.assertFalse(auto_update.setting(self.m)['enabled'])
        auto_update.setting(self.m,True)
        self.assertTrue(auto_update.setting(Manager(self.directory.name,docker=Mock()))['enabled'])
        with self.assertRaises(Problem):auto_update.setting(self.m,'true')
    @patch('updates.latest')
    def test_disabled_does_not_check(self,latest):
        auto_update.tick(self.m);latest.assert_not_called()
    @patch('updates.latest')
    @patch('updates.version',return_value={'available':True})
    def test_open_editor_blocks_start(self,version,latest):
        auto_update.setting(self.m,True)
        self.m.registry.data['books']['b']={'id':'b','state':'ready','name':'Book'}
        self.m.editing=Mock(side_effect=Problem('Open editor',409));self.m.start=Mock()
        auto_update.tick(self.m);self.m.start.assert_not_called()
        self.assertIn('Waiting for editors',self.m.auto_update_status)
    @patch('updates.latest',return_value={'image':'new'})
    @patch('updates.version',return_value={'available':True})
    def test_bundle_scheduled_after_fence(self,version,latest):
        auto_update.setting(self.m,True)
        self.m.registry.data['books']['b']={'id':'b','state':'ready','name':'Book','indexing':True}
        self.m.editing=Mock(return_value={'active_editors':0});self.m.start=Mock()
        auto_update.tick(self.m)
        self.assertEqual(self.m.editing.call_args.args[1], 'prepare')
        self.m.start.assert_called_once_with('b','update_book')
        self.assertEqual(self.m.registry.get('b')['update_targets'],{'wiki':'new','rag':'new'})
    @patch('auto_update.latest',create=True)
    def test_busy_does_not_update(self,latest):
        auto_update.setting(self.m,True);self.m.active.add('b')
        auto_update.tick(self.m);latest.assert_not_called()
