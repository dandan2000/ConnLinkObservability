# Tracing Kuadrant (sin Istio)

Manifiestos para **solo trazas de componentes Kuadrant** en un Gateway API **nativo de OpenShift** (`GatewayClass: openshift-default`). No instala Istio ni configura `Telemetry` / `extensionProviders` del mesh.

Para Gateway **Istio** (`openshift-istio`) + spans de Envoy en el mismo collector, usar **[trace-istio-kuadrant/](../trace-istio-kuadrant/README.md)**.

```
curl → Gateway openshift-default (gw-two) + wasm-shim
         ↓ OTLP
   OpenTelemetry Collector
         ↓ OTLP + tenant dev
   TempoMonolithic (multitenant)
         ↓
   Consola OCP → Observe → Traces
```

## Prerrequisitos

- OpenShift 4.22+ con `GatewayClass` `openshift-default`.
- Connectivity Link (RHCL) ya instalado o instalable vía operador.
- Permisos de `cluster-admin` para operadores, RBAC y UIPlugin.
- Namespace `connlink` con Gateway `gw-two` y HTTPRoute (ver `demo/`).

## Operadores requeridos

| Operador | Namespace | Subscription |
|----------|-----------|--------------|
| Red Hat Connectivity Link | `openshift-operators` | `rhcl-operator` |
| Tempo Operator | `openshift-tempo-operator` | `tempo-product` |
| Red Hat build of OpenTelemetry | `openshift-opentelemetry-operator` | `opentelemetry-product` |
| Cluster Observability Operator | `openshift-cluster-observability-operator` | `cluster-observability-operator` |

**No** se requiere OpenShift Service Mesh 3 / Istio.

## Orden de aplicación

### 1. Operadores

```bash
oc apply -f operators/
```

### 2. Tempo multitenant

```bash
oc apply -f tempo/
oc wait --for=condition=Ready tempomonolithic/multitenant -n openshift-tempo-operator --timeout=5m
```

### 3. OpenTelemetry Collector + RBAC

```bash
oc apply -f otel-collector/
oc wait --for=condition=Ready opentelemetrycollector/otel-collector -n openshift-tempo-operator --timeout=5m
```

### 4. UI de trazas

```bash
oc apply -f coo/
```

### 5. Kuadrant tracing

```bash
oc apply -f kuadrant/
```

### 6. Preservar `x-request-id` (recomendado)

```bash
oc apply -f gateway/
```

### 7. Demo (opcional)

Ajustar hostnames en `demo/gateway-gw-two.yaml` y `demo/httproute-echo-api.yaml`:

```bash
oc apply -f demo/
```

## Prueba de trazas

```bash
oc port-forward -n connlink svc/gw-two-openshift-default 8080:80

REQ_ID="test-$(date +%s)"
curl -v -H "Host: api.apps.sno.home" \
     -H "x-request-id: ${REQ_ID}" \
     http://localhost:8080/
```

O: `./test/curl-traces.sh`

En **Observe → Traces** (tenant `dev`):

- Service names: `wasm-shim`, `authorino`, `limitador`
- Correlación: `{ span.request_id = "<REQ_ID>" }`

## Estructura

```
trace-kuadrant/
├── operators/
├── tempo/
├── otel-collector/     # collector sin transforms de gateway Istio
├── coo/
├── kuadrant/
├── gateway/
└── demo/               # GatewayClass openshift-default
```

## Notas

1. **Un solo origen de spans en el edge:** Kuadrant (wasm-shim, Authorino, Limitador). No hay spans HTTP de Envoy/Istio.
2. Processors del collector: `k8sattributes → resourcedetection → batch`.
3. No editar EnvoyFilters `kuadrant-*` (reconciliados por el operador).
