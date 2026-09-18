# Tracing Istio + Kuadrant

Manifiestos para trazas **Kuadrant y Envoy/Istio** en un Gateway API con **`GatewayClass: openshift-istio`**. Istio exporta spans del proxy al **mismo** OpenTelemetry Collector que wasm-shim / Authorino.

Solo Kuadrant (gateway OCP nativo, sin mesh tracing): **[trace-kuadrant/](../trace-kuadrant/README.md)**.

```
curl → Gateway openshift-istio (gw-two)
         ├─ spans Envoy/Istio (Telemetry)
         └─ wasm-shim → Authorino / Limitador
         ↓ OTLP (mismo collector)
   OpenTelemetry Collector (+ transform spans)
         ↓
   TempoMonolithic → Observe → Traces
```

## Prerrequisitos

- OpenShift 4.22+ con **Red Hat OpenShift Service Mesh 3** (`servicemeshoperator3` en `redhat-operators`).
- `GatewayClass` `openshift-istio` (suele existir en OCP; `gatewayclass/` es opcional).
- RHCL / Kuadrant, Tempo, OpenTelemetry y COO (subscriptions en `operators/`).
- Namespace `connlink` con políticas Kuadrant en el Gateway.

## Operadores

| Operador | Namespace | Subscription |
|----------|-----------|--------------|
| Red Hat Connectivity Link | `openshift-operators` | `rhcl-operator` |
| Tempo Operator | `openshift-tempo-operator` | `tempo-product` |
| Red Hat build of OpenTelemetry | `openshift-opentelemetry-operator` | `opentelemetry-product` |
| Cluster Observability Operator | `openshift-cluster-observability-operator` | `cluster-observability-operator` |
| **OpenShift Service Mesh 3** | `openshift-operators` | `servicemeshoperator3` (`redhat-operators`, channel `stable`) |

OSSM 3 instala el operador Sail downstream. Los CR `Istio` e `IstioCNI` (`sailoperator.io`) se aplican en `istio-system/` e `istio-cni/` tras el CSV en fase `Succeeded`.

> Si el InstallPlan queda en **Manual**, aprobarlo: `oc get installplan -n openshift-operators`

## Orden de aplicación

```bash
./apply-all.sh
SKIP_DEMO=1 ./apply-all.sh   # si connlink/gw-two ya existe
```

Pasos manuales equivalentes:

1. `operators/` → Tempo → `otel-collector/` → `coo/`
2. `istio-system/` + `istio-cni/` → `istio.yaml` (mesh `extensionProviders`) → `demo/namespace.yaml` → `telemetry-connlink.yaml`
3. `kuadrant/` → `gateway/` → `demo/`

### Istio tracing (este bundle)

- **`istio-system/istio.yaml`:** `enableTracing` + provider `otel-collector` → OTLP `:4317`.
- **`istio-system/telemetry-connlink.yaml`:** sampling 100% en namespace `connlink`.

El collector debe existir **antes** de aplicar `istio.yaml` (el `apply-all.sh` ya respeta ese orden).

### Collector

`otel-collector/opentelemetrycollector.yaml` incluye processor `transform/traces` para:

- Renombrar `service.name` de wasm-shim en el gateway (`gateway/<deployment>`).
- Aclarar nombres de spans gRPC de Authorino.

## Prueba de trazas

```bash
oc port-forward -n connlink svc/gw-two-openshift-istio 8080:80

REQ_ID="test-$(date +%s)"
curl -v -H "Host: api.apps.sno.home" \
     -H "x-request-id: ${REQ_ID}" \
     http://localhost:8080/
```

O: `./test/curl-traces.sh`

En **Observe → Traces** (tenant `dev`):

| Origen | Cómo filtrar |
|--------|----------------|
| Kuadrant | `{ span.request_id = "<REQ_ID>" }` → `wasm-shim`, `authorino` |
| Istio gateway | `service.name` ~ `gw-two-openshift-istio` |

### Dos traces con el mismo `request_id`

Es **esperado** si el cliente solo envía `x-request-id`: Envoy inicia un trace y wasm-shim otro (limitación WASM/Envoy; ver [Kuadrant tracing](https://docs.kuadrant.io/latest/kuadrant-operator/doc/observability/tracing/)).

Para acercar un **único `trace_id`**, enviar W3C `traceparent` desde el cliente:

```bash
TRACE_ID=$(openssl rand -hex 16)
SPAN_ID=$(openssl rand -hex 8)
curl -H "traceparent: 00-${TRACE_ID}-${SPAN_ID}-01" \
     -H "x-request-id: ${REQ_ID}" \
     ...
```

## Estructura

```
trace-istio-kuadrant/
├── operators/
├── tempo/
├── otel-collector/       # collector + transform (Istio + Kuadrant)
├── coo/
├── istio-system/         # Istio CR, Telemetry connlink
├── istio-cni/
├── gatewayclass/         # opcional
├── kuadrant/
├── gateway/
├── demo/
└── instrumentation/      # Go auto-instrumentation bff/echo-api (Operador OTel)
```

### Workloads connlink (bff / echo-api con fake-service)

Trazas de aplicación vía operador OpenTelemetry (sidecar Go, OTLP HTTP `:4318`):

```bash
./instrumentation/apply-instrumentation.sh
```

Detalle: `instrumentation/README.md`.

## Notas

1. Aplicar **solo uno** de los bundles en el mismo Gateway si no quieres duplicar collectors/Telemetry; son variantes de referencia.
2. Workloads sin sidecar (ej. `echo-api` solo contenedor app) no generan spans mesh downstream.
3. No editar EnvoyFilters `kuadrant-*`.
