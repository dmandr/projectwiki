#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
require_book
require_docker
if ! compose up -d --build --wait --wait-timeout 120; then
  compose logs --tail 50 wiki
  exit 1
fi
echo "ProjectWiki: http://127.0.0.1:$PROJECTBOOK_PORT/Home"
echo "Book: $PROJECTBOOK_WIKI_DIR"
