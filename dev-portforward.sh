#!/usr/bin/env bash
# ------------------------------------------------------------
# 2SCloud — dev port-forwards
#
# Exposes the stack to Windows via WSL2.
# Run this once after starting WSL2 to access the cloud from Edge.
#
# Usage:
#   ./portforward.sh
#
# Access:
#   Frontend     →  http://localhost:3000     (admin UI — login admin / admin)
#   Grafana      →  http://localhost:3001
#   Gateway HTTP →  http://localhost:30080
#   Gateway TLS  →  https://localhost:30443   (DoH endpoint /dns-query)
#   Admin API    →  http://localhost:9090     (consumed by the frontend)
#
# For TLS-validated requests, extract the internal root CA with:
#   kubectl get secret scloud-internal-root-ca -n cert-manager \
#     -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/scloud-ca.crt
# Then: curl --cacert /tmp/scloud-ca.crt --resolve gateway.scloud.internal:30443:127.0.0.1 ...
# ------------------------------------------------------------

log() { echo "[scloud] $*"; }

log "Starting port-forwards..."

kubectl port-forward --address 0.0.0.0 svc/grafana            -n scloud-observability 3001:80   &
kubectl port-forward --address 0.0.0.0 svc/edge-gateway       -n scloud-gateway        30080:80  &
kubectl port-forward --address 0.0.0.0 svc/edge-gateway       -n scloud-gateway        30443:443 &
kubectl port-forward --address 0.0.0.0 svc/edge-gateway-admin -n scloud-gateway        9090:9090 &
kubectl port-forward --address 0.0.0.0 svc/scloud-frontend    -n scloud-frontend       3000:80   &

log "Done. Press Ctrl+C to stop all forwards."
wait
