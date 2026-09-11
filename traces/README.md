# Traces

Configuración de distributed tracing para Connectivity Link (Kuadrant) en OpenShift.

## Manifiestos reproducibles

Ver **[trace-kuadrant/](trace-kuadrant/README.md)** — bundle completo con:

- Subscriptions de operadores (RHCL, Tempo, OpenTelemetry, COO)
- TempoMonolithic multitenant
- OpenTelemetry Collector + RBAC
- UIPlugin `distributed-tracing`
- Kuadrant CR (tracing + `httpHeaderIdentifier`)
- EnvoyFilter `preserve-request-id`
- Demo app (Gateway, echo-api, HTTPRoute, AuthPolicy)

```bash
cd traces/trace-kuadrant
./apply-all.sh          # aplicar todo en orden
SKIP_DEMO=1 ./apply-all.sh   # sin demo app
```

Querys utiles:

{ k8s.deployment.name = "gw-two-openshift-default" }

{ k8s.node.name = "sno-dani-cele" }
            
{ k8s.namespace.name = "connlink" }

{ k8s.pod.name = "gw-two-openshift-default-8698968ff6-jcz9z" }

{ span.request_id="test-pepe1" }
