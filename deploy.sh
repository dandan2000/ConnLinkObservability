## Script probado en Red Hat OpenShift Container Platform Cluster
#!/bin/bash
set -e

echo "=== 1. Aplicando manifiestos base de Kubernetes / OpenShift ==="
cat << 'YAML' | oc apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: openshift-default
spec:
  controllerName: openshift.io/gateway-controller/v1
---
kind: Project
apiVersion: project.openshift.io/v1
metadata:
  name: connlink
spec: { }
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  labels:
    istio.io/rev: openshift-gateway
    kuadrant.io/gateway: 'true'
  name: gw-one
  namespace: connlink
spec:
  gatewayClassName: openshift-default
  listeners:
    - allowedRoutes:
        namespaces:
          from: All
      name: api
      port: 80
      protocol: HTTP
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echoserver
  namespace: connlink
spec:
  replicas: 1
  selector:
    matchLabels:
      app: echoserver
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 25%
      maxUnavailable: 25%
  template:
    metadata:
      labels:
        app: echoserver
    spec:
      containers:
        - name: echoserver
          image: quay.io/3scale/echoapi:stable
          livenessProbe:
            tcpSocket:
              port: 9292 
            initialDelaySeconds: 10
            timeoutSeconds: 1
          readinessProbe:
            httpGet:
              path: /test/200 
              port: 9292 
            initialDelaySeconds: 15
            timeoutSeconds: 1
          ports:
            - containerPort: 9292 
              protocol: TCP
---
apiVersion: v1
kind: Service
metadata:
  name: echoserver
  namespace: connlink
spec:
  ports:
  - name: echo-api-port
    port: 80
    protocol: TCP
    targetPort: 9292
  selector:
    app: echoserver
  type: ClusterIP
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: echoserver
  namespace: connlink
  labels: 
    service: echoserver ## tiene que llamarse igual al service
spec:
  hostnames:
    - echoserver.example.com
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: gw-one
      namespace: connlink
  rules:
    - backendRefs:
        - group: ''
          kind: Service
          name: echoserver
          port: 80
          weight: 1
      filters: []
      matches:
        - method: GET
          path:
            type: PathPrefix
            value: /
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhcl-operator
  namespace: connlink
spec:
  channel: stable
  installPlanApproval: Automatic
  name: rhcl-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
---
kind: OperatorGroup
apiVersion: operators.coreos.com/v1
metadata:
  name: kuadrant
  namespace: connlink
spec:
  upgradeStrategy: Default
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
## MAGIA MOSCO
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: grafana-thanos-reader
  namespace: connlink
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: grafana-thanos-reader-monitoring-view
subjects:
  - kind: ServiceAccount
    name: grafana-thanos-reader
    namespace: connlink
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-monitoring-view
---
apiVersion: v1
kind: Secret
metadata:
  name: grafana-thanos-reader-token
  namespace: connlink
  annotations:
    kubernetes.io/service-account.name: grafana-thanos-reader
type: kubernetes.io/service-account-token
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: grafana-operator
  namespace: connlink
spec:
  channel: v5
  installPlanApproval: Automatic
  name: grafana-operator
  source: community-operators
  sourceNamespace: openshift-marketplace
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: servicemeshoperator3
  namespace: openshift-operators
spec:
  channel: stable
  installPlanApproval: Automatic
  name: servicemeshoperator3
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  startingCSV: servicemeshoperator3.v3.4.1
YAML


# 2. Esperar a que el operador registre los CRDs en la API
echo "=== Esperando a que Grafana Operator registre sus CRDs ==="
until oc get crd grafanas.grafana.integreatly.org &>/dev/null; do
  echo "Esperando a que OLM cree los CRDs de Grafana..."
  sleep 5
done

oc wait --for=condition=Established crd/grafanas.grafana.integreatly.org --timeout=120s
oc wait --for=condition=Established crd/grafanadashboards.grafana.integreatly.org --timeout=120s

cat << 'YAML' | oc apply -f -
apiVersion: grafana.integreatly.org/v1beta1
kind: Grafana
metadata:
  name: grafana-cl
  namespace: connlink
  labels:
    dashboards: grafana-cl
spec:
  config:
    security:
      admin_user: root
      admin_password: start
    auth.anonymous:
      enabled: "false"
  route:
    spec:
      port:
        targetPort: grafana
---
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: thanos-querier
  namespace: connlink
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana-cl     # tiene que matchear el label del CR Grafana
  valuesFrom:
    - targetPath: secureJsonData.httpHeaderValue1
      valueFrom:
        secretKeyRef:
          name: grafana-thanos-reader-token
          key: token
  datasource:
    name: Kuadrant-Thanos-Hub    # ver 11.3: el nombre lo imponen los dashboards de Kuadrant
    type: prometheus
    access: proxy
    url: https://thanos-querier.openshift-monitoring.svc.cluster.local:9091
    isDefault: true
    jsonData:
      timeInterval: 30s
      httpHeaderName1: Authorization
      tlsSkipVerify: true
    secureJsonData:
      httpHeaderValue1: "Bearer ${token}"    # ${token} lo resuelve valuesFrom

