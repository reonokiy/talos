#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CILIUM_VERSION=${CILIUM_VERSION:-1.19.5}
CILIUM_CHART_SHA256=${CILIUM_CHART_SHA256:-56b60445a2c650b387ce2edb13cfd8d83219a9da693b0523915dba8be451a29e}

command -v kubectl >/dev/null
command -v helm >/dev/null
kubectl cluster-info >/dev/null

CHART_DIR="$ROOT/.build/bootstrap"
CHART="$CHART_DIR/cilium-$CILIUM_VERSION.tgz"
mkdir -p "$CHART_DIR"

if [[ ! -s "$CHART" ]]; then
  for attempt in 1 2 3; do
    if helm pull oci://quay.io/cilium/charts/cilium \
      --version "$CILIUM_VERSION" \
      --destination "$CHART_DIR"; then
      break
    fi
    if [[ $attempt -eq 3 ]]; then
      echo "Failed to download Cilium chart after $attempt attempts" >&2
      exit 1
    fi
    echo "Cilium chart download failed; retrying ($attempt/3)..." >&2
  done
fi

printf '%s  %s\n' "$CILIUM_CHART_SHA256" "$CHART" | sha256sum --check --status || {
  echo "Cilium chart SHA-256 verification failed: $CHART" >&2
  exit 1
}

for attempt in 1 2 3; do
  if helm upgrade --install cilium "$CHART" \
    --namespace kube-system \
    --values "$ROOT/infrastructure/cilium/values.yaml" \
    --wait \
    --timeout 10m; then
    break
  fi
  if [[ $attempt -eq 3 ]]; then
    echo "Failed to install Cilium after $attempt attempts" >&2
    exit 1
  fi
  echo "Cilium install attempt failed; retrying ($attempt/3)..." >&2
done

kubectl rollout status daemonset/cilium -n kube-system --timeout=10m
kubectl rollout status deployment/cilium-operator -n kube-system --timeout=10m
kubectl wait nodes --all --for=condition=Ready --timeout=10m

if command -v cilium >/dev/null; then
  cilium status --wait --wait-duration 5m
else
  echo "Cilium CLI is not installed; skipped cilium status."
fi
