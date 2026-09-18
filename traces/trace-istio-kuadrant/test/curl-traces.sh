#!/usr/bin/env bash
set -euo pipefail

HOST="${HOST:-api.apps.sno.home}"
REQ_ID="${REQ_ID:-test-$(date +%s)}"
PORT="${PORT:-8080}"
GW_SVC="${GW_SVC:-gw-two-openshift-istio}"

echo "==> Port-forward: connlink/${GW_SVC} ${PORT}:80"
echo "    (ejecutar en otra terminal si no hay port-forward activo)"
echo
echo "==> curl con x-request-id=${REQ_ID}"
curl -s -D - -o /dev/null \
  -H "Host: ${HOST}" \
  -H "x-request-id: ${REQ_ID}" \
  "http://localhost:${PORT}/" | rg -i "x-request-id|HTTP/"

echo
echo "==> Buscar en Observe → Traces (tenant dev):"
echo "    Kuadrant:  { span.request_id = \"${REQ_ID}\" }"
echo "    Istio GW:  service.name =~ \"gw-two-openshift-istio\""
echo
echo "==> Para unificar trace_id (W3C), reenviar traceparent desde el cliente:"
TRACE_ID="$(openssl rand -hex 16)"
SPAN_ID="$(openssl rand -hex 8)"
echo "    traceparent=00-${TRACE_ID}-${SPAN_ID}-01"
