#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
require_docker
compose logs --tail 100 "$@" wiki
