#!/usr/bin/env bash
set -euo pipefail

RELEASE_ID=${1:?usage: rollback-b2.sh <release-id>}
: "${B2_ENDPOINT:?set B2_ENDPOINT, without https://}"
: "${B2_REGION:?set B2_REGION}"
: "${B2_BUCKET:?set B2_BUCKET}"
: "${B2_PREFIX:=clusters/production/current/}"
: "${B2_ARCHIVE_PREFIX:=clusters/production/releases/}"
: "${AWS_ACCESS_KEY_ID:?set the write-only B2 publisher key ID}"
: "${AWS_SECRET_ACCESS_KEY:?set the write-only B2 publisher application key}"
: "${B2_RECOVERY_READ_KEY_ID:?set the offline archive read key ID}"
: "${B2_RECOVERY_READ_APPLICATION_KEY:?set the offline archive read application key}"

B2_PREFIX="${B2_PREFIX%/}/"
B2_ARCHIVE_PREFIX="${B2_ARCHIVE_PREFIX%/}/"
PUBLISH_KEY_ID=$AWS_ACCESS_KEY_ID
PUBLISH_APPLICATION_KEY=$AWS_SECRET_ACCESS_KEY
RECOVERY_KEY_ID=$B2_RECOVERY_READ_KEY_ID
RECOVERY_APPLICATION_KEY=$B2_RECOVERY_READ_APPLICATION_KEY
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
unset B2_RECOVERY_READ_KEY_ID B2_RECOVERY_READ_APPLICATION_KEY
ENDPOINT_URL="https://$B2_ENDPOINT"
ENTRYPOINT_PREFIX="${B2_PREFIX}entrypoint/"
COMPATIBILITY_KEY="${B2_ARCHIVE_PREFIX}${RELEASE_ID}/clusters/production/rollback-compatibility/external-dns-cleanup-v1"
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

export AWS_REQUEST_CHECKSUM_CALCULATION=when_required
export AWS_RESPONSE_CHECKSUM_VALIDATION=when_required

# Releases from before the ExternalDNS cleanup boundary can strand owned A/TXT
# records by pruning the controller before it observes the Ingress removals.
# Treat not-found, authorization and transport failures alike: rollback must
# fail closed whenever the permanent compatibility marker cannot be verified.
if ! AWS_ACCESS_KEY_ID="$RECOVERY_KEY_ID" \
  AWS_SECRET_ACCESS_KEY="$RECOVERY_APPLICATION_KEY" \
  AWS_DEFAULT_REGION="$B2_REGION" \
  aws s3api head-object \
    --bucket "$B2_BUCKET" \
    --key "$COMPATIBILITY_KEY" \
    --endpoint-url "$ENDPOINT_URL" \
    >/dev/null 2>&1; then
  echo "Refusing rollback: release $RELEASE_ID is outside the ExternalDNS cleanup boundary or its compatibility marker cannot be verified." >&2
  echo "Remove DNS opt-ins while ExternalDNS is running, verify its owned A/TXT records are gone, publish that cleanup release, and retire the controller only in a later release." >&2
  exit 1
fi

# CopyObject would require one credential with both read and write access.
# Download and upload separately to keep the long-lived publisher write-only.
AWS_ACCESS_KEY_ID="$RECOVERY_KEY_ID" \
AWS_SECRET_ACCESS_KEY="$RECOVERY_APPLICATION_KEY" \
AWS_DEFAULT_REGION="$B2_REGION" \
  aws s3 cp \
    "s3://${B2_BUCKET}/${B2_ARCHIVE_PREFIX}${RELEASE_ID}/release.yaml" \
    "$TMP" \
    --endpoint-url "$ENDPOINT_URL"

test -s "$TMP"
RELEASE_SHA=$(sha256sum "$TMP" | cut -d' ' -f1)

AWS_ACCESS_KEY_ID="$PUBLISH_KEY_ID" \
AWS_SECRET_ACCESS_KEY="$PUBLISH_APPLICATION_KEY" \
AWS_DEFAULT_REGION="$B2_REGION" \
  aws s3 cp \
    "$TMP" \
    "s3://${B2_BUCKET}/${ENTRYPOINT_PREFIX}release.yaml" \
    --endpoint-url "$ENDPOINT_URL" \
    --content-type application/yaml \
    --metadata "sha256=${RELEASE_SHA},git-sha=${RELEASE_ID},rollback=true"

echo "Restored release $RELEASE_ID ($RELEASE_SHA) to s3://$B2_BUCKET/${ENTRYPOINT_PREFIX}release.yaml"
