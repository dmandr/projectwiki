"""Optional local retrieval sidecar. Git blobs are input; generated volumes are disposable."""
import collections
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import threading
import time
import uuid
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from fastembed import TextEmbedding
from qdrant_client import QdrantClient, models
from rank_bm25 import BM25Okapi
import settings_store

BOOK = os.getenv('BOOK_DIR', '/book')
REF = os.getenv('BOOK_REF', 'main')
STATE = Path(os.getenv('STATE_DIR', '/state'))
MODEL = os.getenv('MODEL_NAME', 'sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2')
MODEL_REPO = 'Qdrant/paraphrase-multilingual-MiniLM-L12-v2-onnx-Q'
MODEL_REVISION = 'faf4aa4225822f3bc6376869cb1164e8e3feedd0'
THREADS = int(os.getenv('MODEL_THREADS', '4'))
BATCH = int(os.getenv('BATCH_SIZE', '16'))
ALIAS = 'projectbook_active'
# Increment whenever extraction/chunking changes. Cache is tied to this and the model.
SCHEMA = 'rag-v3-pdf-fallback-chars450-tokenoverlap16'
STATUS = {'state': 'starting', 'experimental': True, 'model': MODEL, 'threads': THREADS}
INDEX_LOCK = threading.Lock()
MODEL_LOCK = threading.Lock()
MODEL_PRIORITY = threading.Condition()
SEARCH_WAITERS = 0
VIEW_LOCK = threading.Lock()
MODEL_INSTANCE = None
VIEW = None
WAKE = threading.Event()


def configuration():
    return settings_store.read(STATE)


class IndexCancelled(Exception): pass


def check_active(config):
    current = configuration()
    if not current['enabled'] or current['include_pdf'] != config['include_pdf']:
        raise IndexCancelled('Indexing stopped after settings changed; published index retained')


Q = QdrantClient(url=os.getenv('QDRANT_URL', 'http://qdrant:6333'), timeout=30)


@contextmanager
def model_slot(search=False):
    """Search has priority between indexing batches; one ONNX invocation at a time."""
    global SEARCH_WAITERS
    if search:
        with MODEL_PRIORITY:
            SEARCH_WAITERS += 1
        try:
            with MODEL_LOCK:
                yield
        finally:
            with MODEL_PRIORITY:
                SEARCH_WAITERS -= 1
                MODEL_PRIORITY.notify_all()
    else:
        with MODEL_PRIORITY:
            MODEL_PRIORITY.wait_for(lambda: SEARCH_WAITERS == 0)
            MODEL_LOCK.acquire()
        try:
            yield
        finally:
            MODEL_LOCK.release()


def git(*args):
    return subprocess.check_output(['git', '-c', 'safe.directory=' + BOOK, '-C', BOOK, *args], timeout=60)


def head():
    return git('rev-parse', '--verify', REF + '^{commit}').decode().strip()


def entries(revision):
    result = []
    for entry in git('ls-tree', '-rz', '-l', revision).split(b'\0'):
        if not entry:
            continue
        meta, path = entry.split(b'\t', 1)
        mode, kind, sha, size = meta.decode().split()
        path = path.decode('utf-8')
        if kind != 'blob' or mode not in ('100644', '100755'):
            continue
        parts = path.split('/')
        folder_page = len(parts) > 1 and parts[-1] == '.index.md' and not any(p.startswith(('.', '_')) for p in parts[:-1])
        if any(p.startswith(('.', '_')) for p in parts) and not folder_page:
            continue
        ext = Path(path).suffix.lower()
        if ext not in ('.md', '.markdown', '.pdf'):
            continue
        result.append({'path': path, 'sha': sha, 'bytes': int(size), 'type': 'pdf' if ext == '.pdf' else 'markdown'})
    return result


