#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
"$ROOT/scripts/render.sh"

helm template cilium oci://quay.io/cilium/charts/cilium \
  --version 1.19.5 \
  --namespace kube-system \
  --values "$ROOT/infrastructure/cilium/values.yaml" >/dev/null

helmfile --file "$ROOT/bootstrap/helmfile.yaml.gotmpl" list --skip-charts >/dev/null

echo "Kustomize, Helm and Helmfile checks passed."