## MAGIA DANI pero desplegado en namespace connlink, el lo despliega en kuadrant-system
---
apiVersion: v1
automountServiceAccountToken: false
kind: ServiceAccount
metadata:
  labels:
    app.kubernetes.io/component: exporter
    app.kubernetes.io/name: kube-state-metrics-kuadrant
    app.kubernetes.io/part-of: kuadrant
    app.kubernetes.io/version: 2.5.0
  name: kube-state-metrics-kuadrant
  namespace: connlink
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  labels:
    app.kubernetes.io/component: exporter
    app.kubernetes.io/name: kube-state-metrics-kuadrant
    app.kubernetes.io/part-of: kuadrant
    app.kubernetes.io/version: 2.5.0
  name: kube-state-metrics-kuadrant
rules:
- apiGroups:
  - ""
  resources:
  - configmaps
  - secrets
  - nodes
  - pods
  - services
  - resourcequotas
  - replicationcontrollers
  - limitranges
  - persistentvolumeclaims
  - persistentvolumes
  - namespaces
  - endpoints
  verbs:
  - list
  - watch
- apiGroups:
  - apps
  resources:
  - statefulsets
  - daemonsets
  - deployments
  - replicasets
  verbs:
  - list
  - watch
- apiGroups:
  - batch
  resources:
  - cronjobs
  - jobs
  verbs:
  - list
  - watch
- apiGroups:
  - autoscaling
  resources:
  - horizontalpodautoscalers
  verbs:
  - list
  - watch
- apiGroups:
  - authentication.k8s.io
  resources:
  - tokenreviews
  verbs:
  - create
- apiGroups:
  - authorization.k8s.io
  resources:
  - subjectaccessreviews
  verbs:
  - create
- apiGroups:
  - policy
  resources:
  - poddisruptionbudgets
  verbs:
  - list
  - watch
- apiGroups:
  - certificates.k8s.io
  resources:
  - certificatesigningrequests
  verbs:
  - list
  - watch
- apiGroups:
  - storage.k8s.io
  resources:
  - storageclasses
  - volumeattachments
  verbs:
  - list
  - watch
- apiGroups:
  - admissionregistration.k8s.io
  resources:
  - mutatingwebhookconfigurations
  - validatingwebhookconfigurations
  verbs:
  - list
  - watch
- apiGroups:
  - networking.k8s.io
  resources:
  - networkpolicies
  - ingresses
  verbs:
  - list
  - watch
- apiGroups:
  - coordination.k8s.io
  resources:
  - leases
  verbs:
  - list
  - watch
- apiGroups:
  - apiextensions.k8s.io
  resources:
  - customresourcedefinitions
  verbs:
  - list
  - watch
- apiGroups:
  - gateway.networking.k8s.io
  resources:
  - gateways
  - gatewayclasses
  - httproutes
  - grpcroutes
  - tcproutes
  - tlsroutes
  - udproutes
  verbs:
  - list
  - watch
- apiGroups:
  - kuadrant.io
  resources:
  - tlspolicies
  - dnspolicies
  - ratelimitpolicies
  - authpolicies
  verbs:
  - list
  - watch
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  labels:
    app.kubernetes.io/component: exporter
    app.kubernetes.io/name: kube-state-metrics-kuadrant
    app.kubernetes.io/part-of: kuadrant
    app.kubernetes.io/version: 2.5.0
  name: kube-state-metrics-kuadrant
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kube-state-metrics-kuadrant
subjects:
- kind: ServiceAccount
  name: kube-state-metrics-kuadrant
  namespace: connlink
