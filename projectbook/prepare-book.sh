#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
if (($# > 1)); then echo 'Usage: prepare-book.sh [local-repository-or-Git-URL]' >&2; exit 1; fi
if [[ -e "$PROJECTBOOK_WIKI_DIR" ]]; then
  echo "Destination already exists; left untouched: $PROJECTBOOK_WIKI_DIR" >&2
  exit 1
fi
PROJECTBOOK_SEED="${1:-$PROJECTBOOK_SCRIPT_DIR/../../testwiki}"
# A separate object database, not a worktree or a clone borrowing its source objects.
git clone --no-local --branch "$GOLLUM_REF" -- "$PROJECTBOOK_SEED" "$PROJECTBOOK_WIKI_DIR"
# Local seeds should keep the actual remote, not push into the working seed checkout.
if [[ -d "$PROJECTBOOK_SEED" ]]; then
  if PROJECTBOOK_REMOTE="$(git -C "$PROJECTBOOK_SEED" remote get-url origin 2>/dev/null)"; then
    git -C "$PROJECTBOOK_WIKI_DIR" remote set-url origin "$PROJECTBOOK_REMOTE"
  else
    git -C "$PROJECTBOOK_WIKI_DIR" remote remove origin
  fi
fi
echo "Prepared independent book: $PROJECTBOOK_WIKI_DIR"
echo 'No commit, push or automatic synchronization was performed.'
