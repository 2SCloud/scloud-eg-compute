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
#   Grafana    →  http://grafana.scloud.internal:3000
#   Gateway    →  http://gateway.scloud.internal:30080
# ------------------------------------------------------------

log() { echo "[scloud] $*"; }

log "Starting port-forwards..."

kubectl port-forward --address 0.0.0.0 svc/grafana      -n scloud-observability 3000:80   &
kubectl port-forward --address 0.0.0.0 svc/edge-gateway -n scloud-gateway        30080:80  &

log "Done. Press Ctrl+C to stop all forwards."
wait
