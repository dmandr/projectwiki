#!/bin/bash
# Build an editor-only hotfix on the exact deployed image; preserve its backend.
set -euo pipefail
cd "$(dirname "$0")/../.."
base_image="${1:?Existing deployment image required}"
output_image="${2:?New versioned image tag required}"
platform="${3:-linux/amd64}"
npm --prefix projectbook/editor test
npm --prefix projectbook/editor run build
context="$(mktemp -d "${TMPDIR:-/tmp}/projectbook-editor-image.XXXXXX")"
trap 'rm -rf "$context"' EXIT
cp -R projectbook/editor/dist "$context/dist"
cp -R projectbook/editor/src "$context/src"
cat > "$context/Dockerfile" <<'DOCKER'
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
COPY dist /experiment/editor/dist
COPY src /opt/projectbook-source/projectbook/editor/src
DOCKER
docker build --platform "$platform" --build-arg "BASE_IMAGE=$base_image" -t "$output_image" "$context"
echo "$output_image"