---
apiVersion: v1
data:
  custom-resource-state.yaml: |
    kind: CustomResourceStateMetrics
    spec:
      resources:
        - groupVersionKind:
            group: gateway.networking.k8s.io
            kind: "Gateway"
            version: "v1beta1"
          metricNamePrefix: gatewayapi_gateway
          labelsFromPath:
            name:
            - metadata
            - name
            namespace:
            - metadata
            - namespace
          metrics:
          - name: "info"
            help: "Gateway information"
            each:
              type: Info
              info:
                labelsFromPath:
                  gatewayclass_name: [spec, gatewayClassName]
          - name: "labels"
            help: "Kubernetes labels converted to Prometheus labels."
            each:
              type: Info
              info:
                path: [metadata]
                labelsFromPath:
                  "*": [labels]
          - name: "created"
            help: "created timestamp"
            each:
              type: Gauge
              gauge:
                path: [metadata, creationTimestamp]
          - name: "deleted"
            help: "deletion timestamp"
            each:
              type: Gauge
              gauge:
                path: [metadata, deletionTimestamp]
          - name: "listener_info"
            help: "Gateway listener information"
            each:
              type: Info
              info:
                path: [spec, listeners]
                labelsFromPath:
                  listener_name: ["name"]
                  port: ["port"]
                  protocol: ["protocol"]
                  hostname: ["hostname"]
                  tls_mode: ["tls","mode"]
                  allowed_routes_namespaces_from: ["allowedRoutes", "namespaces", "from"]
          - name: "status"
            help: "status condition"
            each:
              type: Gauge
              gauge:
                path: [status, conditions]
                labelsFromPath:
                  type: ["type"]
                valueFrom: ["status"]
          - name: "status_listener_attached_routes"
            help: "Number of attached routes for a listener"
            each:
              type: Gauge
              gauge:
                path: [status, listeners]
                labelsFromPath:
                  listener_name: ["name"]
                valueFrom: ["attachedRoutes"]
          - name: "status_address_info"
            help: "Gateway address types and values"
            each:
              type: Info
              info:
                path: [status, addresses]
                labelsFromPath:
                  type: ["type"]
                  value: ["value"]
        - groupVersionKind:
            group: gateway.networking.k8s.io
            kind: "GatewayClass"
            version: "v1beta1"
          metricNamePrefix: gatewayapi_gatewayclass
          labelsFromPath:
            name:
            - metadata
            - name
          metrics:
          - name: "info"
            help: "GatewayClass information"
            each:
              type: Info
              info:
                labelsFromPath:
                  controller_name: [spec, controllerName]
          - name: "labels"
            help: "Kubernetes labels converted to Prometheus labels."
            each:
              type: Info
              info:
                path: [metadata]
                labelsFromPath:
                  "*": [labels]
          - name: "created"
            help: "created timestamp"
            each:
              type: Gauge
              gauge:
                path: [metadata, creationTimestamp]
          - name: "deleted"
            help: "deletion timestamp"
            each:
              type: Gauge
              gauge:
                path: [metadata, deletionTimestamp]
          - name: "status"
            help: "status condition"
            each:
              type: Gauge
              gauge:
                path: [status, conditions]
                labelsFromPath:
                  type: ["type"]
                valueFrom: ["status"]
          - name: "status_supported_features"
            help: "List of supported features for the GatewayClass"
            each:
              type: Info
              info:
                path: [status, supportedFeatures]
                labelsFromPath:
                  features: []
        - groupVersionKind:
            group: gateway.networking.k8s.io
            kind: "HTTPRoute"
            version: "v1beta1"
          metricNamePrefix: gatewayapi_httproute
          labelsFromPath:
            name:
            - metadata
            - name
            namespace:
            - metadata
            - namespace
          metrics:
          - name: "labels"
            help: "Kubernetes labels converted to Prometheus labels."
            each:
              type: Info
              info:
                path: [metadata]
                labelsFromPath:
                  "*": [labels]
          - name: "created"
            help: "created timestamp"
            each:
              type: Gauge
              gauge:
                path: [metadata, creationTimestamp]
          - name: "deleted"
            help: "deletion timestamp"
            each:
              type: Gauge
              gauge:
                path: [metadata, deletionTimestamp]
          - name: "hostname_info"
            help: "Hostname information"
            each:
              type: Info
              info:
                path: [spec, hostnames]
                labelsFromPath:
                  hostname: []
          - name: "parent_info"
            help: "Parent references that the httproute wants to be attached to"
            each:
              type: Info
              info:
                path: [spec, parentRefs]
                labelsFromPath:
                  parent_group: ["group"]
                  parent_kind: ["kind"]
                  parent_name: ["name"]
                  parent_namespace: ["namespace"]
                  parent_section_name: ["sectionName"]
                  parent_port: ["port"]
          - name: "status_parent_info"
            help: "Parent references that the httproute is attached to"
            each:
              type: Info
              info:
                path: [status, parents]
                labelsFromPath:
                  controller_name: ["controllerName"]
                  parent_group: ["parentRef", "group"]
                  parent_kind: ["parentRef", "kind"]
                  parent_name: ["parentRef", "name"]
                  parent_namespace: ["parentRef", "namespace"]
                  parent_section_name: ["parentRef", "sectionName"]
                  parent_port: ["parentRef", "port"]
        - groupVersionKind:
            group: gateway.networking.k8s.io
            kind: "GRPCRoute"
            version: "v1alpha2"
          metricNamePrefix: gatewayapi_grpcroute
          labelsFromPath:
            name:
            - metadata
            - name
            namespace:
            - metadata
            - namespace
          metrics:
          - name: "labels"
            help: "Kubernetes labels converted to Prometheus labels."
            each:
              type: Info
              info:
                path: [metadata]
                labelsFromPath:
                  "*": [labels]
          - name: "created"
            help: "created timestamp"
            each:
              type: Gauge
              gauge:
                path: [metadata, creationTimestamp]
          - name: "deleted"
            help: "deletion timestamp"
            each:
              type: Gauge
              gauge:
                path: [metadata, deletionTimestamp]
          - name: "hostname_info"
            help: "Hostname information"
            each:
              type: Info
              info:
                path: [spec, hostnames]
                labelsFromPath:
                  hostname: []
          - name: "parent_info"
            help: "Parent references that the grpcroute wants to be attached to"
            each:
              type: Info
              info:
                path: [spec, parentRefs]
                labelsFromPath:
                  parent_group: ["group"]
                  parent_kind: ["kind"]
                  parent_name: ["name"]
                  parent_namespace: ["namespace"]
                  parent_section_name: ["sectionName"]
                  parent_port: ["port"]
          - name: "status_parent_info"
            help: "Parent references that the grpcroute is attached to"
            each:
              type: Info
              info:
                path: [status, parents]
                labelsFromPath:
                  controller_name: ["controllerName"]
                  parent_group: ["parentRef", "group"]
                  parent_kind: ["parentRef", "kind"]
                  parent_name: ["parentRef", "name"]
                  parent_namespace: ["parentRef", "namespace"]
                  parent_section_name: ["parentRef", "sectionName"]
                  parent_port: ["parentRef", "port"]
        - groupVersionKind:
            group: gateway.networking.k8s.io
            kind: "TCPRoute"
            version: "v1alpha2"
          metricNamePrefix: gatewayapi_tcproute
          labelsFromPath:
            name:
            - metadata
            - name
            namespace:
            - metadata
            - namespace
          metrics:
          - name: "labels"
            help: "Kubernetes labels converted to Prometheus labels."
            each:
              type: Info
              info:
                path: [metadata]
                labelsFromPath:
                  "*": [labels]
          - name: "created"
            help: "created timestamp"
            each:
              type: Gauge
              gauge:
                path: [metadata, creationTimestamp]
          - name: "deleted"
            help: "deletion timestamp"
            each:
              type: Gauge
              gauge:
                path: [metadata, deletionTimestamp]
          - name: "parent_info"
            help: "Parent references that the tcproute wants to be attached to"
            each:
              type: Info
              info:
                path: [spec, parentRefs]
                labelsFromPath:
                  parent_group: ["group"]
                  parent_kind: ["kind"]
                  parent_name: ["name"]
                  parent_namespace: ["namespace"]
                  parent_section_name: ["sectionName"]
                  parent_port: ["port"]
          - name: "status_parent_info"
            help: "Parent references that the tcproute is attached to"
            each:
              type: Info
              info:
                path: [status, parents]
                labelsFromPath:
                  controller_name: ["controllerName"]
                  parent_group: ["parentRef", "group"]
                  parent_kind: ["parentRef", "kind"]
                  parent_name: ["parentRef", "name"]
                  parent_namespace: ["parentRef", "namespace"]
                  parent_section_name: ["parentRef", "sectionName"]
                  parent_port: ["parentRef", "port"]
        - groupVersionKind:
            group: gateway.networking.k8s.io
            kind: "TLSRoute"
            version: "v1alpha2"
          metricNamePrefix: gatewayapi_tlsroute
          labelsFromPath:
            name:
            - metadata
            - name
            namespace:
            - metadata
            - namespace
          metrics:
          - name: "labels"
            help: "Kubernetes labels converted to Prometheus labels."
            each:
              type: Info
              info:
                path: [metadata]
                labelsFromPath:
                  "*": [labels]
          - name: "created"
            help: "created timestamp"
            each:
              type: Gauge
              gauge:
                path: [metadata, creationTimestamp]
          - name: "deleted"
            help: "deletion timestamp"
            each:
              type: Gauge
              gauge:
                path: [metadata, deletionTimestamp]
          - name: "hostname_info"
            help: "Hostname information"
            each:
              type: Info
              info:
                path: [spec, hostnames]
                labelsFromPath:
                  hostname: []
          - name: "parent_info"
            help: "Parent references that the tlsroute wants to be attached to"
            each:
              type: Info
              info:
                path: [spec, parentRefs]
                labelsFromPath:
                  parent_group: ["group"]
                  parent_kind: ["kind"]
                  parent_name: ["name"]
                  parent_namespace: ["namespace"]
                  parent_section_name: ["sectionName"]
                  parent_port: ["port"]
          - name: "status_parent_info"
            help: "Parent references that the tlsroute is attached to"
            each:
              type: Info
              info:
                path: [status, parents]
                labelsFromPath:
                  controller_name: ["controllerName"]
                  parent_group: ["parentRef", "group"]
                  parent_kind: ["parentRef", "kind"]
                  parent_name: ["parentRef", "name"]
                  parent_namespace: ["parentRef", "namespace"]
                  parent_section_name: ["parentRef", "sectionName"]
                  parent_port: ["parentRef", "port"]
        - groupVersionKind:
            group: gateway.networking.k8s.io
            kind: "UDPRoute"
            version: "v1alpha2"
          metricNamePrefix: gatewayapi_udproute
          labelsFromPath:
            name:
            - metadata
            - name
            namespace:
            - metadata
            - namespace
          metrics:
          - name: "labels"
            help: "Kubernetes labels converted to Prometheus labels."
            each:
              type: Info
              info:
                path: [metadata]
                labelsFromPath:
                  "*": [labels]
          - name: "created"
            help: "created timestamp"
            each:
              type: Gauge
              gauge:
                path: [metadata, creationTimestamp]
          - name: "deleted"
            help: "deletion timestamp"
            each:
              type: Gauge
              gauge:
                path: [metadata, deletionTimestamp]
          - name: "parent_info"
            help: "Parent references that the udproute wants to be attached to"
            each:
              type: Info
              info:
                path: [spec, parentRefs]
                labelsFromPath:
                  parent_group: ["group"]
                  parent_kind: ["kind"]
                  parent_name: ["name"]
                  parent_namespace: ["namespace"]
                  parent_section_name: ["sectionName"]
                  parent_port: ["port"]
          - name: "status_parent_info"
            help: "Parent references that the udproute is attached to"
            each:
              type: Info
              info:
                path: [status, parents]
                labelsFromPath:
                  controller_name: ["controllerName"]
                  parent_group: ["parentRef", "group"]
                  parent_kind: ["parentRef", "kind"]
                  parent_name: ["parentRef", "name"]
                  parent_namespace: ["parentRef", "namespace"]
                  parent_section_name: ["parentRef", "sectionName"]
                  parent_port: ["parentRef", "port"]
        - groupVersionKind:
            group: gateway.networking.k8s.io
            kind: "BackendTLSPolicy"
            version: "v1alpha2"
          metricNamePrefix: gatewayapi_backendtlspolicy
          labelsFromPath:
            name:
            - metadata
            - name
            namespace:
            - metadata
            - namespace
          metrics:
          - name: "labels"
            help: "Kubernetes labels converted to Prometheus labels."
            each:
              type: Info
              info:
                path: [metadata]
                labelsFromPath:
                  "*": [labels]
          - name: "created"
            help: "created timestamp"
            each:
              type: Gauge
              gauge:
                path: [metadata, creationTimestamp]
          - name: "deleted"
            help: "deletion timestamp"
            each:
              type: Gauge
              gauge:
                path: [metadata, deletionTimestamp]
          - name: "target_info"
            help: "Target references that the backendtlspolicy wants to be attached to"
            each:
              type: Info
              info:
                path: [spec, targetRef]
                labelsFromPath:
                  target_group: ["group"]
                  target_kind: ["kind"]
                  target_name: ["name"]
                  target_namespace: ["namespace"]
        - groupVersionKind:
            group: kuadrant.io
            kind: "TLSPolicy"
            version: "v1"
          metricNamePrefix: gatewayapi_tlspolicy
          labelsFromPath:
            name:
            - metadata
            - name
            namespace:
            - metadata
            - namespace
          metrics:
          - name: "labels"
            help: "Kubernetes labels converted to Prometheus labels."
            each:
              type: Info
              info:
                path: [metadata]
                labelsFromPath:
                  "*": [labels]
          - name: "created"
            help: "created timestamp"
            each:
              type: Gauge
              gauge:
                path: [metadata, creationTimestamp]
          - name: "deleted"
            help: "deletion timestamp"
            each:
              type: Gauge
              gauge:
                path: [metadata, deletionTimestamp]
          - name: "target_info"
            help: "Target references that the tlspolicy wants to be attached to"
            each:
              type: Info
              info:
                path: [spec, targetRef]
                labelsFromPath:
                  target_group: ["group"]
                  target_kind: ["kind"]
                  target_name: ["name"]
                  target_namespace: ["namespace"]
          - name: "status"
            help: "status condition"
            each:
              type: Gauge
              gauge:
                path: [status, conditions]
                labelsFromPath:
                  type: ["type"]
                valueFrom: ["status"]
        - groupVersionKind:
            group: kuadrant.io
            kind: "DNSPolicy"
            version: "v1"
          metricNamePrefix: gatewayapi_dnspolicy
          labelsFromPath:
            name:
            - metadata
            - name
            namespace:
            - metadata
            - namespace
          metrics:
          - name: "labels"
            help: "Kubernetes labels converted to Prometheus labels."
            each:
              type: Info
              info:
                path: [metadata]
                labelsFromPath:
                  "*": [labels]
          - name: "created"
            help: "created timestamp"
            each:
              type: Gauge
              gauge:
                path: [metadata, creationTimestamp]
          - name: "deleted"
            help: "deletion timestamp"
            each:
              type: Gauge
              gauge:
                path: [metadata, deletionTimestamp]
          - name: "target_info"
            help: "Target references that the dnspolicy wants to be attached to"
            each:
              type: Info
              info:
                path: [spec, targetRef]
                labelsFromPath:
                  target_group: ["group"]
                  target_kind: ["kind"]
                  target_name: ["name"]
                  target_namespace: ["namespace"]
          - name: "status"
            help: "status condition"
            each:
              type: Gauge
              gauge:
                path: [status, conditions]
                labelsFromPath:
                  type: ["type"]
                valueFrom: ["status"]
        - groupVersionKind:
            group: kuadrant.io
            kind: "RateLimitPolicy"
            version: "v1"
          metricNamePrefix: gatewayapi_ratelimitpolicy
          labelsFromPath:
            name:
            - metadata
            - name
            namespace:
            - metadata
            - namespace
          metrics:
          - name: "labels"
            help: "Kubernetes labels converted to Prometheus labels."
            each:
              type: Info
              info:
                path: [metadata]
                labelsFromPath:
                  "*": [labels]
          - name: "created"
            help: "created timestamp"
            each:
              type: Gauge
              gauge:
                path: [metadata, creationTimestamp]
          - name: "deleted"
            help: "deletion timestamp"
            each:
              type: Gauge
              gauge:
                path: [metadata, deletionTimestamp]
          - name: "target_info"
            help: "Target references that the tlspolicy wants to be attached to"
            each:
              type: Info
              info:
                path: [spec, targetRef]
                labelsFromPath:
                  target_group: ["group"]
                  target_kind: ["kind"]
                  target_name: ["name"]
                  target_namespace: ["namespace"]
          - name: "status"
            help: "status condition"
            each:
              type: Gauge
              gauge:
                path: [status, conditions]
                labelsFromPath:
                  type: ["type"]
                valueFrom: ["status"]
        - groupVersionKind:
            group: kuadrant.io
            kind: "AuthPolicy"
            version: "v1"
          metricNamePrefix: gatewayapi_authpolicy
          labelsFromPath:
            name:
            - metadata
            - name
            namespace:
            - metadata
            - namespace
          metrics:
          - name: "labels"
            help: "Kubernetes labels converted to Prometheus labels."
            each:
              type: Info
              info:
                path: [metadata]
                labelsFromPath:
                  "*": [labels]
          - name: "created"
            help: "created timestamp"
            each:
              type: Gauge
              gauge:
                path: [metadata, creationTimestamp]
          - name: "deleted"
            help: "deletion timestamp"
            each:
              type: Gauge
              gauge:
                path: [metadata, deletionTimestamp]
          - name: "target_info"
            help: "Target references that the authpolicy wants to be attached to"
            each:
              type: Info
              info:
                path: [spec, targetRef]
                labelsFromPath:
                  target_group: ["group"]
                  target_kind: ["kind"]
                  target_name: ["name"]
                  target_namespace: ["namespace"]
          - name: "status"
            help: "status condition"
            each:
              type: Gauge
              gauge:
                path: [status, conditions]
                labelsFromPath:
                  type: ["type"]
                valueFrom: ["status"]
        - groupVersionKind:
            group: kuadrant.io
            kind: "DNSRecord"
            version: "v1alpha1"
          metricNamePrefix: kuadrant_dnsrecord
          labelsFromPath:
            name:
            - metadata
            - name
            namespace:
            - metadata
            - namespace
            rootDomain:
            - spec
            - rootHost
          metrics:
          - name: "created"
            help: "created timestamp"
            each:
              type: Gauge
              gauge:
                path: [metadata, creationTimestamp]
          - name: "status_root_domain_owners"
            help: "root domain owners (the ids of controllers managing this root domain)"
            each:
              type: Info
              info:
                path: [status, domainOwners]
                labelsFromPath:
                  owner: []
          - name: "status"
            help: "status condition"
            each:
              type: Gauge
              gauge:
                path: [status, conditions]
                labelsFromPath:
                  type: ["type"]
                valueFrom: ["status"]
        - groupVersionKind:
            group: kuadrant.io
            kind: "DNSHealthCheckProbe"
            version: "v1alpha1"
          metricNamePrefix: kuadrant_dnshealthcheckprobe
          labelsFromPath:
            name:
            - metadata
            - name
            namespace:
            - metadata
            - namespace
          metrics:
          - name: "healthy_status"
            help: "DNS Probe current status"
            each:
              type: Gauge
              gauge:
                path: [status, healthy]
