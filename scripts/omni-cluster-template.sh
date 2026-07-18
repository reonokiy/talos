#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TALOS_DIR="$ROOT/talos"
TEMPLATE='cluster-template.yaml'
CLUSTER='talos-default'
ACTION=${1:-}

die() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: omni-cluster-template.sh <validate|diff|plan|apply|status>
EOF
}

cd "$TALOS_DIR"

case "$ACTION" in
  validate)
    omnictl cluster template validate -f "$TEMPLATE"
    ;;
  diff)
    omnictl cluster template diff -f "$TEMPLATE"
    ;;
  plan)
    omnictl cluster template validate -f "$TEMPLATE"
    omnictl cluster template sync -f "$TEMPLATE" --dry-run --verbose
    ;;
  status)
    omnictl cluster template status -f "$TEMPLATE" --wait 0s
    ;;
  apply)
    [[ -t 0 && -t 1 ]] || die "run apply from an interactive terminal"

    printf 'Validating %s offline...\n' "$TEMPLATE"
    omnictl cluster template validate -f "$TEMPLATE"

    printf '\nCurrent Omni diff:\n'
    omnictl cluster template diff -f "$TEMPLATE"

    printf '\nDry-run sync:\n'
    omnictl cluster template sync -f "$TEMPLATE" --dry-run --verbose

    printf '\nThis updates Omni resources for %s and may roll Talos nodes.\n' "$CLUSTER"
    printf 'It does not shrink existing EPHEMERAL partitions; reprovisioning is separate.\n'
    printf 'Type %s to apply: ' "$CLUSTER"
    IFS= read -r answer
    [[ "$answer" == "$CLUSTER" ]] || die "confirmation did not match; no changes applied"

    omnictl cluster template sync -f "$TEMPLATE" --verbose
    omnictl cluster template status -f "$TEMPLATE" --wait 20m
    ;;
  -h | --help | help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