def words(text):
    stopwords = {'the', 'a', 'an', 'and', 'or', 'to', 'for', 'of', 'in', 'on', 'how', 'is', 'it',
                 'и', 'в', 'на', 'с', 'по', 'для', 'как', 'или', 'к', 'из', 'что', 'это', 'у', 'о', 'об'}
    return [w for w in re.findall(r'\w+', text.casefold(), flags=re.UNICODE) if w not in stopwords]


def chunks(text, title, page=None):
    """Short overlapping chunks, retaining exact line/page provenance and section heading."""
    result, buf, start, heading = [], '', 1, title
    def flush(end):
        if buf.strip():
            result.append({'text': buf.strip(), 'heading': heading, 'line_start': start,
                           'line_end': end, 'page': page})
    for lineno, line in enumerate(text.splitlines(), 1):
        match = re.match(r'^#{1,6}\s+(.+)', line)
        if match:
            flush(lineno - 1); buf = ''; start = lineno; heading = match.group(1).strip()
        # Break long lines as well, so tokenization cannot silently discard a PDF page.
        for offset in range(0, max(1, len(line)), 350):
            part = line[offset:offset + 350]
            if len(buf) + len(part) + 1 > 450:
                flush(lineno)
                buf = ''; start = lineno
            if not buf:
                start = lineno
            buf += part + '\n'
    flush(len(text.splitlines()))
    return result


def load_model():
    global MODEL_INSTANCE
    if MODEL_INSTANCE is None:
        started = time.perf_counter()
        STATUS['phase'] = 'model_download_and_load'
        from huggingface_hub import snapshot_download
        files = ['model_optimized.onnx', 'config.json', 'tokenizer.json', 'tokenizer_config.json', 'special_tokens_map.json']
        args = dict(repo_id=MODEL_REPO, revision=MODEL_REVISION, cache_dir='/models', allow_patterns=files)
        try:
            location = snapshot_download(**args, local_files_only=True)
            if not all((Path(location) / name).exists() for name in files):
                raise FileNotFoundError('Incomplete cached model')
        except (FileNotFoundError, OSError):
            location = snapshot_download(**args)
        STATUS['model_download_seconds'] = round(time.perf_counter() - started, 3)
        MODEL_INSTANCE = TextEmbedding(model_name=MODEL, specific_model_path=location, threads=THREADS, providers=['CPUExecutionProvider'])
        STATUS['model_load_seconds'] = round(time.perf_counter() - started, 3)
    return MODEL_INSTANCE


def embedding_inputs(model, pieces, title):
    # The model-specific tokenizer enforces the budget, including context prefix.
    # Decode token windows to prevent FastEmbed's default truncation losing source text.
    tokenizer = model.model.tokenizer
    result = []
    from tokenizers import Tokenizer
    splitter = Tokenizer.from_str(tokenizer.to_str())
    splitter.no_truncation(); splitter.no_padding()
    for piece in pieces:
        prefix = (title + ' / ' + piece['heading'])[:120] + '\n'
        # Independent tokenizer copy avoids mutating the model's inference settings.
        ids = splitter.encode(piece['text'], add_special_tokens=False).ids
        prefix_ids = splitter.encode(prefix, add_special_tokens=False).ids[:32]
        prefix = splitter.decode(prefix_ids) + '\n'
        budget = max(32, min(128, (tokenizer.truncation or {}).get('max_length', 128)) - len(prefix_ids) - 4)
        for offset in range(0, len(ids), max(1, budget - 16)):
            subtext = splitter.decode(ids[offset:offset + budget])
            if subtext.strip():
                # Original text remains in payload for exact quotation; token window for embedding only.
                result.append((dict(piece), prefix + subtext))
            if offset + budget >= len(ids):
                break
    return result


