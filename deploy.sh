#!/usr/bin/env bash
# ------------------------------------------------------------
# 2SCloud private cloud — bootstrap script
#
# Deploys all platform components in dependency order:
#   1. scloud-observability  (Alloy, Prometheus, Grafana, Loki, Tempo)
#   2. scloud-dns            (internal DNS + CoreDNS stub zone)
#   3. scloud-edge-gateway   (single external entrypoint + WAF)
#   4. scloud-compute        (platform workloads)
#
# Prerequisites:
#   - kubectl configured and pointing at the target cluster
#   - A default StorageClass provisioner available for PVCs
#   - Sufficient cluster resources (see governance/ quotas per namespace)
#
# Usage:
#   ./deploy.sh
# ------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { echo "[scloud] $*"; }
step() { echo; echo "──────────────────────────────────────────────"; echo "[scloud] $*"; echo "──────────────────────────────────────────────"; }

# ── 1. scloud-observability ───────────────────────────────────────────────────
step "1/4  Deploying scloud-observability"

kubectl apply -f "$REPO_ROOT/observability/namespace.yaml"

# ClusterRoles must exist before bindings in the same namespace
kubectl apply -f "$REPO_ROOT/observability/rbac/clusterrole.yaml"
kubectl apply -f "$REPO_ROOT/observability/rbac/clusterrolebinding.yaml"
kubectl apply -f "$REPO_ROOT/observability/rbac/serviceaccount.yaml"

kubectl apply -f "$REPO_ROOT/observability/governance/"
kubectl apply -f "$REPO_ROOT/observability/network/"
kubectl apply -f "$REPO_ROOT/observability/storage/"

# Start backend stores first so Alloy has somewhere to write on startup
kubectl apply -f "$REPO_ROOT/observability/workloads/loki/"
kubectl apply -f "$REPO_ROOT/observability/workloads/tempo/"
kubectl apply -f "$REPO_ROOT/observability/workloads/prometheus/"
kubectl apply -f "$REPO_ROOT/observability/workloads/grafana/"
kubectl apply -f "$REPO_ROOT/observability/workloads/alloy/"

log "Waiting for Alloy to be ready (scloud-dns OTEL export depends on it)..."
kubectl rollout status deployment/alloy -n scloud-observability --timeout=180s

# ── 2. scloud-dns ─────────────────────────────────────────────────────────────
step "2/4  Deploying scloud-dns"

kubectl apply -f "$REPO_ROOT/dns/namespace.yaml"
kubectl apply -f "$REPO_ROOT/dns/rbac/"
kubectl apply -f "$REPO_ROOT/dns/network/"
kubectl apply -f "$REPO_ROOT/dns/config/"
kubectl apply -f "$REPO_ROOT/dns/workloads/"

log "Waiting for scloud-dns to be ready..."
kubectl rollout status deployment/scloud-dns -n scloud-dns --timeout=120s

log "Patching CoreDNS with scloud.internal stub zone..."
kubectl apply -f "$REPO_ROOT/dns/coredns/coredns-patch.yaml"
kubectl rollout restart deployment/coredns -n kube-system
kubectl rollout status  deployment/coredns -n kube-system --timeout=60s

# ── 3. scloud-edge-gateway ────────────────────────────────────────────────────
step "3/4  Deploying scloud-edge-gateway"

kubectl apply -f "$REPO_ROOT/gateway/namespace.yaml"
kubectl apply -f "$REPO_ROOT/gateway/rbac/"
kubectl apply -f "$REPO_ROOT/gateway/governance/"
kubectl apply -f "$REPO_ROOT/gateway/config/"
kubectl apply -f "$REPO_ROOT/gateway/workloads/"

log "Waiting for edge-gateway to be ready..."
kubectl rollout status deployment/edge-gateway -n scloud-gateway --timeout=180s

# ── 4. scloud-compute (platform) ──────────────────────────────────────────────
step "4/4  Deploying scloud-compute platform"

kubectl apply -f "$REPO_ROOT/platform/namespace.yaml"
kubectl apply -f "$REPO_ROOT/platform/rbac/"
kubectl apply -f "$REPO_ROOT/platform/governance/"
kubectl apply -f "$REPO_ROOT/platform/network/"
kubectl apply -f "$REPO_ROOT/platform/workloads/"

log "Waiting for platform workloads to be ready..."
kubectl rollout status deployment/nginx -n scloud-compute --timeout=120s

# ── Done ──────────────────────────────────────────────────────────────────────
step "2SCloud private cloud bootstrap complete"
echo
echo "  Grafana      →  http://grafana.scloud.internal:3000  (admin / scloud-change-me)"
echo "  Prometheus   →  http://prometheus.scloud.internal:9090"
echo "  Gateway      →  http://gateway.scloud.internal"
echo "  DNS          →  scloud-dns.scloud-dns.svc:53"
echo
echo "  IMPORTANT: Change the Grafana admin password before exposing to users."
echo "             See observability/workloads/grafana/deployment.yaml → GF_SECURITY_ADMIN_PASSWORD"
echo
