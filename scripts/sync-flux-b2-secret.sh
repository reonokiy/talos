#!/usr/bin/env bash
set -euo pipefail

: "${B2_READ_KEY_ID:?load the prefix-scoped B2 reader key with fnox}"
: "${B2_READ_APPLICATION_KEY:?load the prefix-scoped B2 reader application key with fnox}"

READER_KEY_ID=$B2_READ_KEY_ID
READER_APPLICATION_KEY=$B2_READ_APPLICATION_KEY
unset B2_READ_KEY_ID B2_READ_APPLICATION_KEY

command -v kubectl >/dev/null
kubectl get namespace flux-system >/dev/null

# Process substitution keeps both values out of argv and off disk. The Secret
# is intentionally not part of the B2 bundle: Flux needs it before it can read
# that bundle, and the cluster never receives 1Password credentials or tooling.
kubectl -n flux-system create secret generic b2-flux-reader \
  --from-file=accesskey=<(printf '%s' "$READER_KEY_ID") \
  --from-file=secretkey=<(printf '%s' "$READER_APPLICATION_KEY") \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Synchronized flux-system/b2-flux-reader from the fnox subprocess."