def extract(entry, raw):
    path = entry['path']
    title = Path(path).stem.replace('_', ' ').replace('-', ' ')
    if entry['type'] == 'markdown':
        if len(raw) > 2 * 1024 * 1024:
            raise ValueError('markdown_size_limit')
        text = raw.decode('utf-8')
        match = re.search(r'^#\s+(.+)$', text, re.MULTILINE)
        title = match.group(1) if match else title
        return title, chunks(text, title), {'characters': len(text)}
    if len(raw) > 100 * 1024 * 1024:
        raise ValueError('pdf_size_limit')
    with tempfile.NamedTemporaryFile(suffix='.pdf') as file:
        file.write(raw); file.flush()
        process = subprocess.run(['python', '/app/extract.py', file.name], capture_output=True, timeout=120)
        if process.returncode:
            # No PDF text/content in operational logs.
            raise ValueError('pdf_extraction_failed')
        data = json.loads(process.stdout)
    pieces = [piece for page in data.pop('pages') for piece in chunks(page['text'], title, page['page'])]
    return title, pieces, data


def atomic_json(path, data):
    temp = path.with_suffix('.tmp')
    temp.write_text(json.dumps(data, ensure_ascii=False))
    temp.replace(path)


def aliases():
    return {alias.alias_name: alias.collection_name for alias in Q.get_aliases().aliases}


