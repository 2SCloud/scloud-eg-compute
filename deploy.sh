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
#   - docker available for building images
#   - sudo access for k3s ctr image import
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

# ── Submodules ────────────────────────────────────────────────────────────────
log "Initializing submodules..."
git -C "$REPO_ROOT" submodule update --init --recursive

# ── Build & load images ───────────────────────────────────────────────────────
step "0/4  Building images"

EG_REPO="$REPO_ROOT/.."

log "Building 2scloud/edge-gateway:latest..."
docker build -t 2scloud/edge-gateway:latest "$EG_REPO"

log "Loading edge-gateway image into k3s..."
docker save 2scloud/edge-gateway:latest | sudo k3s ctr images import -

log "Building 2scloud/frontend:latest..."
docker build -t 2scloud/frontend:latest "$EG_REPO/frontend"

log "Loading frontend image into k3s..."
docker save 2scloud/frontend:latest | sudo k3s ctr images import -

# ── 0. Platform PKI (cert-manager must already be installed) ─────────────────
step "0/4  Deploying platform PKI"

log "Applying PKI bootstrap issuer + root CA + internal CA issuer..."
kubectl apply -f "$REPO_ROOT/platform/pki/"

log "Waiting for scloud-internal-root-ca certificate to be issued..."
kubectl wait --for=condition=Ready certificate/scloud-internal-root-ca \
  -n cert-manager --timeout=120s

log "Waiting for scloud-internal-ca ClusterIssuer to be ready..."
kubectl wait --for=condition=Ready clusterissuer/scloud-internal-ca --timeout=60s

# ── 1. scloud-observability ───────────────────────────────────────────────────
# Skip with: SKIP_OBSERVABILITY=1 ./deploy.sh
# The rest of the stack (dns, gateway, frontend, compute) runs fine
# without it. scloud-dns ships OTEL traces to alloy.scloud-observability
# via fire-and-forget HTTP — when alloy is missing it logs a warning
# per export and keeps serving DNS normally. Use this flag on memory-
# constrained hosts (under ~6 GiB RAM) where Mimir/Loki/Tempo cause
# OOM / crashloop storms.
if [[ "${SKIP_OBSERVABILITY:-0}" == "1" ]]; then
  step "1/4  Skipping scloud-observability (SKIP_OBSERVABILITY=1)"
  log "Observability stack not deployed. Other components will still run."
else
  step "1/4  Deploying scloud-observability"

  (cd "$REPO_ROOT/observability-stack" && bash deploy-scloud-observability.sh)

  log "Applying observability RBAC..."
  kubectl apply -f "$REPO_ROOT/observability/rbac/clusterrole.yaml"
  kubectl apply -f "$REPO_ROOT/observability/rbac/clusterrolebinding.yaml"
  kubectl apply -f "$REPO_ROOT/observability/rbac/serviceaccount.yaml"

  log "Applying observability governance..."
  kubectl apply -f "$REPO_ROOT/observability/governance/"

  log "Applying observability storage..."
  kubectl apply -f "$REPO_ROOT/observability/storage/"

  log "Deploying Mimir (monolithic)..."
  kubectl apply -f "$REPO_ROOT/observability/workloads/mimir/"

  log "Applying observability network policies..."
  kubectl apply -f "$REPO_ROOT/observability/network/netpol.yaml"
fi

# ── 2. scloud-dns ─────────────────────────────────────────────────────────────
step "2/4  Deploying scloud-dns"

kubectl apply -f "$REPO_ROOT/dns/namespace.yaml"

log "Applying scloud-dns RBAC..."
kubectl apply -f "$REPO_ROOT/dns/rbac/"

log "Applying scloud-dns network policies..."
kubectl apply -f "$REPO_ROOT/dns/network/"

log "Applying scloud-dns configuration..."
kubectl apply -f "$REPO_ROOT/dns/config/"

log "Applying scloud-dns workloads..."
kubectl apply -f "$REPO_ROOT/dns/workloads/"

