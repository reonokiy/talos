#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT="$ROOT/.build/production"
mkdir -p "$OUT"

kubectl kustomize "$ROOT/clusters/production" \
  --load-restrictor=LoadRestrictionsNone > "$OUT/bundle.yaml"
test -s "$OUT/bundle.yaml"
(cd "$OUT" && sha256sum bundle.yaml > bundle.yaml.sha256)
printf 'Rendered %s\n' "$OUT/bundle.yaml"