def index_book(force=False):
    global VIEW
    if not INDEX_LOCK.acquire(blocking=False):
        return
    started = time.perf_counter()
    generation = None
    published = False
    try:
        STATE.mkdir(parents=True, exist_ok=True)
        (STATE / 'cache').mkdir(exist_ok=True)
        config = configuration()
        if not config['enabled']:
            STATUS.update(state='disabled', phase='idle')
            return
        batch = config['batch_size']
        revision = head()
        STATUS.pop('error', None)
        STATUS.update(state='indexing', phase='starting', started_at=time.time(), processed_files=0)
        current = aliases().get(ALIAS)
        if current:
            current_report = json.loads((STATE / (current + '.json')).read_text())
            STATUS.update(indexed_revision=current_report['revision'], indexed_include_pdf=current_report.get('include_pdf', True), report=current_report['report'])
            if not force and current_report['revision'] == revision and current_report['model'] == MODEL and current_report['schema'] == SCHEMA and current_report.get('include_pdf', True) == config['include_pdf']:
                STATUS.update(state='ready', phase='idle', indexed_revision=revision, report=current_report['report'])
                return
        with MODEL_LOCK:
            model = load_model()
        check_active(config)
        generation = 'projectbook_' + uuid.uuid4().hex
        all_chunks, files = [], []
        report = {'revision': revision, 'model': MODEL, 'model_revision': MODEL_REVISION, 'schema': SCHEMA, 'threads': THREADS, 'batch_size': batch,
                  'files_total': 0, 'files_indexed': 0, 'chunks': 0, 'cache_hits': 0,
                  'extraction_seconds': 0., 'embedding_seconds': 0., 'upload_seconds': 0., 'pdf': [], 'errors': []}
        for entry in entries(revision):
            check_active(config)
            if entry['type'] == 'pdf' and not config['include_pdf']: continue
            report['files_total'] += 1
            STATUS.update(phase='extract_and_embed', processed_files=report['files_total'] - 1, current_type=entry['type'])
            cache_key = hashlib.sha256((SCHEMA + MODEL + MODEL_REVISION + entry['sha'] + entry['path']).encode()).hexdigest()
            cache = STATE / 'cache' / (cache_key + '.json.gz')
            try:
                if entry['bytes'] > (100 * 1024 * 1024 if entry['type'] == 'pdf' else 2 * 1024 * 1024):
                    raise ValueError('file_size_limit')
                if cache.exists():
                    with gzip.open(cache, 'rt') as stream:
                        data = json.load(stream)
                    report['cache_hits'] += 1
                else:
                    tick = time.perf_counter()
                    title, pieces, extraction = extract(entry, git('cat-file', 'blob', entry['sha']))
                    extract_seconds = time.perf_counter() - tick
                    tick = time.perf_counter()
                    pairs = embedding_inputs(model, pieces, title)
                    vectors = []
                    for offset in range(0, len(pairs), batch):
                        check_active(config)
                        # Yield the model between batches so searches can use the previous
                        # published generation while a large PDF is being indexed.
                        with model_slot():
                            vectors.extend(model.embed([text for _, text in pairs[offset:offset + batch]], batch_size=batch))
                    embed_seconds = time.perf_counter() - tick
                    data = {'title': title, 'chunks': [p for p, _ in pairs], 'vectors': [v.tolist() for v in vectors],
                            'extraction': extraction, 'extraction_seconds': extract_seconds, 'embedding_seconds': embed_seconds}
                    temp_cache = cache.with_suffix('.tmp')
                    with gzip.open(temp_cache, 'wt') as stream:
                        json.dump(data, stream, ensure_ascii=False)
                    temp_cache.replace(cache)
                    report['extraction_seconds'] += extract_seconds
                    report['embedding_seconds'] += embed_seconds
                if entry['type'] == 'pdf':
                    report['pdf'].append(dict(path=entry['path'], **data['extraction'], chunks=len(data['chunks'])))
                if not data['chunks']:
                    report['errors'].append({'path': entry['path'], 'reason': 'no_extractable_text_no_ocr'})
                    continue
                if not Q.collection_exists(generation):
                    Q.create_collection(generation, vectors_config=models.VectorParams(size=len(data['vectors'][0]), distance=models.Distance.COSINE))
                points = []
                for number, (piece, vector) in enumerate(zip(data['chunks'], data['vectors'])):
                    payload = dict(piece, path=entry['path'], sha=entry['sha'], type=entry['type'], title=data['title'])
                    point_id = str(uuid.uuid5(uuid.NAMESPACE_URL, entry['path'] + ':' + str(number)))
                    points.append(models.PointStruct(id=point_id, vector=vector, payload=payload))
                    all_chunks.append(dict(payload, id=point_id))
                tick = time.perf_counter()
                for offset in range(0, len(points), 64):
                    Q.upsert(generation, points=points[offset:offset + 64], wait=True)
                report['upload_seconds'] += time.perf_counter() - tick
                report['files_indexed'] += 1; report['chunks'] += len(points)
                files.append(entry)
            except (ValueError, UnicodeError, subprocess.TimeoutExpired) as error:
                report['errors'].append({'path': entry['path'], 'reason': str(error)[:100]})
            STATUS.update(processed_files=report['files_total'], chunks=report['chunks'])
            print(json.dumps({'event': 'indexed_file', 'processed': report['files_total'], 'chunks': report['chunks'], 'elapsed_seconds': round(time.perf_counter() - started, 2)}), flush=True)
        if not all_chunks:
            raise ValueError('No searchable text extracted; previous index retained')
        report.update(model_download_seconds=STATUS.get('model_download_seconds', 0), total_seconds=round(time.perf_counter() - started, 3),
                      model_load_seconds=STATUS.get('model_load_seconds', 0), finished_at=time.time())
        for key in ('extraction_seconds', 'embedding_seconds', 'upload_seconds'):
            report[key] = round(report[key], 3)
        manifest = {'revision': revision, 'model': MODEL, 'schema': SCHEMA, 'report': report, 'chunks': all_chunks, 'files': files, 'include_pdf': config['include_pdf']}
        atomic_json(STATE / (generation + '.json'), manifest)
        actions = []
        if current:
            actions.append(models.DeleteAliasOperation(delete_alias=models.DeleteAlias(alias_name=ALIAS)))
        actions.append(models.CreateAliasOperation(create_alias=models.CreateAlias(collection_name=generation, alias_name=ALIAS)))
        # Search holds this lock through its query; no mixed manifests or deleted old generation.
        with VIEW_LOCK:
            check_active(config)
            Q.update_collection_aliases(change_aliases_operations=actions)
            published = True
            VIEW = None
        STATUS.update(state='ready', phase='idle', indexed_revision=revision, indexed_include_pdf=config['include_pdf'], report=report)
        # Keep one previous generation for rollback; caches are disposable and explicitly cleaned with rag.sh clean.
        for collection in Q.get_collections().collections:
            if collection.name.startswith('projectbook_') and collection.name not in (generation, current):
                Q.delete_collection(collection.name)
                (STATE / (collection.name + '.json')).unlink(missing_ok=True)
    except Exception as error:
        STATUS.update(state=('disabled' if not configuration()['enabled'] else 'paused') if isinstance(error, IndexCancelled) else 'error', phase='idle', error=type(error).__name__ + ': ' + str(error)[:250])
        print(json.dumps({'event': 'index_error', 'error': STATUS['error']}), flush=True)
        if generation and not published:
            try:
                if Q.collection_exists(generation): Q.delete_collection(generation)
            except Exception: pass
    finally:
        INDEX_LOCK.release()


