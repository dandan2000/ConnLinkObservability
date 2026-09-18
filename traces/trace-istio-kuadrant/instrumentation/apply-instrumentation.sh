#!/usr/bin/env bash
# Instrumentación Go (Operador OpenTelemetry) para bff-service y echo-api en connlink.
# Requiere: operador OpenTelemetry, collector otel-collector en openshift-tempo-operator.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS=connlink
SA=otel-workloads

echo "==> 1/4 SCC + ServiceAccount"
oc apply -f "${ROOT}/scc-otel-go.yaml"
oc apply -f "${ROOT}/serviceaccount.yaml"
oc adm policy add-scc-to-user otel-go-instrumentation-scc -z "${SA}" -n "${NS}"

echo "==> 2/4 Instrumentation CR (Go -> OTLP HTTP :4318)"
oc apply -f "${ROOT}/instrumentation-connlink.yaml"

echo "==> 3/4 Anotaciones + SA en deployments (rollout)"
# Llamada in-cluster para que BFF y echo-api compartan trace_id (W3C traceparent).
# Evita re-entrar por gw-two (echo-api.fortaleza.bank), que crea trazas gateway aparte.
if oc get deployment bff-service -n "${NS}" &>/dev/null; then
  oc set env deployment/bff-service -n "${NS}" \
    UPSTREAM_URIS='http://echo-api.connlink.svc.cluster.local:80'
fi

for dep in bff-service echo-api; do
  if ! oc get deployment "${dep}" -n "${NS}" &>/dev/null; then
    echo "    omitido: deployment/${dep} no existe"
    continue
  fi
  oc patch deployment "${dep}" -n "${NS}" --type=merge -p "$(cat <<PATCH
{
  "spec": {
    "template": {
      "metadata": {
        "annotations": {
          "instrumentation.opentelemetry.io/inject-go": "connlink-instrumentation",
          "instrumentation.opentelemetry.io/otel-go-auto-target-exe": "/app/fake-service"
        }
      },
      "spec": {
        "serviceAccountName": "${SA}"
      }
    }
  }
}
PATCH
)"
  oc rollout status deployment/"${dep}" -n "${NS}" --timeout=3m
done

echo "==> 4/4 Verificación rápida"
POD="$(oc get pod -n "${NS}" -l app=fake-service -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -n "${POD}" ]]; then
  oc get pod -n "${NS}" "${POD}" -o jsonpath='containers={.spec.containers[*].name}{"\n"}'
  oc get pod -n "${NS}" "${POD}" -o jsonpath='shareProcessNamespace={.spec.shareProcessNamespace}{"\n"}'
fi

echo "==> Listo. Ver instrumentation/README.md (TraceQL y troubleshooting)."
