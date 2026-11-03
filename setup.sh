#!/usr/bin/env bash
# One kind cluster for the whole demo:
#   argocd, kargo, cert-manager (Kargo's own dependency), flux-system
#   vc-test, vc-prod-eu, vc-prod-us   one vcluster each, standing in for a cluster
# Re-runnable: every step is an install-or-upgrade.
set -euo pipefail
cd "$(dirname "$0")"

CLUSTER_NAME=${CLUSTER_NAME:-kargo-argo-flux}
ARGOCD_CHART_VERSION=${ARGOCD_CHART_VERSION:-10.11.6}
KARGO_CHART_VERSION=${KARGO_CHART_VERSION:-1.12.5}
CERT_MANAGER_CHART_VERSION=${CERT_MANAGER_CHART_VERSION:-v1.21.3}
VCLUSTER_CHART_VERSION=${VCLUSTER_CHART_VERSION:-0.37.6}
STAGES=(test prod-eu prod-us)

step() { printf '\n==> %s\n' "$*"; }

step "kind cluster ${CLUSTER_NAME}"
kind get clusters | grep -qx "$CLUSTER_NAME" || kind create cluster --name "$CLUSTER_NAME" --wait 120s
kubectl config use-context "kind-${CLUSTER_NAME}"

step "cert-manager (required by Kargo; unrelated to the demo's cert-manager)"
helm upgrade --install cert-manager cert-manager --repo https://charts.jetstack.io \
  --version "$CERT_MANAGER_CHART_VERSION" -n cert-manager --create-namespace \
  --set crds.enabled=true --wait

step "Argo CD"
helm upgrade --install argocd argo-cd --repo https://argoproj.github.io/argo-helm \
  --version "$ARGOCD_CHART_VERSION" -n argocd --create-namespace --wait

step "Kargo (admin password: admin)"
helm upgrade --install kargo oci://ghcr.io/akuity/kargo-charts/kargo \
  --version "$KARGO_CHART_VERSION" -n kargo --create-namespace \
  --set api.adminAccount.passwordHash='$2a$10$Zrhhie4vLz5ygtVSaif6o.qN36jgs6vjtMBdM6yrU1FOeiAAMMxOm' \
  --set api.adminAccount.tokenSigningKey=iwishtowashmyirishwristwatch \
  --wait

step "Flux, only the controllers this lane needs"
# Flux's default NetworkPolicies break DNS for its controllers under kind's
# kindnet, so leave them out on this local cluster.
flux install --components=source-controller,helm-controller --network-policy=false

for stage in "${STAGES[@]}"; do
  step "vcluster for ${stage} (namespace vc-${stage})"
  helm upgrade --install vcluster vcluster --repo https://charts.loft.sh \
    --version "$VCLUSTER_CHART_VERSION" -n "vc-${stage}" --create-namespace \
    -f cluster/vcluster-values.yaml \
    --set exportKubeConfig.server="https://vcluster.vc-${stage}:443" \
    --wait
done

step "Kargo project, warehouse, stages; Argo CD ApplicationSet"
kubectl apply -f kargo/project.yaml
until kubectl get namespace kargo-argo-flux >/dev/null 2>&1; do sleep 2; done # Kargo creates it
kubectl apply -f kargo/
kubectl apply -f argocd/addons-appset.yaml

if grep -rq emilyxinyi argocd/ kargo/; then
  printf '\nNote: emilyxinyi is still in argocd/ and kargo/. Point those at your fork and re-run.\n'
fi

cat <<'MSG'

Done. UIs:
  Argo CD  kubectl -n argocd port-forward svc/argocd-server 8080:443   -> https://localhost:8080
           admin / $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
  Kargo    kubectl -n kargo port-forward svc/kargo-api 8081:443        -> https://localhost:8081
           admin / admin
MSG
