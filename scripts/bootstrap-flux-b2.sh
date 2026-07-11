#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
fi
: "${B2_BUCKET:?set B2_BUCKET}"
: "${B2_ENDPOINT:?set B2_ENDPOINT, without https://}"
: "${B2_REGION:?set B2_REGION, e.g. eu-central-003}"
: "${B2_PREFIX:=clusters/production/current/}"
: "${B2_READ_KEY_ID:?set the read-only B2 key ID}"
: "${B2_READ_APPLICATION_KEY:?set the read-only B2 application key}"

B2_PREFIX="${B2_PREFIX%/}/"

command -v flux >/dev/null
command -v kubectl >/dev/null
command -v aws >/dev/null
kubectl cluster-info >/dev/null

# Fail before changing the cluster if the read-only key cannot see the active
# artifact that Flux is about to consume.
AWS_ACCESS_KEY_ID="$B2_READ_KEY_ID" \
AWS_SECRET_ACCESS_KEY="$B2_READ_APPLICATION_KEY" \
AWS_DEFAULT_REGION="$B2_REGION" \
AWS_REQUEST_CHECKSUM_CALCULATION=when_required \
AWS_RESPONSE_CHECKSUM_VALIDATION=when_required \
  aws s3api head-bucket \
    --bucket "$B2_BUCKET" \
    --endpoint-url "https://$B2_ENDPOINT" >/dev/null

AWS_ACCESS_KEY_ID="$B2_READ_KEY_ID" \
AWS_SECRET_ACCESS_KEY="$B2_READ_APPLICATION_KEY" \
AWS_DEFAULT_REGION="$B2_REGION" \
AWS_REQUEST_CHECKSUM_CALCULATION=when_required \
AWS_RESPONSE_CHECKSUM_VALIDATION=when_required \
  aws s3api list-objects-v2 \
    --bucket "$B2_BUCKET" \
    --prefix "$B2_PREFIX" \
    --max-keys 1 \
    --endpoint-url "https://$B2_ENDPOINT" >/dev/null

AWS_ACCESS_KEY_ID="$B2_READ_KEY_ID" \
AWS_SECRET_ACCESS_KEY="$B2_READ_APPLICATION_KEY" \
AWS_DEFAULT_REGION="$B2_REGION" \
AWS_REQUEST_CHECKSUM_CALCULATION=when_required \
AWS_RESPONSE_CHECKSUM_VALIDATION=when_required \
  aws s3api head-object \
    --bucket "$B2_BUCKET" \
    --key "${B2_PREFIX}bundle.yaml" \
    --endpoint-url "https://$B2_ENDPOINT" >/dev/null

flux check --pre
flux install \
  --components=source-controller,kustomize-controller,helm-controller

kubectl -n flux-system create secret generic b2-flux-reader \
  --from-literal=accesskey="$B2_READ_KEY_ID" \
  --from-literal=secretkey="$B2_READ_APPLICATION_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

B2_KUSTOMIZE_PATH="./${B2_PREFIX%/}"
export B2_BUCKET B2_ENDPOINT B2_REGION B2_PREFIX B2_KUSTOMIZE_PATH
sed \
  -e "s|\${B2_BUCKET}|$B2_BUCKET|g" \
  -e "s|\${B2_ENDPOINT}|$B2_ENDPOINT|g" \
  -e "s|\${B2_REGION}|$B2_REGION|g" \
  -e "s|\${B2_PREFIX}|$B2_PREFIX|g" \
  -e "s|\${B2_KUSTOMIZE_PATH}|$B2_KUSTOMIZE_PATH|g" \
  "$ROOT/bootstrap/b2-source.yaml.tpl" | kubectl apply -f -

flux reconcile source bucket cluster-config --namespace flux-system
flux reconcile kustomization cluster-config --namespace flux-system --with-source
flux check
flux get sources bucket --namespace flux-system
flux get kustomizations --namespace flux-system
