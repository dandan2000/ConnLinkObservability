Stack de Observabilidad en Conn Link

Los manifiestos referencias se obtuvieron por medio de 

kustomize build "https://github.com/Kuadrant/kuadrant-operator/config/install/configure/observability/openshift?ref=v1.4.2"

que es un ajuste sobre la documentación oficial

https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.4/html/observability/rhcl-observability#configure-obs-monitoring_rhcl-observability

que propone este comando, el cual falla

oc apply -k https://github.com/Kuadrant/kuadrant-operator/config/install/configure/observability?ref=v1.2.0


Listado de Metricas en:
https://github.com/Kuadrant/gateway-api-state-metrics/blob/main/METRICS.md

Se quita creacion de namespace monitoring

Se reemplaza ns monitoring por kudrant-system

Se trasladan manifiestos de otros ns a archivo extras.yaml para facilitar control de lo impactado.

Para que los Dashboard funcionen correctamente sobre los manifiestos HTTPRoutes se deben incluir:
  labels:
    - service: myapp
    - deployment: myapp

El valor myapp debe coincidir con el nombre del svc o deployment hacia el cual se dirige el tráfico (es decir el backend).



Se elimina manifiesto por impacto en Prometheus, pendiente analisis y mejora
apiVersion: telemetry.istio.io/v1alpha1
kind: Telemetry
metadata:
  name: namespace-metrics
  namespace: openshift-ingress
spec:
  metrics:
  - overrides:
    - match:
        metric: REQUEST_COUNT
      tagOverrides:
        request_url_path:
          value: request.url_path
    - match:
        metric: REQUEST_DURATION
      tagOverrides:
        request_url_path:
          value: request.url_path
    providers:
    - name: prometheus

Este manifiesto de Istio (usado por Kuadrant) configura el envío de métricas a Prometheus para todo el tráfico procesado en el namespace openshift-ingress, añadiendo la ruta exacta de la URL como una etiqueta (tag) en las métricas clave de cada petición.
¿Qué efecto específico produce?

De forma predeterminada, por motivos de rendimiento y cardinalidad, Istio no incluye la ruta completa del request (request.url_path) dentro de sus métricas estándar de Prometheus. Este manifiesto modifica ese comportamiento para dos métricas concretas:

    REQUEST_COUNT (Métrica istio_requests_total):

        Efecto: Añade la etiqueta request_url_path indicando la ruta solicitada (ej. /api/v1/users, /health, etc.).

        Para qué sirve: Te permite contar exactamente cuántas peticiones llegan a un endpoint específico.

    REQUEST_DURATION (Métrica istio_request_duration_milliseconds):

        Efecto: Añade la misma etiqueta request_url_path al histograma de latencia/duración.

        Para qué sirve: Te permite medir cuánto tarda Istio (o el Ingress Controller) en responder a endpoints específicos.

    Proveedor prometheus:

        Indica que estos cambios y etiquetas adicionales se aplicarán únicamente a la exportación hacia Prometheus.

Impacto práctico y por qué Kuadrant lo necesita

Kuadrant utiliza este tipo de métricas para Rate Limiting (Límite de tasa) y Observabilidad fina de APIs.

Con esta configuración, puedes construir dashboards en Grafana o alertas en Prometheus agrupadas por la URL exacta solicitada, en lugar de ver únicamente el rendimiento global del servicio o del Ingress.

    Advertencia sobre Cardinalidad: Añadir request.url_path genera una métrica nueva por cada URL única procesada. Si tu aplicación recibe peticiones con parámetros en la ruta como /users/123, /users/124, etc., la cantidad de series temporales en Prometheus puede dispararse (High Cardinality).

Se elimina susbcription a Grafana es independiente de este proceso.
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  labels:
    operators.coreos.com/grafana-operator.openshift-operators: ""
  name: grafana-operator
  namespace: openshift-operators
spec:
  channel: v5
  installPlanApproval: Automatic
  name: grafana-operator
  source: community-operators
  sourceNamespace: openshift-marketplace
