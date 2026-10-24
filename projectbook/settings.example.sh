# Copy to settings.local.sh if needed. This is trusted shell code, not a dotenv file.
# Shell environment overrides these defaults (keep the ${...:-...} syntax).
export PROJECTBOOK_PORT="${PROJECTBOOK_PORT:-4569}"
export PROJECTBOOK_INSTANCE="${PROJECTBOOK_INSTANCE:-projectbook-fork}"
export PROJECTBOOK_IMAGE="${PROJECTBOOK_IMAGE:-projectwiki:local}"
# Default: an independent sibling checkout named testwiki-projectwiki.
# export PROJECTBOOK_WIKI_DIR="${PROJECTBOOK_WIKI_DIR:-/absolute/path/to/book}"
export GOLLUM_REF="${GOLLUM_REF:-main}"
export GOLLUM_EDITOR="${GOLLUM_EDITOR:-mdx}"
export GOLLUM_TREE="${GOLLUM_TREE:-true}"
export GOLLUM_READ_ONLY="${GOLLUM_READ_ONLY:-false}"
