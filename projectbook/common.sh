#!/bin/bash
set -euo pipefail
PROJECTBOOK_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Optional, trusted local shell configuration; never part of the image or Git.
if [[ -f "$PROJECTBOOK_SCRIPT_DIR/settings.local.sh" ]]; then
  source "$PROJECTBOOK_SCRIPT_DIR/settings.local.sh"
fi
export PROJECTBOOK_WIKI_DIR="${PROJECTBOOK_WIKI_DIR:-$PROJECTBOOK_SCRIPT_DIR/../../testwiki-projectwiki}"
export PROJECTBOOK_PORT="${PROJECTBOOK_PORT:-4569}"
export PROJECTBOOK_INSTANCE="${PROJECTBOOK_INSTANCE:-projectbook-fork}"
export PROJECTBOOK_IMAGE="${PROJECTBOOK_IMAGE:-projectwiki:local}"
export GOLLUM_REF="${GOLLUM_REF:-main}"
case "$PROJECTBOOK_WIKI_DIR" in
  /*) ;;
  *) echo 'PROJECTBOOK_WIKI_DIR must be an absolute path.' >&2; exit 1 ;;
esac
case "$PROJECTBOOK_PORT" in
  ''|*[!0-9]*) echo 'PROJECTBOOK_PORT must be a TCP port number.' >&2; exit 1 ;;
esac
if ((10#$PROJECTBOOK_PORT < 1 || 10#$PROJECTBOOK_PORT > 65535)); then
  echo 'PROJECTBOOK_PORT must be between 1 and 65535.' >&2; exit 1
fi
compose() { docker compose -f "$PROJECTBOOK_SCRIPT_DIR/compose.yaml" "$@"; }
require_docker() {
  command -v docker >/dev/null || { echo 'Install and start Docker Desktop first.' >&2; exit 1; }
  docker compose version >/dev/null
  docker info >/dev/null 2>&1 || { echo 'Start Docker Desktop and try again.' >&2; exit 1; }
}
require_book() {
  [[ -d "$PROJECTBOOK_WIKI_DIR/.git" ]] || {
    echo 'Book clone is missing. Run ./projectbook/prepare-book.sh first.' >&2; exit 1;
  }
  git -C "$PROJECTBOOK_WIKI_DIR" rev-parse --verify "$GOLLUM_REF^{commit}" >/dev/null
  [[ "$(git -C "$PROJECTBOOK_WIKI_DIR" symbolic-ref --short HEAD)" == "$GOLLUM_REF" ]] || {
    echo "Book checkout must be on branch $GOLLUM_REF." >&2; exit 1;
  }
}
