# Instrumentación Go en connlink (Operador OpenTelemetry)

Manifiestos para **bff-service** y **echo-api** cuando usan `nicholasjackson/fake-service` (binario en `/app/fake-service`).

## Prerrequisitos

- Operador Red Hat build of OpenTelemetry instalado.
- `OpenTelemetryCollector/otel-collector` en `openshift-tempo-operator` con receivers OTLP **4317** (gRPC) y **4318** (HTTP).
- Deployments `bff-service` y `echo-api` en namespace `connlink`.

## Aplicar

```bash
chmod +x instrumentation/apply-instrumentation.sh
./instrumentation/apply-instrumentation.sh
```

O paso a paso:

```bash
oc apply -f instrumentation/scc-otel-go.yaml
oc apply -f instrumentation/serviceaccount.yaml
oc adm policy add-scc-to-user otel-go-instrumentation-scc -z otel-workloads -n connlink
oc apply -f instrumentation/instrumentation-connlink.yaml
# luego patch de deployments (ver apply-instrumentation.sh)
```

## Qué debe verse en el pod

Tras el rollout, cada pod instrumentado debería tener:

- Dos contenedores: el de la app + `opentelemetry-auto-instrumentation`
- `shareProcessNamespace: true`
- Variables `OTEL_*` en el sidecar (endpoint **:4318**)

```bash
oc get pod -n connlink -l app=fake-service -o jsonpath='{.items[0].spec.containers[*].name}{"\n"}'
oc describe pod -n connlink -l app=echo-api | rg -i 'opentelemetry|Failed|privileged'
```

## Trazas en consola

Tenant Tempo del lab: `dev`.

TraceQL (ejemplos):

```traceql
{ resource.k8s.namespace.name = "connlink" && resource.k8s.deployment.name = "bff-service" }
{ resource.k8s.namespace.name = "connlink" && resource.k8s.deployment.name = "echo-api" }
```

Los nombres de servicio en spans suelen derivar del deployment/contenedor; además seguirás viendo spans de Kuadrant (`wasm-shim`, etc.).

## Spans “sueltos” (no un solo árbol)

Es normal ver **varias trazas** para un mismo request si no alineás propagación. En este lab conviven tres mecanismos distintos:

| Origen | Correlación | Protocolo típico |
|--------|-------------|------------------|
| Kuadrant (wasm-shim, authorino) | atributo `request_id` ← header **`x-request-id`** | OTLP gRPC, no enlaza con Go por defecto |
| Istio (gateways `gw-one` / `gw-two`) | **`traceparent`** / mesh OTel | OTLP al mismo collector |
| Apps Go (BFF, echo-api) | **`traceparent`** (propagators del `Instrumentation`) | OTLP HTTP `:4318` |

### Cadena real del lab

```text
Cliente → gw-one → bff-service → ??? → echo-api
                              ↑
              si UPSTREAM = echo-api.fortaleza.bank
              vuelve a entrar por gw-two → trazas gateway extra, otro trace_id
```

**Qué hacer:**

1. **BFF → echo-api por Service cluster-internal** (el script `apply-instrumentation.sh` fija `UPSTREAM_URIS=http://echo-api.connlink.svc.cluster.local:80`). Así el client span del BFF y el server span de echo-api comparten **`trace_id`** en Tempo (un solo trace de aplicación).

   Si preferís hostname público, aceptá trazas gateway separadas en el salto intermedio.

2. **Kuadrant vs apps:** el CR Kuadrant usa `httpHeaderIdentifier: x-request-id`, no sustituye W3C. Aunque BFF y echo-api estén unidos, **wasm-shim suele seguir en otro `trace_id`**. Correlacioná con TraceQL:

   ```traceql
   { span.request_id = "<tu-x-request-id>" }
   ```

   vs spans Go filtrando por deployment. Ver [Kuadrant tracing](https://docs.kuadrant.io/latest/kuadrant-operator/doc/observability/tracing/) (limitación Envoy/WASM).

3. **Unificar más (Istio + apps):** enviar **`traceparent`** desde el cliente además de `x-request-id` (ver `test/curl-traces.sh` y README principal). Eso ayuda a que el gateway Istio y el servidor Go del BFF compartan contexto W3C.

4. **No esperes un único trace_id** que incluya wasm-shim + Istio + Go en todos los labs; lo habitual es **un trace de app** (bff+echo) + **traces de data plane** correlacionadas por `x-request-id` o por `traceparent` donde aplique.

### Comprobar integración BFF → echo-api

Tras cambiar `UPSTREAM_URIS`, generá tráfico al BFF y en Tempo abrí un trace de `bff-service`: deberías ver spans hijos hacia echo-api **con el mismo Trace ID**, no dos roots independientes.

## Si echo-api no es fake-service

- Imagen `quay.io/3scale/echoapi`: **no** aplica `inject-go` / `/app/fake-service`; hace falta otro enfoque (SDK, Zipkin en fake-service, etc.).
- Si la imagen es otra Go, ajustá `otel-go-auto-target-exe` al path real (`readlink /proc/1/exe` dentro del contenedor).

## Troubleshooting

| Síntoma | Causa habitual |
|--------|----------------|
| Pod 1/1, sin sidecar | Falta `otel-go-auto-target-exe` |
| Pod Pending / SCC | SA sin `otel-go-instrumentation-scc` |
| Sidecar CrashLoop | Imagen autoinstrumentation no pullable o exe path incorrecto |
| Sidecar OK, sin spans en Tempo | Endpoint Go debe ser **:4318** (HTTP), no gRPC :4317 |

Go auto-instrumentation es **Technology Preview** en la documentación de Red Hat.