def get_view():
    global VIEW
    active = aliases().get(ALIAS)
    if not active:
        raise ValueError('Index is not ready; use get_search_index_status')
    if VIEW is None or VIEW[0] != active:
        data = json.loads((STATE / (active + '.json')).read_text())
        texts = [words(p['title'] + ' ' + p['heading'] + ' ' + p['text']) or ['__empty__'] for p in data['chunks']]
        VIEW = (active, data, BM25Okapi(texts))
    return VIEW


def search(query, path='', limit=None, mode=None):
    config = configuration()
    if not config['enabled']: raise ValueError('Semantic search is disabled in this deployment')
    limit = config['result_limit'] if limit is None else limit
    mode = config['default_mode'] if mode is None else mode
    if not isinstance(query, str) or not 1 <= len(query.strip()) <= 500:
        raise ValueError('Use a query of 1..500 characters')
    if not isinstance(path, str) or len(path) > 1024 or (path and any(p in ('', '.', '..') for p in path.split('/'))):
        raise ValueError('Invalid scope')
    if type(limit) is not int or not 1 <= limit <= 20 or mode not in ('semantic', 'hybrid', 'keyword'):
        raise ValueError('Invalid limit or mode')
    started = time.perf_counter()
    with VIEW_LOCK:
        active, data, bm25 = get_view()
        candidates = [p for p in data['chunks'] if not path or p['path'] == path or p['path'].startswith(path + '/')]
        candidates = [p for p in candidates if config['include_pdf'] or p['type'] != 'pdf']
        by_id = {p['id']: p for p in candidates}
        scores, dense_scores = collections.defaultdict(float), {}
        if mode != 'keyword':
            with model_slot(search=True):
                model = load_model()
                vector = list(model.query_embed([query]))[0].tolist()
            # Scope filtered using explicit matched paths; no approximate post-filter loss.
            query_filter = models.Filter(must=[models.FieldCondition(key='path', match=models.MatchAny(any=sorted({p['path'] for p in candidates})))]) if path or not config['include_pdf'] else None
            dense = Q.query_points(active, query=vector, query_filter=query_filter, limit=60, with_payload=False).points if candidates else []
            for rank, point in enumerate(dense, 1):
                scores[str(point.id)] += 1 / (60 + rank)
                dense_scores[str(point.id)] = point.score
        if mode != 'semantic':
            lexical = bm25.get_scores(words(query))
            order = sorted((i for i, p in enumerate(data['chunks']) if p['id'] in by_id and lexical[i] > 0), key=lambda i: lexical[i], reverse=True)[:60]
            for rank, i in enumerate(order, 1):
                scores[data['chunks'][i]['id']] += 1 / (60 + rank)
        results, seen = [], set()
        for point_id in sorted(scores, key=scores.get, reverse=True):
            p = by_id[point_id]
            identity = (p['path'], p['page'], p['line_start'], p['text'])
            if identity in seen: continue
            seen.add(identity)
            results.append(dict(p, score=round(scores[point_id], 6), semantic_score=dense_scores.get(point_id)))
            if len(results) >= limit: break
        return {'query': query, 'mode': mode, 'indexed_revision': data['revision'], 'model': data['model'],
                'seconds': round(time.perf_counter() - started, 3), 'items': results,
                'guidance': 'Scores rank relevance, not factual certainty. Read sources before answering or editing. PDF page numbers are one-based. No OCR.'}


