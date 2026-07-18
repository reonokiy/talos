#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
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
TMP=$(mktemp)
TMP_LONGHORN=$(mktemp)
TMP_LIVE_LONGHORN=$(mktemp)
trap 'rm -f "$TMP" "$TMP_LONGHORN" "$TMP_LIVE_LONGHORN"' EXIT

LONGHORN_HELMRELEASE="$ROOT/clusters/production/infrastructure/storage/longhorn/helmrelease.yaml"
EXPECTED_LONGHORN_VERSION=$(yq eval -r '.spec.chart.spec.version // ""' "$LONGHORN_HELMRELEASE")

if ! kubectl -n longhorn-system get helmrelease longhorn \
  -o yaml >"$TMP_LIVE_LONGHORN" 2>/dev/null; then
  echo "Cannot read the live Longhorn HelmRelease; refusing rollback." >&2
  exit 1
fi

LIVE_LONGHORN_VERSION=$(yq eval -r '.spec.chart.spec.version // ""' "$TMP_LIVE_LONGHORN")
INSTALLED_LONGHORN_VERSION=$(yq eval -r '.status.history[0].chartVersion // ""' "$TMP_LIVE_LONGHORN")
INSTALLED_LONGHORN_STATUS=$(yq eval -r '.status.history[0].status // ""' "$TMP_LIVE_LONGHORN")
LIVE_READY=$(yq eval -r '[.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length' "$TMP_LIVE_LONGHORN")
LIVE_RECONCILING=$(yq eval -r '[.status.conditions[]? | select(.type == "Reconciling" and .status == "True")] | length' "$TMP_LIVE_LONGHORN")
LIVE_GENERATION=$(yq eval -r '.metadata.generation // -1' "$TMP_LIVE_LONGHORN")
LIVE_OBSERVED_GENERATION=$(yq eval -r '.status.observedGeneration // -2' "$TMP_LIVE_LONGHORN")

if [[ ! $EXPECTED_LONGHORN_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid Longhorn chart version in current checkout: $EXPECTED_LONGHORN_VERSION" >&2
  exit 1
fi

if [[ ! $LIVE_LONGHORN_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Cannot verify the live Longhorn desired version; refusing rollback." >&2
  exit 1
fi

if [[ ! $INSTALLED_LONGHORN_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Cannot verify the installed Longhorn chart version; refusing rollback." >&2
  exit 1
fi

if [[ $LIVE_READY != 1 || $LIVE_RECONCILING != 0 || \
  $LIVE_GENERATION != "$LIVE_OBSERVED_GENERATION" || \
  $INSTALLED_LONGHORN_STATUS != deployed ]]; then
  echo "The live Longhorn HelmRelease is not stably reconciled; refusing rollback." >&2
  exit 1
fi

if [[ $EXPECTED_LONGHORN_VERSION != "$LIVE_LONGHORN_VERSION" ]]; then
  echo "Refusing rollback: checkout '$EXPECTED_LONGHORN_VERSION' does not match live desired '$LIVE_LONGHORN_VERSION'." >&2
  exit 1
fi

if [[ $EXPECTED_LONGHORN_VERSION != "$INSTALLED_LONGHORN_VERSION" ]]; then
  echo "Refusing rollback: checkout '$EXPECTED_LONGHORN_VERSION' does not match installed '$INSTALLED_LONGHORN_VERSION'." >&2
  exit 1
fi

export AWS_REQUEST_CHECKSUM_CALCULATION=when_required
export AWS_RESPONSE_CHECKSUM_VALIDATION=when_required

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

# A Flux rollback can otherwise reconcile an older HelmRelease and attempt an
# unsupported Longhorn downgrade. Require both the generated release marker and
# the archived HelmRelease to match the current checkout before promotion.
TARGET_LONGHORN_VERSION=$(yq eval -r \
  'select(.kind == "Bucket" and .metadata.name == "cluster-release") | .metadata.annotations."storage.nokiy.net/longhorn-chart-version" // ""' \
  "$TMP")
TARGET_RELEASE_PREFIX=$(yq eval -r \
  'select(.kind == "Bucket" and .metadata.name == "cluster-release") | .spec.prefix // ""' \
  "$TMP")
EXPECTED_RELEASE_PREFIX="${B2_ARCHIVE_PREFIX}${RELEASE_ID}/"

if [[ $TARGET_LONGHORN_VERSION != "$EXPECTED_LONGHORN_VERSION" ]]; then
  echo "Refusing rollback: target Longhorn marker '$TARGET_LONGHORN_VERSION' does not match current '$EXPECTED_LONGHORN_VERSION'." >&2
  exit 1
fi

if [[ $TARGET_RELEASE_PREFIX != "$EXPECTED_RELEASE_PREFIX" ]]; then
  echo "Refusing rollback: target release prefix does not match the requested immutable release." >&2
  exit 1
fi

AWS_ACCESS_KEY_ID="$RECOVERY_KEY_ID" \
AWS_SECRET_ACCESS_KEY="$RECOVERY_APPLICATION_KEY" \
AWS_DEFAULT_REGION="$B2_REGION" \
  aws s3 cp \
    "s3://${B2_BUCKET}/${TARGET_RELEASE_PREFIX}clusters/production/infrastructure/storage/longhorn/helmrelease.yaml" \
    "$TMP_LONGHORN" \
    --endpoint-url "$ENDPOINT_URL"

test -s "$TMP_LONGHORN"
TARGET_MANIFEST_VERSION=$(yq eval -r '.spec.chart.spec.version // ""' "$TMP_LONGHORN")

if [[ $TARGET_MANIFEST_VERSION != "$EXPECTED_LONGHORN_VERSION" ]]; then
  echo "Refusing rollback: archived Longhorn manifest '$TARGET_MANIFEST_VERSION' does not match current '$EXPECTED_LONGHORN_VERSION'." >&2
  exit 1
fi

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
