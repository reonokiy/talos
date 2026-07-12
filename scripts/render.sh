#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT="$ROOT/.build/production"
: "${RELEASE_ID:=local}"
: "${B2_ENDPOINT:=s3.eu-central-003.backblazeb2.com}"
: "${B2_REGION:=eu-central-003}"
: "${B2_BUCKET:=talos-nokiy-net}"
: "${B2_ARCHIVE_PREFIX:=clusters/production/releases/}"

B2_ARCHIVE_PREFIX="${B2_ARCHIVE_PREFIX%/}/"
B2_RELEASE_PREFIX="${B2_ARCHIVE_PREFIX}${RELEASE_ID}/"
B2_RELEASE_PATH="./${B2_RELEASE_PREFIX%/}"

rm -rf "$OUT"
mkdir -p "$OUT/repository"

# Preserve the repository layout in B2 so Flux builds the same Kustomize paths
# validated locally. The immutable release prefix provides version isolation.
cp -R "$ROOT/clusters" "$OUT/repository/clusters"

sed \
  -e "s|\${B2_BUCKET}|$B2_BUCKET|g" \
  -e "s|\${B2_ENDPOINT}|$B2_ENDPOINT|g" \
  -e "s|\${B2_REGION}|$B2_REGION|g" \
  -e "s|\${B2_RELEASE_PREFIX}|$B2_RELEASE_PREFIX|g" \
  -e "s|\${B2_RELEASE_PATH}|$B2_RELEASE_PATH|g" \
  "$ROOT/bootstrap/release-entrypoint.yaml.tpl" > "$OUT/release.yaml"

(
  cd "$OUT/repository"
  find . -type f -print0 | sort -z | xargs -0 sha256sum
) > "$OUT/manifest.sha256"
(cd "$OUT" && sha256sum release.yaml) >> "$OUT/manifest.sha256"

printf 'Rendered layered release %s in %s\n' "$RELEASE_ID" "$OUT"
