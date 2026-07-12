#!/usr/bin/env bash
set -euo pipefail

: "${ONEPASSWORD_SERVICE_ACCOUNT_TOKEN:?load the talos.nokiy.net Service Account token with fnox}"

if (($# == 0)); then
  echo "usage: $0 <application-namespace> [application-namespace ...]" >&2
  exit 2
fi

TOKEN=$ONEPASSWORD_SERVICE_ACCOUNT_TOKEN
unset ONEPASSWORD_SERVICE_ACCOUNT_TOKEN

command -v kubectl >/dev/null

for namespace in "$@"; do
  kubectl get namespace "$namespace" >/dev/null

  # Process substitution keeps the token out of argv and off disk. Each
  # namespaced SecretStore references only its local copy of this bootstrap
  # Secret. Never render this Secret into the B2 release bundle.
  kubectl -n "$namespace" create secret generic onepassword-service-account \
    --from-file=token=<(printf '%s' "$TOKEN") \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  printf 'Synchronized %s/onepassword-service-account from the fnox subprocess.\n' "$namespace"
done
