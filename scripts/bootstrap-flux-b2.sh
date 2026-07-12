#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
: "${B2_BUCKET:?set B2_BUCKET}"
: "${B2_ENDPOINT:?set B2_ENDPOINT, without https://}"
: "${B2_REGION:?set B2_REGION, e.g. eu-central-003}"
: "${B2_PREFIX:=clusters/production/current/}"
: "${B2_READ_KEY_ID:?set the read-only B2 key ID}"
: "${B2_READ_APPLICATION_KEY:?set the read-only B2 application key}"

B2_PREFIX="${B2_PREFIX%/}/"
B2_ENTRYPOINT_PREFIX="${B2_PREFIX}entrypoint/"
B2_ENTRYPOINT_PATH="./${B2_ENTRYPOINT_PREFIX%/}"
READER_KEY_ID=$B2_READ_KEY_ID
READER_APPLICATION_KEY=$B2_READ_APPLICATION_KEY
unset B2_READ_KEY_ID B2_READ_APPLICATION_KEY

command -v flux >/dev/null
command -v kubectl >/dev/null
command -v helmfile >/dev/null
command -v aws >/dev/null
kubectl cluster-info >/dev/null

# Fail before changing the cluster if the read-only key cannot see the active
# artifact that Flux is about to consume.
AWS_ACCESS_KEY_ID="$READER_KEY_ID" \
AWS_SECRET_ACCESS_KEY="$READER_APPLICATION_KEY" \
AWS_DEFAULT_REGION="$B2_REGION" \
AWS_REQUEST_CHECKSUM_CALCULATION=when_required \
AWS_RESPONSE_CHECKSUM_VALIDATION=when_required \
  aws s3api head-bucket \
    --bucket "$B2_BUCKET" \
    --endpoint-url "https://$B2_ENDPOINT" >/dev/null

AWS_ACCESS_KEY_ID="$READER_KEY_ID" \
AWS_SECRET_ACCESS_KEY="$READER_APPLICATION_KEY" \
AWS_DEFAULT_REGION="$B2_REGION" \
AWS_REQUEST_CHECKSUM_CALCULATION=when_required \
AWS_RESPONSE_CHECKSUM_VALIDATION=when_required \
  aws s3api list-objects-v2 \
    --bucket "$B2_BUCKET" \
    --prefix "$B2_PREFIX" \
    --max-keys 1 \
    --endpoint-url "https://$B2_ENDPOINT" >/dev/null

AWS_ACCESS_KEY_ID="$READER_KEY_ID" \
AWS_SECRET_ACCESS_KEY="$READER_APPLICATION_KEY" \
AWS_DEFAULT_REGION="$B2_REGION" \
AWS_REQUEST_CHECKSUM_CALCULATION=when_required \
AWS_RESPONSE_CHECKSUM_VALIDATION=when_required \
  aws s3api head-object \
    --bucket "$B2_BUCKET" \
    --key "${B2_ENTRYPOINT_PREFIX}release.yaml" \
    --endpoint-url "https://$B2_ENDPOINT" >/dev/null

flux check --pre
helmfile --file "$ROOT/bootstrap/helmfile.yaml.gotmpl" \
  --selector phase=flux sync

B2_READ_KEY_ID="$READER_KEY_ID" \
B2_READ_APPLICATION_KEY="$READER_APPLICATION_KEY" \
  "$ROOT/scripts/sync-flux-b2-secret.sh"

# Suspend the legacy monolithic reconciler and disable pruning before changing
# its source path. Child Kustomizations can then adopt the existing inventory
# without a gap that removes cluster networking or system services.
if kubectl -n flux-system get kustomization cluster-config >/dev/null 2>&1; then
  flux suspend kustomization cluster-config --namespace flux-system
  kubectl -n flux-system patch kustomization cluster-config \
    --type=merge -p '{"spec":{"prune":false}}'
fi

export B2_BUCKET B2_ENDPOINT B2_REGION B2_ENTRYPOINT_PREFIX B2_ENTRYPOINT_PATH
sed \
  -e "s|\${B2_BUCKET}|$B2_BUCKET|g" \
  -e "s|\${B2_ENDPOINT}|$B2_ENDPOINT|g" \
  -e "s|\${B2_REGION}|$B2_REGION|g" \
  -e "s|\${B2_ENTRYPOINT_PREFIX}|$B2_ENTRYPOINT_PREFIX|g" \
  -e "s|\${B2_ENTRYPOINT_PATH}|$B2_ENTRYPOINT_PATH|g" \
  "$ROOT/bootstrap/b2-source.yaml.tpl" | kubectl apply -f -

flux resume kustomization cluster-config --namespace flux-system
flux reconcile source bucket cluster-config --namespace flux-system
flux reconcile kustomization cluster-config --namespace flux-system --with-source

for layer in cluster-network cluster-certificates cluster-system cluster-apps; do
  flux reconcile kustomization "$layer" --namespace flux-system --with-source
done

# The root inventory now contains only the release source and child
# Kustomizations. Restoring prune no longer risks deleting adopted workloads.
kubectl -n flux-system patch kustomization cluster-config \
  --type=merge -p '{"spec":{"prune":true}}'

flux check
flux get sources bucket --namespace flux-system
flux get kustomizations --namespace flux-system
