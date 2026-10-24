#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
# Dedicated sandbox. Never replace the normal 4569 deployment.
export PROJECTBOOK_INSTANCE=projectbook-rag
export PROJECTBOOK_PORT=4570
export PROJECTBOOK_IMAGE=projectwiki:rag-local
rag_compose() { docker compose -f "$PROJECTBOOK_SCRIPT_DIR/compose.yaml" -f "$PROJECTBOOK_SCRIPT_DIR/compose.rag.yaml" "$@"; }
require_docker
case "${1:-status}" in
  start) require_book; rag_compose up -d --build --wait --wait-timeout 120; echo 'Experimental wiki: http://127.0.0.1:4570/Home'; echo 'MCP: http://127.0.0.1:4570/mcp (read-only, includes search_knowledge and get_search_index_status)' ;;
  stop) rag_compose down ;;
  clean) rag_compose down --volumes; echo 'Experimental containers and generated model/index volumes removed; book untouched.' ;;
  logs) rag_compose logs --tail 60 rag ;;
  status) rag_compose exec -T rag python -c 'import urllib.request; print(urllib.request.urlopen("http://localhost:8090/status").read().decode())' ;;
  rebuild) rag_compose exec -T rag python -c 'import json, urllib.request; print(urllib.request.urlopen(urllib.request.Request("http://localhost:8090/index", data=json.dumps({"force":True}).encode(), headers={"Content-Type":"application/json"})).read().decode())' ;;
  benchmark) rag_compose exec -T rag python /app/benchmark.py ;;
  index) rag_compose exec -T rag python -c 'import urllib.request; print(urllib.request.urlopen(urllib.request.Request("http://localhost:8090/index", data=b"{}", headers={"Content-Type":"application/json"})).read().decode())' ;;
  *) echo 'Usage: rag.sh start|stop|clean|logs|status|index|rebuild|benchmark' >&2; exit 1 ;;
esac
