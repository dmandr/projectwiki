#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
platform="${1:-linux/amd64}"
revision="$(git rev-parse --short=12 HEAD)"
[[ -z "$(git status --porcelain)" ]] || { echo 'Commit reviewed source changes before building a release.' >&2; exit 1; }
image="projectwiki:${revision}-${platform##*/}"
docker buildx build --platform "$platform" --load -t "$image" --label "org.opencontainers.image.revision=$(git rev-parse HEAD)" -f projectbook/Dockerfile .
echo "$image"
