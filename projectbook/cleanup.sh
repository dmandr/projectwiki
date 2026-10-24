#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
if (($# > 1)) || [[ "${1:-}" != '' && "${1:-}" != '--image' ]]; then
  echo 'Usage: cleanup.sh [--image]' >&2; exit 1
fi
require_docker
compose down --remove-orphans
if [[ "${1:-}" == '--image' ]]; then
  # No force: refuse to remove the image if another container still uses it.
  docker image rm "$PROJECTBOOK_IMAGE"
fi
echo "Book preserved: $PROJECTBOOK_WIKI_DIR"
