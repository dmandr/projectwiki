#!/bin/bash
set -euo pipefail
host="${1:?SSH host required}"
image="${2:?Versioned image already delivered required}"
book="${3:?Book Git remote required}"
[[ "$image" =~ ^[a-zA-Z0-9./:_-]+$ && "$book" =~ ^[a-zA-Z0-9./:@_-]+$ ]] || exit 1
here="$(cd "$(dirname "$0")" && pwd)"
ssh "$host" 'mkdir -p /opt/projectbook'
scp "$here/compose.yaml" "$here/nginx.conf" "$here/watch-push.py" "$host:/opt/projectbook/"
ssh "$host" bash -s -- "$image" "$book" <<'REMOTE'
set -euo pipefail
cd /opt/projectbook
if [ ! -d book/.git ]; then git clone "$2" book; fi
git -c safe.directory=/opt/projectbook/book -C book status --short
git -c safe.directory=/opt/projectbook/book -C book diff --quiet
git -c safe.directory=/opt/projectbook/book -C book diff --cached --quiet
git -c safe.directory=/opt/projectbook/book -C book pull --ff-only
chown -R 1000:1000 book
git config --global --add safe.directory /opt/projectbook/book
IMAGE="$1" python3 - <<'PY'
import os,secrets
from pathlib import Path
p=Path('.env'); old=p.read_text().splitlines() if p.exists() else []
lines=[s for s in old if not s.startswith('PROJECTBOOK_IMAGE=')]
lines.append('PROJECTBOOK_IMAGE='+os.environ['IMAGE'])
if not any(s.startswith('PROJECTBOOK_MCP_TOKEN=') for s in lines): lines.append('PROJECTBOOK_MCP_TOKEN='+secrets.token_urlsafe(32))
p.write_text('\n'.join(lines)+'\n');p.chmod(0o600)
PY
cat > /etc/systemd/system/projectbook-book-push.service <<'UNIT'
[Unit]
Description=Push committed ProjectBook changes to origin
After=network-online.target
[Service]
Environment=HOME=/root
ExecStart=/usr/bin/python3 /opt/projectbook/watch-push.py /opt/projectbook/book /opt/projectbook/book-push.json
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable projectbook-book-push.service
systemctl restart projectbook-book-push.service
docker compose up -d --wait --wait-timeout 180
docker compose ps
REMOTE
