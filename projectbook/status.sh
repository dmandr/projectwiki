#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
require_docker
compose ps --all
echo "URL: http://127.0.0.1:$PROJECTBOOK_PORT/Home"
echo "Book: $PROJECTBOOK_WIKI_DIR"
if [[ -d "$PROJECTBOOK_WIKI_DIR/.git" ]]; then
  git -C "$PROJECTBOOK_WIKI_DIR" log -1 --format='Book HEAD: %h %s'
  git -C "$PROJECTBOOK_WIKI_DIR" status --short
fi