def status():
    if 'report' not in STATUS:
        # Inspect a retained index without loading/downloading the embedding model.
        try:
            active = aliases().get(ALIAS)
            if active:
                saved = json.loads((STATE / (active + '.json')).read_text())
                STATUS.update(report=saved['report'], indexed_revision=saved['revision'], indexed_include_pdf=saved.get('include_pdf', True))
        except Exception:
            pass
    result = dict(STATUS)
    config = configuration()
    result['settings'] = config
    result['model_cached'] = (Path('/models') / ('models--' + MODEL_REPO.replace('/', '--')) / 'snapshots' / MODEL_REVISION / 'model_optimized.onnx').exists()
    result['model_loaded'] = MODEL_INSTANCE is not None
    result['model_revision'] = MODEL_REVISION
    if not config['enabled']: result['state'] = 'disabled'
    try:
        result['current_revision'] = head()
        result['stale'] = result.get('indexed_revision') != result['current_revision'] or result.get('indexed_include_pdf', True) != config['include_pdf']
    except Exception:
        result['stale'] = True
    return result


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def respond(self, code, data):
        body = json.dumps(data, ensure_ascii=False).encode()
        self.send_response(code); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        if self.path == '/health': self.respond(200, {'alive': True}); return
        if self.path == '/status': self.respond(200, status()); return
        if self.path == '/settings':
            value = configuration()
            self.respond(200, {'settings': value, 'version': settings_store.version(value), 'status': status()}); return
        self.respond(404, {'error': 'Not found'})
    def do_POST(self):
        try:
            size = int(self.headers.get('Content-Length', '0'))
            if not 0 < size <= 8192: raise ValueError('Request too large or empty')
            payload = json.loads(self.rfile.read(size))
            if self.path == '/settings':
                saved = settings_store.save(STATE, payload['settings'], payload['expected_version'])
                WAKE.set()
                self.respond(200, dict(saved, status=status()))
            elif self.path == '/search': self.respond(200, search(**payload))
            elif self.path == '/index':
                if not configuration()['enabled']: raise ValueError('Enable semantic search before indexing')
                threading.Thread(target=index_book, kwargs={'force': payload.get('force') is True}, daemon=True).start(); self.respond(202, {'scheduled': True})
            else: self.respond(404, {'error': 'Not found'})
        except settings_store.Conflict as error:
            self.respond(409, {'error': str(error)})
        except (ValueError, TypeError, KeyError) as error:
            self.respond(422, {'error': str(error)[:200]})
        except Exception as error:
            self.respond(503, {'error': 'Search unavailable: ' + type(error).__name__})


def poll():
    global MODEL_INSTANCE, VIEW
    while True:
        WAKE.clear()
        try:
            config = configuration()
            if config['enabled'] and config['auto_index']:
                index_book()
            elif not config['enabled']:
                if not INDEX_LOCK.locked():
                    with VIEW_LOCK, MODEL_LOCK:
                        MODEL_INSTANCE = None; VIEW = None
                STATUS.update(state='disabled', phase='idle')
            elif STATUS['state'] in ('starting', 'disabled'):
                STATUS.update(state='idle', phase='manual_indexing')
            WAKE.wait(config['poll_seconds'])
        except Exception as error:
            STATUS.update(state='error', error=str(error)[:200])
            WAKE.wait(30)


if __name__ == '__main__':
    threading.Thread(target=poll, daemon=True).start()
    ThreadingHTTPServer(('0.0.0.0', 8090), Handler).serve_forever()
