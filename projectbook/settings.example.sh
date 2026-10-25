# Copy to settings.local.sh if needed. This is trusted shell code, not a dotenv file.
# Shell environment overrides these defaults (keep the ${...:-...} syntax).
export PROJECTBOOK_PORT="${PROJECTBOOK_PORT:-4000}"
export PROJECTBOOK_INSTANCE="${PROJECTBOOK_INSTANCE:-projectbook-fork}"
export PROJECTBOOK_IMAGE="${PROJECTBOOK_IMAGE:-projectwiki:local}"
# Default: an independent sibling checkout named testwiki-projectwiki.
# export PROJECTBOOK_WIKI_DIR="${PROJECTBOOK_WIKI_DIR:-/absolute/path/to/book}"
export GOLLUM_REF="${GOLLUM_REF:-main}"
export GOLLUM_EDITOR="${GOLLUM_EDITOR:-mdx}"
export GOLLUM_TREE="${GOLLUM_TREE:-true}"
export GOLLUM_READ_ONLY="${GOLLUM_READ_ONLY:-false}"

# Optional semantic search. false installs/starts no RAG containers or model.
export PROJECTBOOK_RAG_AVAILABLE="${PROJECTBOOK_RAG_AVAILABLE:-false}"
# Initial value only, before this deployment has saved settings in its RAG volume.
export PROJECTBOOK_RAG_ENABLED="${PROJECTBOOK_RAG_ENABLED:-false}"
# Permit Settings changes from this local deployment's Web UI. This is not login/auth.
export PROJECTBOOK_SETTINGS_ADMIN="${PROJECTBOOK_SETTINGS_ADMIN:-false}"
# Resource limits: restart deployment to apply. The tested model is pinned in the image.
export PROJECTBOOK_RAG_THREADS="${PROJECTBOOK_RAG_THREADS:-4}"
export PROJECTBOOK_RAG_CPUS="${PROJECTBOOK_RAG_CPUS:-4}"
export PROJECTBOOK_RAG_MEMORY="${PROJECTBOOK_RAG_MEMORY:-4g}"
export PROJECTBOOK_QDRANT_CPUS="${PROJECTBOOK_QDRANT_CPUS:-2}"
export PROJECTBOOK_QDRANT_MEMORY="${PROJECTBOOK_QDRANT_MEMORY:-2g}"
# Initial runtime defaults; subsequently editable in Settings.
export PROJECTBOOK_RAG_BATCH_SIZE="${PROJECTBOOK_RAG_BATCH_SIZE:-16}"
export PROJECTBOOK_RAG_POLL_SECONDS="${PROJECTBOOK_RAG_POLL_SECONDS:-60}"
