#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
platform="${1:-linux/amd64}"
revision="$(git rev-parse HEAD)"
short="$(git rev-parse --short=12 HEAD)"
image="projectbook-rag:${short}-${platform##*/}"
context="$(mktemp -d "${TMPDIR:-/tmp}/projectbook-rag-release.XXXXXX")"
trap 'rm -rf "$context"' EXIT
git archive "$revision" projectbook/rag | tar -x -C "$context"
docker buildx build --platform "$platform" --load -t "$image" --label "org.opencontainers.image.revision=$revision" "$context/projectbook/rag"
echo "$image"
