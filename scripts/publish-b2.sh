#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
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
PUBLISH_KEY_ID=$AWS_ACCESS_KEY_ID
PUBLISH_APPLICATION_KEY=$AWS_SECRET_ACCESS_KEY
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

if [[ -z ${RELEASE_ID:-} ]]; then
  RELEASE_ID=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || date -u +%Y%m%dT%H%M%SZ)
fi

export RELEASE_ID B2_ENDPOINT B2_REGION B2_BUCKET B2_ARCHIVE_PREFIX
"$ROOT/scripts/check.sh"
RELEASE="$ROOT/.build/production/release.yaml"
REPOSITORY="$ROOT/.build/production/repository"
MANIFEST="$ROOT/.build/production/manifest.sha256"
RELEASE_SHA=$(sha256sum "$RELEASE" | cut -d' ' -f1)
ENDPOINT_URL="https://$B2_ENDPOINT"
METADATA="sha256=${RELEASE_SHA},git-sha=${RELEASE_ID}"
RELEASE_PREFIX="${B2_ARCHIVE_PREFIX}${RELEASE_ID}/"
ENTRYPOINT_PREFIX="${B2_PREFIX}entrypoint/"

# Some S3-compatible services do not implement optional modern checksum
# trailers used by recent AWS CLI versions. The object itself carries SHA-256
# metadata and Flux independently calculates its source artifact digest.
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required
export AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
export AWS_DEFAULT_REGION="$B2_REGION"

AWS_ACCESS_KEY_ID="$PUBLISH_KEY_ID" \
AWS_SECRET_ACCESS_KEY="$PUBLISH_APPLICATION_KEY" \
aws s3 cp "$REPOSITORY" \
  "s3://${B2_BUCKET}/${RELEASE_PREFIX}" \
  --recursive \
  --endpoint-url "$ENDPOINT_URL" \
  --content-type application/yaml \
  --metadata "$METADATA"

AWS_ACCESS_KEY_ID="$PUBLISH_KEY_ID" \
AWS_SECRET_ACCESS_KEY="$PUBLISH_APPLICATION_KEY" \
aws s3 cp "$MANIFEST" \
  "s3://${B2_BUCKET}/${RELEASE_PREFIX}manifest.sha256" \
  --endpoint-url "$ENDPOINT_URL" \
  --content-type text/plain \
  --metadata "$METADATA"

AWS_ACCESS_KEY_ID="$PUBLISH_KEY_ID" \
AWS_SECRET_ACCESS_KEY="$PUBLISH_APPLICATION_KEY" \
aws s3 cp "$RELEASE" \
  "s3://${B2_BUCKET}/${RELEASE_PREFIX}release.yaml" \
  --endpoint-url "$ENDPOINT_URL" \
  --content-type application/yaml \
  --metadata "$METADATA"

# Immutable repository objects are complete before this single active pointer is
# replaced, so Flux cannot observe a partially published release.
AWS_ACCESS_KEY_ID="$PUBLISH_KEY_ID" \
AWS_SECRET_ACCESS_KEY="$PUBLISH_APPLICATION_KEY" \
aws s3 cp "$RELEASE" \
  "s3://${B2_BUCKET}/${ENTRYPOINT_PREFIX}release.yaml" \
  --endpoint-url "$ENDPOINT_URL" \
  --content-type application/yaml \
  --metadata "$METADATA"

echo "Published layered release $RELEASE_ID ($RELEASE_SHA) to s3://$B2_BUCKET/${ENTRYPOINT_PREFIX}release.yaml"
