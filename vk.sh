#!/usr/bin/env bash
# kubectl against one stage's vcluster, with no vcluster CLI needed.
#   ./vk.sh test get pods -A
#   ./vk.sh prod-eu -n cert-manager scale deploy cert-manager --replicas=0
set -euo pipefail

stage=${1:?usage: ./vk.sh <test|prod-eu|prod-us> <kubectl args...>}
shift
ns="vc-${stage}"
port=$((20000 + RANDOM % 10000))
kubeconfig=$(mktemp)

kubectl -n "$ns" port-forward svc/vcluster "${port}:443" >/dev/null 2>&1 &
pf=$!
disown
trap 'kill $pf 2>/dev/null; rm -f "$kubeconfig"' EXIT

# Same kubeconfig Flux uses, pointed at the local port-forward instead.
kubectl -n "$ns" get secret vc-vcluster -o jsonpath='{.data.config}' | base64 -d \
  | sed "s#server: .*#server: https://localhost:${port}#" >"$kubeconfig"

for _ in $(seq 50); do
  kubectl --kubeconfig "$kubeconfig" get --raw=/readyz >/dev/null 2>&1 && break
  sleep 0.2
done

kubectl --kubeconfig "$kubeconfig" "$@"