kind: ConfigMap
metadata:
  name: custom-resource-state
  namespace: connlink
---
apiVersion: v1
kind: Service
metadata:
  labels:
    app.kubernetes.io/component: exporter
    app.kubernetes.io/name: kube-state-metrics-kuadrant
    app.kubernetes.io/part-of: kuadrant
    app.kubernetes.io/version: 2.5.0
  name: kube-state-metrics-kuadrant
  namespace: connlink
spec:
  clusterIP: None
  ports:
  - name: https-main
    port: 8081
    targetPort: https-main
  - name: https-self
    port: 8082
    targetPort: https-self
  selector:
    app.kubernetes.io/component: exporter
    app.kubernetes.io/name: kube-state-metrics-kuadrant
    app.kubernetes.io/part-of: kuadrant
---
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app.kubernetes.io/component: exporter
    app.kubernetes.io/name: kube-state-metrics-kuadrant
    app.kubernetes.io/part-of: kuadrant
    app.kubernetes.io/version: 2.5.0
  name: kube-state-metrics-kuadrant
  namespace: connlink
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/component: exporter
      app.kubernetes.io/name: kube-state-metrics-kuadrant
      app.kubernetes.io/part-of: kuadrant
  template:
    metadata:
      annotations:
        kubectl.kubernetes.io/default-container: kube-state-metrics
      labels:
        app.kubernetes.io/component: exporter
        app.kubernetes.io/name: kube-state-metrics-kuadrant
        app.kubernetes.io/part-of: kuadrant
        app.kubernetes.io/version: 2.5.0
    spec:
      automountServiceAccountToken: true
      containers:
      - args:
        - --port=8081
        - --telemetry-port=8082
        - --custom-resource-state-config-file
        - /custom-resource-state/custom-resource-state.yaml
        image: registry.redhat.io/openshift4/ose-kube-state-metrics-rhel9:latest
        name: kube-state-metrics
        ports:
        - containerPort: 8081
          name: https-main
        - containerPort: 8082
          name: https-self
        resources:
          limits:
            cpu: 100m
            memory: 250Mi
          requests:
            cpu: 10m
            memory: 190Mi
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop:
            - ALL
          readOnlyRootFilesystem: true
        volumeMounts:
        - mountPath: /custom-resource-state
          name: custom-resource-state
      nodeSelector:
        kubernetes.io/os: linux
      serviceAccountName: kube-state-metrics-kuadrant
      volumes:
      - configMap:
          defaultMode: 420
          name: custom-resource-state
        name: custom-resource-state
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  labels:
    app.kubernetes.io/component: exporter
    app.kubernetes.io/name: kube-state-metrics-kuadrant
    app.kubernetes.io/part-of: kuadrant
    app.kubernetes.io/version: 2.5.0
  name: kube-state-metrics-kuadrant
  namespace: connlink
