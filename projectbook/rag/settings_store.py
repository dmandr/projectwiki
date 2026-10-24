"""Deployment-local settings. Never stored in the book repository."""
import hashlib
import json
import os
import threading

LOCK = threading.RLock()
DEFAULTS = {
    'enabled': os.getenv('RAG_ENABLED', 'false') == 'true',
    'auto_index': True,
    'include_pdf': True,
    'poll_seconds': int(os.getenv('POLL_SECONDS', '60')),
    'batch_size': int(os.getenv('BATCH_SIZE', '16')),
    'default_mode': 'hybrid',
    'result_limit': 8,
}


class Conflict(ValueError): pass


def validate(value):
    if not isinstance(value, dict) or set(value) != set(DEFAULTS):
        raise ValueError('Submit the complete settings object; unknown keys are not allowed')
    for key in ('enabled', 'auto_index', 'include_pdf'):
        if type(value[key]) is not bool: raise ValueError(key + ' must be a boolean')
    for key, low, high in [('poll_seconds', 30, 86400), ('batch_size', 1, 64), ('result_limit', 1, 20)]:
        if type(value[key]) is not int or not low <= value[key] <= high:
            raise ValueError(f'{key} must be between {low} and {high}')
    if value['default_mode'] not in ('hybrid', 'semantic', 'keyword'):
        raise ValueError('Invalid default search mode')
    return dict(value)


def version(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def read(state):
    with LOCK:
        path = state / 'settings.json'
        return validate(json.loads(path.read_text()) if path.exists() else DEFAULTS)


def save(state, value, expected_version):
    with LOCK:
        value = validate(value)
        previous = read(state)
        if expected_version != version(previous):
            raise Conflict('Settings changed in another session. Reload before saving.')
        if value != previous:
            state.mkdir(parents=True, exist_ok=True)
            temp = state / 'settings.json.tmp'
            temp.write_text(json.dumps(value, indent=2) + '\n')
            temp.replace(state / 'settings.json')
        return {'settings': value, 'version': version(value), 'unchanged': value == previous}
