#!/usr/bin/env bash
set -euo pipefail

HOST="${HOST:-api.apps.sno.home}"
REQ_ID="${REQ_ID:-test-$(date +%s)}"
PORT="${PORT:-8080}"

echo "==> Port-forward: connlink/gw-two-openshift-default ${PORT}:80"
echo "    (ejecutar en otra terminal si no hay port-forward activo)"
echo
echo "==> curl con x-request-id=${REQ_ID}"
curl -s -D - -o /dev/null \
  -H "Host: ${HOST}" \
  -H "x-request-id: ${REQ_ID}" \
  "http://localhost:${PORT}/" | rg -i "x-request-id|HTTP/"

echo
echo "==> Buscar en Observe → Traces (tenant dev):"
echo "    { span.request_id = \"${REQ_ID}\" }"
