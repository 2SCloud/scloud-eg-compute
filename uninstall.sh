#!/usr/bin/env bash
# ------------------------------------------------------------
# 2SCloud private cloud — uninstall script
#
# Removes all scloud namespaces and their resources.
# Also cleans up stale webhooks and the CoreDNS stub zone patch.
#
# Usage:
#   ./uninstall.sh
# ------------------------------------------------------------
set -euo pipefail

log()  { echo "[scloud] $*"; }
step() { echo; echo "──────────────────────────────────────────────"; echo "[scloud] $*"; echo "──────────────────────────────────────────────"; }

step "Uninstalling 2SCloud private cloud"

# ── Helm releases ─────────────────────────────────────────────────────────────
log "Uninstalling Helm releases..."
helm uninstall loki    -n scloud-observability 2>/dev/null || true
helm uninstall tempo   -n scloud-observability 2>/dev/null || true
helm uninstall alloy   -n scloud-observability 2>/dev/null || true
helm uninstall grafana -n scloud-observability 2>/dev/null || true
helm uninstall mimir   -n scloud-observability 2>/dev/null || true

# ── Stale webhooks ────────────────────────────────────────────────────────────
log "Removing stale webhooks..."
kubectl delete validatingwebhookconfiguration prepare-downscale-scloud-observability.grafana.com 2>/dev/null || true
kubectl delete mutatingwebhookconfiguration   prepare-downscale-scloud-observability.grafana.com 2>/dev/null || true

# ── Namespaces ────────────────────────────────────────────────────────────────
log "Deleting scloud namespaces..."
for ns in scloud-observability scloud-dns scloud-gateway scloud-frontend scloud-compute; do
    kubectl delete namespace "$ns" --ignore-not-found
done

# ── CoreDNS patch ─────────────────────────────────────────────────────────────
log "Restoring CoreDNS to default config..."
kubectl patch configmap coredns -n kube-system --type merge -p '{"data":{"Corefile":".:53 {\n    errors\n    health {\n        lameduck 5s\n    }\n    ready\n    kubernetes cluster.local in-addr.arpa ip6.arpa {\n        pods insecure\n        fallthrough in-addr.arpa ip6.arpa\n        ttl 30\n    }\n    prometheus :9153\n    forward . /etc/resolv.conf {\n        max_concurrent 1000\n    }\n    cache 30\n    loop\n    reload\n    loadbalance\n}\n"}}'
kubectl rollout restart deployment/coredns -n kube-system || true

step "Uninstall complete"
