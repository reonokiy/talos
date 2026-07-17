#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
"$ROOT/scripts/render.sh"
"$ROOT/scripts/check-external-secrets-policy.sh"

LONGHORN_VALUES="$ROOT/clusters/production/infrastructure/storage/longhorn/values.yaml"
LONGHORN_HELMRELEASE="$ROOT/clusters/production/infrastructure/storage/longhorn/helmrelease.yaml"
LONGHORN_VERSION=$(yq eval -r '.spec.chart.spec.version' "$LONGHORN_HELMRELEASE")
LONGHORN_RENDER=$(mktemp)
trap 'rm -f "$LONGHORN_RENDER"' EXIT

yq eval -e '
  .persistence.createStorageClass == false and
  .persistence.defaultClass == false and
  .persistence.dataEngine == "v1" and
  .networkPolicies.enabled == true and
  .networkPolicies.type == "" and
  .service.ui.type == "ClusterIP" and
  .ingress.enabled == false and
  .httproute.enabled == false and
  .defaultSettings.createDefaultDiskLabeledNodes == true and
  .defaultSettings.defaultDataPath == "/var/mnt/longhorn" and
  .defaultSettings.allowVolumeCreationWithDegradedAvailability == false and
  .defaultSettings.allowEmptyNodeSelectorVolume == false and
  .defaultSettings.allowEmptyDiskSelectorVolume == false and
  .defaultSettings.deletingConfirmationFlag == false and
  .defaultSettings.v1DataEngine == true and
  .defaultSettings.v2DataEngine == false
' "$LONGHORN_VALUES" >/dev/null

if grep -REn --include='*.yaml' --include='*.yml' \
  'node\.longhorn\.io/(create-default-disk|default-disks-config)' \
  "$ROOT/clusters"; then
  echo "Longhorn disk opt-in metadata is forbidden until dedicated disks are mounted." >&2
  exit 1
fi

helm template longhorn longhorn \
  --repo https://charts.longhorn.io \
  --version "$LONGHORN_VERSION" \
  --namespace longhorn-system \
  --values "$LONGHORN_VALUES" >"$LONGHORN_RENDER"

if grep -q '^kind: StorageClass$' "$LONGHORN_RENDER"; then
  echo "Longhorn must not render a StorageClass while the cluster has only system disks." >&2
  exit 1
fi

RELEASE_LONGHORN_VERSION=$(yq eval -r \
  'select(.kind == "Bucket" and .metadata.name == "cluster-release") | .metadata.annotations."storage.nokiy.net/longhorn-chart-version" // ""' \
  "$ROOT/.build/production/release.yaml")

if [[ $RELEASE_LONGHORN_VERSION != "$LONGHORN_VERSION" ]]; then
  echo "Longhorn release marker does not match the HelmRelease chart version." >&2
  exit 1
fi

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

kubectl kustomize "$ROOT/clusters/production" >/dev/null

helmfile --file "$ROOT/bootstrap/helmfile.yaml.gotmpl" list --skip-charts >/dev/null

echo "Kustomize, pinned Helm charts, release guards and Helmfile checks passed."
