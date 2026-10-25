#!/bin/bash
set -euo pipefail
host="${1:?SSH host required}"
image="${2:?Versioned Docker image required}"
# Only the built image is transferred. No application checkout on the server.
docker image inspect "$image" >/dev/null
docker save "$image" | gzip | ssh "$host" 'gunzip | docker load'
