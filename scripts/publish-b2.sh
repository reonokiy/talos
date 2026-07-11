#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
fi
: "${B2_ENDPOINT:?set B2_ENDPOINT, without https://}"
: "${B2_REGION:?set B2_REGION, e.g. eu-central-003}"
: "${B2_BUCKET:?set B2_BUCKET}"
: "${B2_PREFIX:=clusters/production/current/}"
: "${B2_ARCHIVE_PREFIX:=clusters/production/releases/}"
: "${AWS_ACCESS_KEY_ID:?set the B2 publisher key ID}"
: "${AWS_SECRET_ACCESS_KEY:?set the B2 publisher application key}"

# Prefix-scoped B2 keys compare the requested ListObjects prefix literally.
# Keep exactly one trailing slash in every object prefix.
B2_PREFIX="${B2_PREFIX%/}/"
B2_ARCHIVE_PREFIX="${B2_ARCHIVE_PREFIX%/}/"

if [[ -z ${RELEASE_ID:-} ]]; then
  RELEASE_ID=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || date -u +%Y%m%dT%H%M%SZ)
fi

"$ROOT/scripts/check.sh"
BUNDLE="$ROOT/.build/production/bundle.yaml"
BUNDLE_SHA=$(cut -d' ' -f1 "$ROOT/.build/production/bundle.yaml.sha256")
ENDPOINT_URL="https://$B2_ENDPOINT"
METADATA="sha256=${BUNDLE_SHA},git-sha=${RELEASE_ID}"

# Some S3-compatible services do not implement optional modern checksum
# trailers used by recent AWS CLI versions. The object itself carries SHA-256
# metadata and Flux independently calculates its source artifact digest.
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required
export AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
export AWS_DEFAULT_REGION="$B2_REGION"

aws s3 cp "$BUNDLE" \
  "s3://${B2_BUCKET}/${B2_ARCHIVE_PREFIX}${RELEASE_ID}/bundle.yaml" \
  --endpoint-url "$ENDPOINT_URL" \
  --content-type application/yaml \
  --metadata "$METADATA"

# Publish the active revision last. This is a single PutObject, so Flux never
# observes a partially synchronized set of manifests.
aws s3 cp "$BUNDLE" \
  "s3://${B2_BUCKET}/${B2_PREFIX}bundle.yaml" \
  --endpoint-url "$ENDPOINT_URL" \
  --content-type application/yaml \
  --metadata "$METADATA"

echo "Published release $RELEASE_ID ($BUNDLE_SHA) to s3://$B2_BUCKET/${B2_PREFIX}bundle.yaml"
