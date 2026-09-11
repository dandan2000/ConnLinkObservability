cat << 'EOF' > test-traffic.sh
#!/bin/bash

ENDPOINT="http://localhost:8080"
HOST="Host: echoserver.example.com"

echo "Iniciando Port-Forward..."
oc port-forward svc/gw-one-openshift-default 8080:80 -n connlink &
PF_PID=$!

trap "kill $PF_PID" EXIT
sleep 2

echo "Generando tráfico en $ENDPOINT..."
while true; do
  curl -s -o /dev/null -w "200 -> %{http_code}\n" -H "$HOST" "$ENDPOINT/"
  curl -s -o /dev/null -w "404 -> %{http_code}\n" -H "$HOST" "$ENDPOINT/not-found-$(date +%s)"
  curl -s -o /dev/null -w "500 -> %{http_code}\n" -H "$HOST" "$ENDPOINT/status/500"
  sleep 0.2
done
EOF

chmod +x test-traffic.sh