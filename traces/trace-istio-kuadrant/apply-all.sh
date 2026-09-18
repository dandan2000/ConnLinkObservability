#!/usr/bin/env bash
# Istio + Kuadrant tracing. Requiere oc y cluster-admin.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> 1/9 Operadores (Tempo, OTel, COO, RHCL, Service Mesh 3)"
oc apply -f "${ROOT}/operators/"

echo "==> Esperando operadores (60s)..."
sleep 60

echo "==> 2/9 Tempo"
oc apply -f "${ROOT}/tempo/"
oc wait --for=condition=Ready tempomonolithic/multitenant -n openshift-tempo-operator --timeout=5m || true

echo "==> 3/9 OpenTelemetry Collector"
oc apply -f "${ROOT}/otel-collector/"
oc wait --for=condition=Ready opentelemetrycollector/otel-collector -n openshift-tempo-operator --timeout=5m || true

echo "==> 4/9 UI Plugin"
oc apply -f "${ROOT}/coo/"

echo "==> 5/9 Istio"
echo "    Si OSSM3 es nuevo: oc wait csv -n openshift-operators servicemeshoperator3.v3.4.2 --for=jsonpath='{.status.phase}'=Succeeded --timeout=10m"
oc apply -f "${ROOT}/istio-system/namespace.yaml"
oc apply -f "${ROOT}/istio-cni/"
oc apply -f "${ROOT}/istio-system/istio.yaml"
oc apply -f "${ROOT}/demo/namespace.yaml"
oc apply -f "${ROOT}/istio-system/telemetry-connlink.yaml"

echo "==> 6/9 GatewayClass Istio (opcional si ya existe openshift-istio)"
oc apply -f "${ROOT}/gatewayclass/" || true

echo "==> 7/9 Kuadrant tracing"
oc apply -f "${ROOT}/kuadrant/"

echo "==> 8/9 EnvoyFilter preserve-request-id"
oc apply -f "${ROOT}/gateway/"

echo "==> 9/9 Demo (opcional - omitir si ya existe connlink/gw-two)"
if [[ "${SKIP_DEMO:-}" != "1" ]]; then
  oc apply -f "${ROOT}/demo/"
fi

echo "==> Listo. Ver README.md para pruebas."
