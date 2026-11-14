"""Conservative Git exchange shared by managed and standalone books."""
import fcntl
import os
from pathlib import Path
import time


def sync_book(git, root='/book'):
    root = Path(root)
    branch = git('symbolic-ref', '--short', 'HEAD')
    # Network I/O does not hold the application lock. Fetch never changes the worktree.
    git('fetch', '--no-tags', 'origin', 'refs/heads/' + branch + ':refs/remotes/origin/' + branch)
    lock = root / '.git' / 'projectbook-sync.lock'
    with lock.open('a+') as stream:
        os.chmod(lock, 0o666)
        deadline = time.monotonic() + 20
        while True:
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() > deadline:
                    raise RuntimeError('Book is busy; synchronization will retry.')
                time.sleep(.1)
        if git('symbolic-ref', '--short', 'HEAD') != branch:
            raise RuntimeError('Branch changed during fetch; synchronization will retry.')
        if git('status', '--porcelain'):
            raise RuntimeError('Uncommitted files or conflicts; synchronization paused. Files retained.')
        local = git('rev-parse', 'HEAD')
        remote = git('rev-parse', 'refs/remotes/origin/' + branch)
        ahead, behind = map(int, git('rev-list', '--left-right', '--count', local + '...' + remote).split())
        if ahead and behind:
            raise RuntimeError('Local and remote commits diverged; manual merge required. No changes discarded.')
        if behind:
            owner = root.stat()
            try:
                git('merge', '--ff-only', '--no-overwrite-ignore', remote)
            finally:
                # Git helpers run as root for short-lived credentials; web app keeps ownership.
                if os.geteuid() == 0:
                    for directory, dirs, files in os.walk(root):
                        os.chown(directory, owner.st_uid, owner.st_gid)
                        for name in dirs + files:
                            os.chown(os.path.join(directory, name), owner.st_uid, owner.st_gid, follow_symlinks=False)
        revision = git('rev-parse', 'HEAD')
    # Push the checked revision, not a HEAD that may have changed while waiting for network.
    git('push', 'origin', revision + ':refs/heads/' + branch)
    return {'revision': revision, 'branch': branch, 'pulled_commits': behind,
            'pushed_commits': ahead, 'ok': True, 'checked_at': time.time()}
