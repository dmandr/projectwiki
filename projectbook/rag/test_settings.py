import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import settings_store
import service


class SettingsTests(unittest.TestCase):
    def test_persistence_conflict_validation_and_noop(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            old = settings_store.read(state); version = settings_store.version(old)
            result = settings_store.save(state, old, version)
            self.assertTrue(result['unchanged']); self.assertFalse((state / 'settings.json').exists())
            new = dict(old, enabled=True, poll_seconds=300)
            saved = settings_store.save(state, new, version)
            self.assertEqual(new, settings_store.read(state))
            with self.assertRaises(settings_store.Conflict): settings_store.save(state, old, version)
            for invalid in [dict(new, batch_size=0),dict(new, enabled='true'),dict(new, poll_seconds=True),dict(new, model='arbitrary')]:
                with self.assertRaises(ValueError): settings_store.save(state, invalid, saved['version'])
            self.assertEqual(new, settings_store.read(state))

    def test_disabled_does_not_load_model_or_query_database(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch.multiple(service, STATE=Path(directory), STATUS={}), \
             patch.object(service, 'configuration', return_value=dict(settings_store.DEFAULTS, enabled=False)), \
             patch.object(service, 'load_model') as model, patch.object(service, 'Q') as db:
            service.index_book()
            self.assertEqual('disabled', service.STATUS['state'])
            with self.assertRaises(ValueError): service.search('engine')
            model.assert_not_called(); db.get_aliases.assert_not_called()

    def test_disabling_or_changing_pdf_cancels_existing_run(self):
        start = dict(settings_store.DEFAULTS, enabled=True, include_pdf=True)
        for changed in [dict(start,enabled=False),dict(start,include_pdf=False)]:
            with patch.object(service,'configuration',return_value=changed):
                with self.assertRaises(service.IndexCancelled): service.check_active(start)


if __name__ == '__main__': unittest.main()
