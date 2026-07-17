#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
APPS="$ROOT/clusters/production/apps"
PRODUCTION="$ROOT/clusters/production"

command -v yq >/dev/null
command -v jq >/dev/null

mapfile -d '' APP_YAML_FILES < <(find "$APPS" -type f \( -name '*.yaml' -o -name '*.yml' \) -print0)
mapfile -d '' YAML_FILES < <(find "$PRODUCTION" -type f \( -name '*.yaml' -o -name '*.yml' \) -print0)

if ((${#APP_YAML_FILES[@]} > 0)) && grep -En \
    '^[[:space:]]*kind:[[:space:]]*(SecretStore|ClusterSecretStore|ClusterExternalSecret|PushSecret|ClusterPushSecret)[[:space:]]*$' \
    "${APP_YAML_FILES[@]}"; then
  echo "Applications may only use read-only ExternalSecret resources with the central ClusterSecretStore." >&2
  exit 1
fi

for file in "${YAML_FILES[@]}"; do
  documents=$(yq eval -o=json '.' "$file") || {
    echo "$file: failed to parse YAML documents." >&2
    exit 1
  }

  while IFS=$'\t' read -r name namespace creation_policy store_kind store_name data_from_count key; do
    [[ $creation_policy == "Owner" ]] || {
      echo "$file: ExternalSecret $namespace/$name target must use creationPolicy: Owner." >&2
      exit 1
    }
    [[ $store_kind == "ClusterSecretStore" && $store_name == "onepassword" ]] || {
      echo "$file: ExternalSecret $namespace/$name must reference ClusterSecretStore/onepassword." >&2
      exit 1
    }
    [[ $data_from_count == "0" ]] || {
      echo "$file: ExternalSecret $namespace/$name dataFrom is forbidden." >&2
      exit 1
    }

    prefix="${namespace}/"
    remainder=${key#"$prefix"}
    if [[ $key != "$prefix"* || ! $remainder =~ ^[^/]+/[^/]+$ ]]; then
      echo "$file: ExternalSecret $namespace/$name remote key '$key' must use <namespace-item>/<section>/<field>." >&2
      exit 1
    fi
  done < <(
    printf '%s\n' "$documents" |
      jq -r '
        select(.kind == "ExternalSecret") as $secret |
        (($secret.spec.data // []) | if length == 0 then [null] else . end)[] as $entry |
        [
          $secret.metadata.name // "",
          $secret.metadata.namespace // "",
          $secret.spec.target.creationPolicy // "",
          $secret.spec.secretStoreRef.kind // "",
          $secret.spec.secretStoreRef.name // "",
          (($secret.spec.dataFrom // []) | length | tostring),
          $entry.remoteRef.key // ""
        ] | @tsv
      '
  )
done

echo "External Secrets policy checks passed."
