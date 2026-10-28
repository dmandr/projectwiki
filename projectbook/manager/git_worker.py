"""Short-lived helper; only the selected book volume and Git credentials are mounted."""
import json
import os
from pathlib import Path
import subprocess
import sys
from urllib.parse import urlsplit


def git(*args, cwd='/book', check=True):
    env = dict(os.environ, GIT_TERMINAL_PROMPT='0', GIT_CONFIG_NOSYSTEM='1',
               GIT_CONFIG_GLOBAL='/dev/null', GIT_SSH_COMMAND=(
                   'ssh -F /dev/null -i /run/git/id_ed25519 -o IdentitiesOnly=yes '
                   '-o BatchMode=yes -o StrictHostKeyChecking=yes '
                   '-o UserKnownHostsFile=/run/git/known_hosts'))
    if Path('/run/git/ca.crt').is_file():
        env['GIT_SSL_CAINFO'] = '/run/git/ca.crt'
    result = subprocess.run(['git', '-c', 'core.hooksPath=/dev/null',
                             '-c', 'safe.directory=/book',
                             '-c', 'http.followRedirects=false', '-c', 'credential.useHttpPath=true',
                             '-c', 'credential.helper=!python /app/git_worker.py credential',
                             *args], cwd=cwd, env=env, capture_output=True, text=True, timeout=240)
    if check and result.returncode:
        # Git errors may contain credentials or remote-controlled text. Keep output local.
        raise RuntimeError('Git operation failed: ' + args[0] + '. Check repository access, branch and remote divergence.')
    return result.stdout.strip() if check else result


def clone(repo):
    root = Path('/book')
    if not (root / '.git').exists():
        if any(root.iterdir()):
            raise RuntimeError('Clone directory is not empty; retained for inspection.')
        git('clone', '--', repo, '/book', cwd='/')
    elif git('remote', 'get-url', 'origin') != repo:
        raise RuntimeError('Existing volume belongs to a different repository.')
    git('config', 'user.name', 'Project Book')
    git('config', 'user.email', 'projectbook@localhost')
    if git('rev-parse', '--verify', 'HEAD', check=False).returncode:
        (root / 'Home.md').write_text('# ' + os.environ.get('BOOK_TITLE', 'Project Book') + '\n', encoding='utf8')
        git('add', 'Home.md')
        git('commit', '-m', 'Initialize Project Book')
    branch = git('symbolic-ref', '--short', 'HEAD')
    if os.environ.get('GIT_INITIAL_PUSH') == '1':
        git('push', 'origin', 'HEAD:refs/heads/' + branch)
        remote = git('ls-remote', 'origin', 'refs/heads/' + branch).split()
        if not remote or remote[0] != git('rev-parse', 'HEAD'):
            raise RuntimeError('Initial Git push could not be verified; book retained.')
    # Container image runs as www-data (UID/GID 1000).
    for base, dirs, files in os.walk(root):
        os.chown(base, 1000, 1000)
        for name in dirs + files:
            os.chown(os.path.join(base, name), 1000, 1000, follow_symlinks=False)
    return {'branch': branch, 'revision': git('rev-parse', 'HEAD')}


def save():
    if git('ls-files', '-u'):
        raise RuntimeError('Unresolved Git conflicts; book retained.')
    git('add', '-A')
    # Raw Notes may intentionally be untracked during ordinary use. Preserve them on removal.
    notes = Path('/book/raw-notes')
    if notes.is_dir() and not notes.is_symlink():
        git('add', '-f', '--', 'raw-notes')
    if git('diff', '--cached', '--quiet', check=False).returncode:
        git('commit', '-m', 'Save book before removing its installation')
    branch = git('symbolic-ref', '--short', 'HEAD')
    revision = git('rev-parse', 'HEAD')
    git('push', 'origin', 'HEAD:refs/heads/' + branch)
    remote = git('ls-remote', 'origin', 'refs/heads/' + branch).split()
    if not remote or remote[0] != revision:
        raise RuntimeError('Remote verification failed; book retained.')
    return {'revision': revision, 'branch': branch, 'pushed': True}


def credential():
    fields = dict(line.rstrip('\n').split('=', 1) for line in sys.stdin if '=' in line)
    token = Path('/run/git/https-token')
    hosts = os.environ.get('GIT_HOSTS', 'github.com').split(',')
    if os.environ.get('GIT_OAUTH_STDIN') == '1':
        value = json.loads(Path('/run/git/oauth.json').read_text())
        repo = urlsplit(value['repo'])
        if (fields.get('protocol') == 'https' and fields.get('host') == 'github.com'
                and fields.get('path', '').removesuffix('.git') == repo.path.lstrip('/').removesuffix('.git')):
            print('username=x-access-token\npassword=' + value['token'])
        return
    if fields.get('protocol') == 'https' and fields.get('host') in hosts and token.is_file():
        print('username=x-access-token\npassword=' + token.read_text().strip())


if __name__ == '__main__':
    try:
        if sys.argv[1] == 'credential':
            credential()
        else:
            if os.environ.get('GIT_OAUTH_STDIN') == '1':
                value = json.loads(sys.stdin.read(4096))
                if not isinstance(value.get('token'), str) or not value['token'].startswith('ghu_') or '\n' in value['token']:
                    raise RuntimeError('Invalid short-lived Git credential.')
                repo = urlsplit(value.get('repo', ''))
                if repo.scheme != 'https' or repo.netloc != 'github.com':
                    raise RuntimeError('GitHub OAuth credentials require a GitHub HTTPS repository.')
                fd = os.open('/run/git/oauth.json', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                with os.fdopen(fd, 'w') as f:
                    json.dump(value, f)
            result = clone(sys.argv[2]) if sys.argv[1] == 'clone' else save()
            print(json.dumps(result))
    except Exception as error:
        print(json.dumps({'error': str(error) if isinstance(error, RuntimeError) else type(error).__name__}))
        sys.exit(1)
    finally:
        if sys.argv[1] != 'credential' and os.environ.get('GIT_OAUTH_STDIN') == '1':
            Path('/run/git/oauth.json').unlink(missing_ok=True)
