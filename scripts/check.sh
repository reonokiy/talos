#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
"$ROOT/scripts/render.sh"
"$ROOT/scripts/check-external-secrets-policy.sh"

kubectl kustomize "$ROOT/clusters/production" >/dev/null

helm template cilium oci://quay.io/cilium/charts/cilium \
  --version 1.19.5 \
  --namespace kube-system \
  --values "$ROOT/clusters/production/infrastructure/network/cilium/values.yaml" >/dev/null

yq eval '.spec.values' \
  "$ROOT/clusters/production/infrastructure/secrets/external-secrets/helmrelease-crds.yaml" |
  helm template external-secrets-crds external-secrets \
    --repo https://charts.external-secrets.io \
    --version 2.6.0 \
    --namespace external-secrets \
    --values - >/dev/null

yq eval '.spec.values' \
  "$ROOT/clusters/production/infrastructure/secrets/external-secrets/helmrelease.yaml" |
  helm template external-secrets external-secrets \
    --repo https://charts.external-secrets.io \
    --version 2.6.0 \
    --namespace external-secrets \
    --values - >/dev/null

helmfile --file "$ROOT/bootstrap/helmfile.yaml.gotmpl" list --skip-charts >/dev/null

echo "Kustomize, Helm and Helmfile checks passed."
