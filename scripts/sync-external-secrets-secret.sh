#!/usr/bin/env bash
set -euo pipefail

: "${ONEPASSWORD_SERVICE_ACCOUNT_TOKEN:?load the talos.nokiy.net Service Account token with fnox}"

if (($# != 0)); then
  echo "usage: $0" >&2
  exit 2
fi

TOKEN=$ONEPASSWORD_SERVICE_ACCOUNT_TOKEN
unset ONEPASSWORD_SERVICE_ACCOUNT_TOKEN

command -v kubectl >/dev/null
kubectl get namespace external-secrets >/dev/null

# Process substitution keeps the token out of argv and off disk. The central
# ClusterSecretStore references this single bootstrap Secret; never render it
# into the B2 release bundle or copy it into application namespaces.
kubectl -n external-secrets create secret generic onepassword-service-account \
  --from-file=token=<(printf '%s' "$TOKEN") \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "Synchronized external-secrets/onepassword-service-account from the fnox subprocess."
