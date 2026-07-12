#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BUCKET_ID=${1:-}

if [[ -z $BUCKET_ID ]]; then
  echo "Usage: $0 <b2-bucket-id>" >&2
  echo "Find the bucketId for talos-nokiy-net in the Backblaze console." >&2
  exit 2
fi

command -v terraform >/dev/null

read_secret() {
  local variable=$1
  local prompt=$2
  local value

  if [[ -n ${!variable:-} ]]; then
    return
  fi

  read -r -s -p "$prompt: " value
  echo
  if [[ -z $value ]]; then
    echo "$variable must not be empty." >&2
    exit 1
  fi
  printf -v "$variable" '%s' "$value"
  export "${variable?}"
}

export TF_CLOUD_ORGANIZATION=${TF_CLOUD_ORGANIZATION:-reonokiy}
export TF_WORKSPACE=${TF_WORKSPACE:-talos-b2}

read_secret TF_TOKEN_app_terraform_io "HCP Terraform token"
read_secret B2_APPLICATION_KEY_ID "B2 account-level key ID"
read_secret B2_APPLICATION_KEY "B2 account-level application key"
read_secret TF_VAR_onepassword_service_account_token "1Password Service Account token"

cleanup() {
  unset TF_TOKEN_app_terraform_io
  unset B2_APPLICATION_KEY_ID
  unset B2_APPLICATION_KEY
  unset TF_VAR_onepassword_service_account_token
}
trap cleanup EXIT

terraform -chdir="$ROOT/terraform/b2" init
terraform -chdir="$ROOT/terraform/b2" import b2_bucket.flux "$BUCKET_ID"

echo "Imported B2 bucket $BUCKET_ID into $TF_CLOUD_ORGANIZATION/$TF_WORKSPACE."
echo "Run 'mise run b2:tf:plan' to review the remaining changes."