spec:
  endpoints:
  - honorLabels: true
    interval: 30s
    port: https-main
    relabelings:
    - action: labeldrop
      regex: (pod|service|endpoint|namespace)
    scheme: http
    scrapeTimeout: 30s
  - interval: 30s
    port: https-self
    scheme: http
  jobLabel: app.kubernetes.io/name
  selector:
    matchLabels:
      app.kubernetes.io/component: exporter
      app.kubernetes.io/name: kube-state-metrics-kuadrant
      app.kubernetes.io/part-of: kuadrant

---
## MAGIA MIA 
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kube-state-metrics-kuadrant-crd-binding
subjects:
- kind: ServiceAccount
  name: kube-state-metrics-kuadrant
  namespace: connlink
roleRef:
  kind: ClusterRole
  name: kube-state-metrics-crd-reader
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kube-state-metrics-kuadrant-full
rules:
  - apiGroups: [""]
    resources:
      - configmaps
      - endpoints
      - events
      - limitranges
      - namespaces
      - nodes
      - persistentvolumeclaims
      - persistentvolumes
      - pods
      - replicationcontrollers
      - resourcequotas
      - secrets
      - services
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources:
      - daemonsets
      - deployments
      - replicasets
      - statefulsets
    verbs: ["get", "list", "watch"]
  - apiGroups: ["batch"]
    resources:
      - cronjobs
      - jobs
    verbs: ["get", "list", "watch"]
  - apiGroups: ["networking.k8s.io"]
    resources:
      - ingresses
      - networkpolicies
    verbs: ["get", "list", "watch"]
  - apiGroups: ["gateway.networking.k8s.io"]
    resources: ["*"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["kuadrant.io"]
    resources: ["*"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["autoscaling"]
    resources:
      - horizontalpodautoscalers
    verbs: ["get", "list", "watch"]
  - apiGroups: ["policy"]
    resources:
      - poddisruptionbudgets
    verbs: ["get", "list", "watch"]
  - apiGroups: ["admissionregistration.k8s.io"]
    resources:
      - mutatingwebhookconfigurations
      - validatingwebhookconfigurations
    verbs: ["get", "list", "watch"]
  - apiGroups: ["certificates.k8s.io"]
    resources:
      - certificatesigningrequests
    verbs: ["get", "list", "watch"]
  - apiGroups: ["coordination.k8s.io"]
    resources:
      - leases
    verbs: ["get", "list", "watch"]
  - apiGroups: ["storage.k8s.io"]
    resources:
      - storageclasses
      - volumeattachments
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kube-state-metrics-kuadrant-full-binding
subjects:
  - kind: ServiceAccount
    name: kube-state-metrics-kuadrant
    namespace: connlink
roleRef:
  kind: ClusterRole
  name: kube-state-metrics-kuadrant-full
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: gw-proxy-uwm
  namespace: connlink
spec:
  selector:
    matchLabels:
      gateway.networking.k8s.io/gateway-name: gw-one
  podMetricsEndpoints:
  - port: http-envoy-prom
    path: /stats/prometheus
YAML

# Asegurar el directorio de trabajo
mkdir -p /tmp/instalacion 2>/dev/null || true
cd /tmp/instalacion 2>/dev/null || true

cat <<EOF > kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - https://github.com/Kuadrant/kuadrant-operator/examples/dashboards?ref=v1.4.1
namespace: connlink
EOF

oc apply -k .

cat << 'YAML' | oc apply -f -
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: grafana-app-developer
  namespace: connlink
spec:
  allowCrossNamespaceImport: false
  configMapRef:
    key: app_developer.json
    name: grafana-app-developer
  instanceSelector:
    matchLabels:
      dashboards: grafana-cl
---
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: grafana-business-user
  namespace: connlink
spec:
  allowCrossNamespaceImport: false
  configMapRef:
    key: business_user.json
    name: grafana-business-user
  instanceSelector:
    matchLabels:
      dashboards: grafana-cl
---
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: grafana-controller-resources-metrics
  namespace: connlink
spec:
  allowCrossNamespaceImport: false
  configMapRef:
    key: controller-resources-metrics.json
    name: grafana-controller-resources-metrics
  instanceSelector:
    matchLabels:
      dashboards: grafana-cl
---
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: grafana-controller-runtime-metrics
  namespace: connlink
spec:
  allowCrossNamespaceImport: false
  configMapRef:
    key: controller-runtime-metrics.json
    name: grafana-controller-runtime-metrics
  instanceSelector:
    matchLabels:
      dashboards: grafana-cl
---
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: grafana-dns-operator
  namespace: connlink
spec:
  allowCrossNamespaceImport: false
  configMapRef:
    key: dns-operator.json
    name: grafana-dns-operator
  instanceSelector:
    matchLabels:
      dashboards: grafana-cl
---
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:            - '--custom-resource-state-only=true'
  name: grafana-platform-engineer
  namespace: connlink
spec:
  allowCrossNamespaceImport: false
  configMapRef:
    key: platform_engineer.json
    name: grafana-platform-engineer
  instanceSelector:
    matchLabels:
      dashboards: grafana-cl
YAML

echo "=== Esperando creación del Deployment del Gateway por el Operador ==="
until oc get deployment/gw-one-openshift-default -n connlink &>/dev/null; do
  echo "Esperando a deployment/gw-one-openshift-default..."
  sleep 5
done

oc patch deployment/gw-one-openshift-default -n connlink --type=json -p '[{"op": "remove", "path": "/spec/template/spec/containers/0/resources/limits"}]'
oc patch deployment/gw-one-openshift-default -n connlink --type=merge -p '{"spec":{"template":{"metadata":{"annotations":{"sidecar.istio.io/statsInclusionRegexps":".*upstream_rq_time.*|.*downstream_cx_active.*"}}}}}'
oc rollout restart deployment/gw-one-openshift-default -n connlink

## Este patch hace que no se dupliquen las metricas pero deja de funcionar el segundo dashboard de CL oficial
oc patch deployment kube-state-metrics-kuadrant -n connlink --type='json' -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--custom-resource-state-only=true"}]'
oc rollout restart deployment/kube-state-metrics-kuadrant -n connlink

echo "=== Esperando a que el pod complete su reinicio y esté en Running ==="
oc rollout status deployment/gw-one-openshift-default -n connlink --timeout=120s

oc exec -n connlink deployment/gw-one-openshift-default -c istio-proxy -- pilot-agent request GET /stats/prometheus | grep "upstream_rq_time"
