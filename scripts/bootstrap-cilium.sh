#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CILIUM_VERSION=${CILIUM_VERSION:-1.19.5}
CILIUM_CHART_SHA256=${CILIUM_CHART_SHA256:-56b60445a2c650b387ce2edb13cfd8d83219a9da693b0523915dba8be451a29e}

command -v kubectl >/dev/null
command -v helm >/dev/null
command -v helmfile >/dev/null
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

BOOTSTRAP_CILIUM_CHART="$CHART" \
  helmfile --file "$ROOT/bootstrap/helmfile.yaml.gotmpl" \
    --selector phase=cni sync

kubectl rollout status daemonset/cilium -n kube-system --timeout=10m
kubectl rollout status deployment/cilium-operator -n kube-system --timeout=10m
kubectl wait nodes --all --for=condition=Ready --timeout=10m

if command -v cilium >/dev/null; then
  cilium status --wait --wait-duration 5m
else
  echo "Cilium CLI is not installed; skipped cilium status."
fi
