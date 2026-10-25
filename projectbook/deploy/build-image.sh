#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
platform="${1:-linux/amd64}"
revision="$(git rev-parse HEAD)"
short="$(git rev-parse --short=12 HEAD)"
image="projectwiki:${short}-${platform##*/}"
context="$(mktemp -d "${TMPDIR:-/tmp}/projectbook-release.XXXXXX")"
trap 'rm -rf "$context"' EXIT
# Build exactly the reviewed commit even if another experiment edits this checkout.
git archive "$revision" | tar -x -C "$context"
docker buildx build --platform "$platform" --load -t "$image" --label "org.opencontainers.image.revision=$revision" -f "$context/projectbook/Dockerfile" "$context"
echo "$image"
