#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORKFLOWS=("$ROOT"/.github/workflows/*.yaml)

if grep -En \
  '(OP_SERVICE_ACCOUNT_TOKEN|FNOX_|op://|uses:[[:space:]]+[^[:space:]]*1password)' \
  "${WORKFLOWS[@]}"; then
  echo "GitHub Actions must not read from 1Password." >&2
  exit 1
fi

if grep -En \
  '^[[:space:]]+(run|install_args):.*(fnox|[[:space:]]op([[:space:]]|$))' \
  "${WORKFLOWS[@]}"; then
  echo "GitHub Actions must not install or execute fnox/op." >&2
  exit 1
fi

if grep -En \
  '^[[:space:]]+run:[[:space:]]+mise run[[:space:]]+[^-]' \
  "${WORKFLOWS[@]}"; then
  echo "GitHub Actions mise tasks must disable automatic tool installation." >&2
  exit 1
fi

echo "GitHub Actions 1Password boundary check passed."
