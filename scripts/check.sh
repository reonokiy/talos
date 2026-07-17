#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
"$ROOT/scripts/render.sh"
"$ROOT/scripts/check-external-secrets-policy.sh"

test -f "$ROOT/.build/production/repository/clusters/production/rollback-compatibility/external-dns-cleanup-v1"

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

TRAEFIK_DIR="$ROOT/clusters/production/infrastructure/network/traefik"
TRAEFIK_CHART=$(yq eval -er '.spec.chart.spec.chart' "$TRAEFIK_DIR/helmrelease.yaml")
TRAEFIK_CHART_VERSION=$(yq eval -er '.spec.chart.spec.version' "$TRAEFIK_DIR/helmrelease.yaml")
TRAEFIK_REPOSITORY=$(yq eval -er '.spec.url' "$TRAEFIK_DIR/helmrepository.yaml")
helm template traefik "$TRAEFIK_CHART" \
  --repo "$TRAEFIK_REPOSITORY" \
  --version "$TRAEFIK_CHART_VERSION" \
  --namespace traefik \
  --values "$TRAEFIK_DIR/values.yaml" >/dev/null

EXTERNAL_DNS_DIR="$ROOT/clusters/production/infrastructure/system/external-dns"
EXTERNAL_DNS_CHART=$(yq eval -er '.spec.chart.spec.chart' "$EXTERNAL_DNS_DIR/helmrelease.yaml")
EXTERNAL_DNS_CHART_VERSION=$(yq eval -er '.spec.chart.spec.version' "$EXTERNAL_DNS_DIR/helmrelease.yaml")
EXTERNAL_DNS_REPOSITORY=$(yq eval -er '.spec.url' "$EXTERNAL_DNS_DIR/helmrepository.yaml")
helm template external-dns "$EXTERNAL_DNS_CHART" \
  --repo "$EXTERNAL_DNS_REPOSITORY" \
  --version "$EXTERNAL_DNS_CHART_VERSION" \
  --namespace external-dns \
  --values "$EXTERNAL_DNS_DIR/values.yaml" >/dev/null

helmfile --file "$ROOT/bootstrap/helmfile.yaml.gotmpl" list --skip-charts >/dev/null

echo "Kustomize, Helm and Helmfile checks passed."
