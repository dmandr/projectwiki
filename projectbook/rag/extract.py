"""Bounded PDF worker. Reads only a temporary Git blob, never active book paths."""
import json
import os
import resource
import sys
import subprocess
import re
from pypdf import PdfReader


def extract_pypdf(path):
    reader = PdfReader(path, strict=False)
    if reader.is_encrypted and not reader.decrypt(''):
        raise ValueError('encrypted_pdf')
    if len(reader.pages) > 3000:
        raise ValueError('page_limit')
    pages, blank = [], []
    for number, page in enumerate(reader.pages, 1):
        contents = page.get_contents()
        if contents and len(contents.get_data()) > 20 * 1024 * 1024:
            raise ValueError('page_stream_limit')
        text = page.extract_text() or ''
        if len(text) > 200_000:
            raise ValueError('page_text_limit')
        if not text.strip():
            blank.append(number)
        else:
            pages.append({'page': number, 'text': text})
    return {'extractor': 'pypdf', 'pages': pages, 'page_count': len(reader.pages), 'empty_pages': blank,
            'characters': sum(len(p['text']) for p in pages)}


def extract(path):
    try:
        return extract_pypdf(path)
    except Exception as original:
        info = subprocess.check_output(['pdfinfo', path], stderr=subprocess.DEVNULL, timeout=20).decode(errors='replace')
        count = int(re.search(r'^Pages:\s+(\d+)', info, re.MULTILINE).group(1))
        if count > 3000:
            raise ValueError('page_limit')
        text = subprocess.check_output(['pdftotext', '-layout', '-enc', 'UTF-8', path, '-'], stderr=subprocess.DEVNULL, timeout=60).decode('utf-8')
        texts = text.split('\f')
        if texts and not texts[-1].strip(): texts.pop()
        if len(texts) != count: raise ValueError('pdf_page_count_mismatch')
        if any(len(t) > 200_000 for t in texts): raise ValueError('page_text_limit')
        return {'extractor': 'poppler', 'fallback_reason': type(original).__name__, 'page_count': count,
                'pages': [{'page': n, 'text': t} for n, t in enumerate(texts, 1) if t.strip()],
                'empty_pages': [n for n, t in enumerate(texts, 1) if not t.strip()],
                'characters': sum(len(t) for t in texts)}


if __name__ == '__main__':
    limit = max(128, min(1024, int(os.getenv("PDF_MEMORY_MB", "1024")))) * 1024**2
    resource.setrlimit(resource.RLIMIT_AS, (limit, limit))
    resource.setrlimit(resource.RLIMIT_CPU, (100, 100))
    print(json.dumps(extract(sys.argv[1]), ensure_ascii=False))
