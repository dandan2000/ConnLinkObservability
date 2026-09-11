# Tracing Kuadrant / Connectivity Link en OpenShift 4.22

Manifiestos para reproducir el stack de trazas usado en el lab:

```
curl → Gateway (gw-two) + wasm-shim
         ↓ OTLP
   OpenTelemetry Collector
         ↓ OTLP + tenant dev
   TempoMonolithic (multitenant)
         ↓
   Consola OCP → Observe → Traces
```

## Prerrequisitos

- OpenShift 4.22+ con `GatewayClass` `openshift-default` (gateway nativo OCP).
- Connectivity Link (RHCL) ya instalado o instalable vía operador.
- Permisos de `cluster-admin` para operadores, RBAC y UIPlugin.
- Namespace de aplicación `connlink` con Gateway `gw-two` y HTTPRoute (ver `demo/`).

## Operadores requeridos

| Operador | Namespace | Subscription |
|----------|-----------|--------------|
| Red Hat Connectivity Link | `openshift-operators` | `rhcl-operator` |
| Tempo Operator | `openshift-tempo-operator` | `tempo-product` |
| Red Hat build of OpenTelemetry | `openshift-opentelemetry-operator` | `opentelemetry-product` |
| Cluster Observability Operator | `openshift-cluster-observability-operator` | `cluster-observability-operator` |

Authorino y Limitador se instalan como dependencias de RHCL (OLM).

## Orden de aplicación

### 1. Operadores

```bash
oc apply -f operators/
```

Esperar CSVs en fase `Succeeded`:

```bash
oc get csv -n openshift-tempo-operator
oc get csv -n openshift-opentelemetry-operator
oc get csv -n openshift-cluster-observability-operator
oc get csv -n openshift-operators | rg rhcl
```

> **RHCL:** la subscription del lab usa `installPlanApproval: Manual`. Aprobar el InstallPlan si queda pendiente:
> `oc get installplan -n openshift-operators`

### 2. Tempo multitenant

```bash
oc apply -f tempo/
oc wait --for=condition=Ready tempomonolithic/multitenant -n openshift-tempo-operator --timeout=5m
```

Verificar tenant `dev`:

```bash
oc get tempomonolithic multitenant -n openshift-tempo-operator \
  -o jsonpath='tenant={.spec.multitenancy.authentication[0].tenantName} id={.spec.multitenancy.authentication[0].tenantId}{"\n"}'
```

El `tenantId` (UUID) lo asigna el cluster en modo `openshift`. El collector usa el **nombre** del tenant (`dev`) en `X-Scope-OrgID`.

### 3. OpenTelemetry Collector + RBAC

```bash
oc apply -f otel-collector/
oc wait --for=condition=Ready opentelemetrycollector/otel-collector -n openshift-tempo-operator --timeout=5m
```

Servicio OTLP: `otel-collector-collector.openshift-tempo-operator.svc.cluster.local:4317`

### 4. UI de trazas en consola

```bash
oc apply -f coo/
```

En **Administration → Cluster settings → Cluster observability → UI plugins**, verificar `distributed-tracing` en estado válido.

### 5. Kuadrant tracing

```bash
oc apply -f kuadrant/
```

Kuadrant propaga el endpoint OTLP a wasm-shim, Authorino y Limitador vía EnvoyFilters en el Gateway.

### 6. Preservar `x-request-id` del cliente (opcional pero recomendado)

Por defecto Envoy reemplaza `x-request-id` en el edge. Este EnvoyFilter **no** es gestionado por Kuadrant:

```bash
oc apply -f gateway/
```

### 7. Demo app (si el cluster no tiene gw-two / echo-api)

Ajustar en `demo/gateway-gw-two.yaml` el hostname `*.apps.<tu-dominio>` antes de aplicar:

```bash
# Editar APPS_DOMAIN en gateway-gw-two.yaml y httproute-echo-api.yaml
oc apply -f demo/
```

## Prueba de trazas

```bash
oc port-forward -n connlink svc/gw-two-openshift-default 8080:80

REQ_ID="test-$(date +%s)"
curl -v -H "Host: api.apps.sno.home" \
     -H "x-request-id: ${REQ_ID}" \
     http://localhost:8080/

echo "Buscar en consola: span.request_id = \"${REQ_ID}\""
```

En **Observe → Traces**:

- Tenant: `dev` / stack `multitenant`
- Service names esperados: `wasm-shim`, `authorino`, `limitador`
- Filtro namespace: `connlink` (wasm-shim), `kuadrant-system` (authorino/limitador)

TraceQL:

```traceql
{ span.request_id = "test-123" }
{ resource.k8s.namespace.name = "connlink" }
```

## Estructura de directorios

```
trace-kuadrant/
├── operators/          # Subscriptions OLM
├── tempo/              # TempoMonolithic multitenant
├── otel-collector/     # SA, RBAC, Collector
├── coo/                # UIPlugin distributed-tracing
├── kuadrant/           # Kuadrant CR observability + tracing
├── gateway/            # EnvoyFilter preserve x-request-id
└── demo/               # Gateway, echo-api, HTTPRoute, AuthPolicy
```

## Notas importantes

1. **Camino A (este setup):** trazas de componentes Kuadrant (wasm-shim, authorino, limitador). No requiere Istio CR ni extension provider en mesh.
2. **Processors del collector:** orden `k8sattributes → resourcedetection → batch` (batch al final) para que funcione el filtro por namespace.
3. **RBAC Tempo:** `resources: [dev]` + `resourceNames: [traces]` + verb `create` (no invertir).
4. **No editar** EnvoyFilters `kuadrant-*`; son reconciliados por el operador Kuadrant.
5. **Storage:** `memory` 2Gi es para lab; en producción usar S3/OBC.

## Versiones usadas en el lab

| Componente | Versión |
|------------|---------|
| OCP | 4.22 |
| RHCL | 1.4.2 |
| Tempo Operator | 0.22.0-1 |
| OpenTelemetry Operator | 0.158.0-1 |
| COO | 1.5.2 |
