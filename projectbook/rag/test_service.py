import json
import subprocess
import tempfile
import unittest
import threading
import time
from pathlib import Path
from unittest.mock import patch
from types import SimpleNamespace
import service
from tokenizers import Tokenizer, models, pre_tokenizers


class RetrievalTests(unittest.TestCase):
    def test_generations_reuse_cache_remove_deleted_files_and_retain_index_on_failure(self):
        import numpy as np
        from qdrant_client import QdrantClient
        fake_model = SimpleNamespace(embed=lambda texts, **kwargs: [np.array([float(len(t)), 1.]) for t in texts])
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); book = root / 'book'; book.mkdir(); state = root / 'state'
            subprocess.run(['git', 'init', '-q', '-b', 'main', str(book)], check=True)
            def commit():
                subprocess.run(['git', '-C', str(book), 'add', '-A'], check=True)
                subprocess.run(['git', '-C', str(book), '-c', 'user.name=Test', '-c', 'user.email=test@example.com', 'commit', '-qm', 'Fixture'], check=True)
            (book / 'one.md').write_text('# First\nEngine coolant')
            (book / 'two.md').write_text('# Second\nOil maintenance')
            commit()
            client = QdrantClient(':memory:')
            with patch.multiple(service, BOOK=str(book), STATE=state, Q=client, STATUS={}, VIEW=None), \
                 patch.object(service, 'load_model', return_value=fake_model), \
                 patch.object(service, 'configuration', return_value=dict(service.settings_store.DEFAULTS, enabled=True)), \
                 patch.object(service, 'embedding_inputs', side_effect=lambda model, pieces, title: [(p, p['text']) for p in pieces]):
                service.index_book()
                self.assertEqual('ready', service.STATUS['state'])
                old = service.aliases()[service.ALIAS]
                (book / 'one.md').write_text('# First\nUpdated coolant')
                commit(); service.index_book()
                self.assertEqual(1, service.STATUS['report']['cache_hits'])
                self.assertNotEqual(old, service.aliases()[service.ALIAS])
                (book / 'two.md').unlink(); commit(); service.index_book()
                good = service.aliases()[service.ALIAS]
                points, _ = client.scroll(good)
                self.assertEqual({'one.md'}, {p.payload['path'] for p in points})
                (book / 'one.md').write_text('# First\nAnother update'); commit()
                with patch.object(client, 'upsert', side_effect=RuntimeError('Storage unavailable')):
                    service.index_book()
                self.assertEqual('error', service.STATUS['state'])
                self.assertEqual(good, service.aliases()[service.ALIAS])
                self.assertTrue(client.collection_exists(good))
            client.close()

    def test_queries_take_priority_over_next_index_batch(self):
        order = []
        service.MODEL_LOCK.acquire()
        def query():
            with service.model_slot(search=True): order.append('query')
        def indexing():
            with service.model_slot(): order.append('index')
        first = threading.Thread(target=query); first.start()
        deadline = time.monotonic() + 2
        while service.SEARCH_WAITERS == 0 and time.monotonic() < deadline: time.sleep(.001)
        self.assertEqual(1, service.SEARCH_WAITERS)
        second = threading.Thread(target=indexing); second.start()
        service.MODEL_LOCK.release()
        first.join(2); second.join(2)
        self.assertFalse(first.is_alive() or second.is_alive())
        self.assertEqual(['query', 'index'], order)

    def test_chunks_keep_all_text_and_page_heading(self):
        text = '# Heading\n' + 'x' * 1500 + '\nA Russian line: двигатель\n'
        pieces = service.chunks(text, 'Title', 7)
        self.assertEqual(1500, sum(p['text'].count('x') for p in pieces))
        self.assertTrue(all(p['page'] == 7 and p['heading'] == 'Heading' for p in pieces))
        self.assertTrue(all(len(p['text']) <= 450 for p in pieces))
        self.assertIn('двигатель', pieces[-1]['text'])

    def test_token_windows_do_not_drop_tail_or_exceed_budget(self):
        tokenizer = Tokenizer(models.WordLevel({'[UNK]': 0, 'word': 1, 'tail': 2}, unk_token='[UNK]'))
        tokenizer.pre_tokenizer = pre_tokenizers.Whitespace()
        tokenizer.enable_truncation(max_length=128)
        fake = SimpleNamespace(model=SimpleNamespace(tokenizer=tokenizer))
        pieces = [{'text': 'word ' * 500 + 'tail', 'heading': 'word ' * 100, 'page': None}]
        pairs = service.embedding_inputs(fake, pieces, 'word ' * 100)
        full = Tokenizer.from_str(tokenizer.to_str()); full.no_truncation()
        self.assertGreater(len(pairs), 1)
        self.assertTrue(all(len(full.encode(t).ids) <= 128 for _, t in pairs))
        self.assertIn('tail', pairs[-1][1])
        self.assertEqual(128, tokenizer.truncation['max_length'])

    def test_git_snapshot_ignores_local_work_hidden_files_and_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(['git', 'init', '-q', '-b', 'main', directory], check=True)
            (root / 'note.md').write_text('# Committed')
            (root / '.secret.md').write_text('secret')
            (root / 'alias.md').symlink_to('/etc/passwd')
            subprocess.run(['git', '-C', directory, 'add', '.'], check=True)
            subprocess.run(['git', '-C', directory, '-c', 'user.name=Test', '-c', 'user.email=test@example.com', 'commit', '-qm', 'Fixture'], check=True)
            (root / 'note.md').write_text('# Unsaved')
            with patch.object(service, 'BOOK', directory):
                entries = service.entries(service.head())
                self.assertEqual(['note.md'], [e['path'] for e in entries])
                self.assertEqual(b'# Committed', service.git('cat-file', 'blob', entries[0]['sha']))

    def test_invalid_queries_rejected_before_model_or_database(self):
        for kwargs in [{'query': ''}, {'query': 'x', 'limit': 100}, {'query': 'x', 'path': '../secret'}, {'query': 'x', 'mode': 'shell'}]:
            with self.assertRaises(ValueError): service.search(**kwargs)

    def test_image_only_pdf_explicitly_reports_empty_page(self):
        from pypdf import PdfWriter
        from extract import extract
        with tempfile.NamedTemporaryFile(suffix='.pdf') as file:
            writer = PdfWriter(); writer.add_blank_page(width=100, height=100); writer.write(file.name)
            data = extract(file.name)
            self.assertEqual(1, data['page_count']); self.assertEqual([1], data['empty_pages'])
            self.assertEqual([], data['pages']); self.assertEqual(0, data['characters'])

    def test_aes_pdf_and_poppler_fallback(self):
        from pypdf import PdfWriter
        import extract
        with tempfile.NamedTemporaryFile(suffix='.pdf') as file:
            writer = PdfWriter(); writer.add_blank_page(width=100, height=100)
            writer.encrypt('', algorithm='AES-256'); writer.write(file.name)
            data = extract.extract(file.name)
            self.assertEqual('pypdf', data['extractor'])
            self.assertEqual(1, data['page_count'])
            with patch.object(extract, 'extract_pypdf', side_effect=ValueError('Parser limit')):
                data = extract.extract(file.name)
                self.assertEqual('poppler', data['extractor'])
                self.assertEqual('ValueError', data['fallback_reason'])
                self.assertEqual([1], data['empty_pages'])


if __name__ == '__main__': unittest.main()