log "Patching CoreDNS with scloud.internal stub zone..."
SCLOUD_DNS_IP=$(kubectl get svc scloud-dns -n scloud-dns -o jsonpath='{.spec.clusterIP}')
sed "s|scloud-dns.scloud-dns.svc.cluster.local:53|${SCLOUD_DNS_IP}:53|g" \
  "$REPO_ROOT/dns/coredns/coredns-patch.yaml" | kubectl apply -f -
log "CoreDNS will hot-reload the stub zone via the reload plugin (~30s)"

# ── 3. scloud-edge-gateway ────────────────────────────────────────────────────
step "3/4  Deploying scloud-edge-gateway"

kubectl apply -f "$REPO_ROOT/gateway/namespace.yaml"

log "Applying scloud-edge-gateway RBAC..."
kubectl apply -f "$REPO_ROOT/gateway/rbac/"

log "Applying scloud-edge-gateway governance..."
kubectl apply -f "$REPO_ROOT/gateway/governance/"

log "Applying scloud-edge-gateway configuration..."
kubectl apply -f "$REPO_ROOT/gateway/config/"

log "Waiting for edge-gateway TLS certificate to be issued..."
kubectl wait --for=condition=Ready certificate/edge-gateway-tls \
  -n scloud-gateway --timeout=120s

log "Applying scloud-edge-gateway workloads..."
kubectl apply -f "$REPO_ROOT/gateway/workloads/"

log "edge-gateway deployed (requires local image build before it becomes Ready)"

# ── 4. scloud-compute (platform) ──────────────────────────────────────────────
step "4/4  Deploying scloud-compute platform"

kubectl apply -f "$REPO_ROOT/platform/namespace.yaml"

log "Applying scloud-compute RBAC..."
kubectl apply -f "$REPO_ROOT/platform/rbac/"

log "Applying scloud-compute governance..."
kubectl apply -f "$REPO_ROOT/platform/governance/"

log "Applying scloud-compute network policies..."
kubectl apply -f "$REPO_ROOT/platform/network/"

log "Applying scloud-compute workloads..."
kubectl apply -f "$REPO_ROOT/platform/workloads/"

log "Waiting for platform workloads to be ready..."
kubectl rollout status deployment/nginx-deployment -n scloud-compute --timeout=120s

# ── 5. scloud-frontend (admin UI) ────────────────────────────────────────────
step "5/5  Deploying scloud-frontend"

kubectl apply -f "$REPO_ROOT/frontend/namespace.yaml"

log "Applying scloud-frontend configuration..."
kubectl apply -f "$REPO_ROOT/frontend/config/"

log "Applying scloud-frontend network policies..."
kubectl apply -f "$REPO_ROOT/frontend/network/"

log "Applying scloud-frontend workloads..."
kubectl apply -f "$REPO_ROOT/frontend/workloads/"

log "Waiting for frontend to be ready..."
kubectl rollout status deployment/scloud-frontend -n scloud-frontend --timeout=120s

# ── Done ──────────────────────────────────────────────────────────────────────
step "2SCloud private cloud bootstrap complete"
echo
echo "  Grafana      →  http://grafana.scloud.internal:3000  (admin / scloud-change-me)"
echo "  Prometheus   →  http://prometheus.scloud.internal:9090"
echo "  Gateway HTTP →  http://gateway.scloud.internal:30080"
echo "  Gateway TLS  →  https://gateway.scloud.internal:30443   (DoH /dns-query)"
echo "  Frontend     →  kubectl port-forward -n scloud-frontend svc/scloud-frontend 3000:80"
echo "                  then open http://localhost:3000  (admin / admin)"
echo "  Admin API    →  kubectl port-forward -n scloud-gateway  svc/edge-gateway-admin 9090:9090"
echo "  DNS          →  scloud-dns.scloud-dns.svc:53"
echo
echo "  IMPORTANT: Change the Grafana admin password before exposing to users."
echo "             See observability/workloads/grafana/deployment.yaml → GF_SECURITY_ADMIN_PASSWORD"
echo
