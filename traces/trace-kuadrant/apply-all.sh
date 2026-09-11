#!/usr/bin/env bash
# Aplica todos los manifiestos en orden. Requiere oc y permisos cluster-admin.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> 1/7 Operadores"
oc apply -f "${ROOT}/operators/"

echo "==> Esperando operadores (60s)..."
sleep 60

echo "==> 2/7 Tempo"
oc apply -f "${ROOT}/tempo/"
oc wait --for=condition=Ready tempomonolithic/multitenant -n openshift-tempo-operator --timeout=5m || true

echo "==> 3/7 OpenTelemetry Collector"
oc apply -f "${ROOT}/otel-collector/"
oc wait --for=condition=Ready opentelemetrycollector/otel-collector -n openshift-tempo-operator --timeout=5m || true

echo "==> 4/7 UI Plugin"
oc apply -f "${ROOT}/coo/"

echo "==> 5/7 Kuadrant tracing"
oc apply -f "${ROOT}/kuadrant/"

echo "==> 6/7 EnvoyFilter preserve-request-id"
oc apply -f "${ROOT}/gateway/"

echo "==> 7/7 Demo (opcional - omitir si ya existe connlink/gw-two)"
if [[ "${SKIP_DEMO:-}" != "1" ]]; then
  oc apply -f "${ROOT}/demo/"
fi

echo "==> Listo. Ver README.md para pruebas."
