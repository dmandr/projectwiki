#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/../common.sh"
require_book
mkdir -p "$PROJECTBOOK_SCRIPT_DIR/.runtime" "$HOME/Library/LaunchAgents"
export PROJECTBOOK_PUSH_PYTHON="$(command -v python3)"
export PROJECTBOOK_PUSH_SCRIPT="$PROJECTBOOK_SCRIPT_DIR/deploy/watch-push.py"
export PROJECTBOOK_PUSH_STATE="$PROJECTBOOK_SCRIPT_DIR/.runtime/book-push.json"
export PROJECTBOOK_PUSH_PLIST="$HOME/Library/LaunchAgents/net.projectbook.book-push.plist"
python3 - <<'PY'
import os,plistlib
p=os.environ
with open(p['PROJECTBOOK_PUSH_PLIST'],'wb') as f:
 plistlib.dump({'Label':'net.projectbook.book-push','ProgramArguments':[p['PROJECTBOOK_PUSH_PYTHON'],p['PROJECTBOOK_PUSH_SCRIPT'],p['PROJECTBOOK_WIKI_DIR'],p['PROJECTBOOK_PUSH_STATE']], 'RunAtLoad':True,'KeepAlive':True,'ThrottleInterval':10,'StandardOutPath':p['PROJECTBOOK_PUSH_STATE']+'.log','StandardErrorPath':p['PROJECTBOOK_PUSH_STATE']+'.log'},f)
PY
launchctl bootout "gui/$(id -u)/net.projectbook.book-push" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PROJECTBOOK_PUSH_PLIST"
echo "Auto-push enabled. Status: $PROJECTBOOK_PUSH_STATE"
