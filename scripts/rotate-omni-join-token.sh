#!/usr/bin/env bash

set +x
set -euo pipefail

umask 077

OLD_TOKEN_ID=""
NEW_TOKEN_ID=""

cleanup() {
  unset OLD_TOKEN_ID NEW_TOKEN_ID TOKEN_LIST
}

trap cleanup EXIT
trap 'exit 130' INT TERM

usage() {
  cat <<'EOF'
Usage: rotate-omni-join-token.sh [new-token-name]

Create a new Omni SideroLink join token, make it the default, and revoke the
previous default. The name defaults to a UTC timestamp such as
20260715T120000Z.
EOF
}

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

if (($# > 1)); then
  usage >&2
  exit 2
fi

case "${1-}" in
  -h | --help)
    usage
    exit 0
    ;;
  -*)
    usage >&2
    exit 2
    ;;
esac

if [[ ! -t 0 || ! -t 1 ]]; then
  fail "run this task from an interactive terminal"
fi

command -v omnictl >/dev/null 2>&1 || fail "omnictl is not available"

NEW_TOKEN_NAME="${1:-$(date -u +%Y%m%dT%H%M%SZ)}"
if [[ ! "$NEW_TOKEN_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
  fail "the token name must be 1-64 letters, digits, dots, underscores, or hyphens"
fi

if ! TOKEN_LIST="$(omnictl jointoken list)"; then
  fail "unable to list join tokens; refresh the local omnictl login and retry"
fi

default_count=0
while IFS= read -r line; do
  read -r -a columns <<<"$line"
  if ((${#columns[@]} >= 2)) && [[ "${columns[-1]}" == "*" ]]; then
    OLD_TOKEN_ID="${columns[0]}"
    ((default_count += 1))
  fi
done <<<"$TOKEN_LIST"
unset TOKEN_LIST

if ((default_count != 1)) || [[ -z "$OLD_TOKEN_ID" ]]; then
  fail "expected exactly one default join token; inspect 'omnictl jointoken list'"
fi

printf 'Create join token "%s", make it default, and revoke the previous default? [y/N] ' "$NEW_TOKEN_NAME"
read -r answer
[[ "$answer" == "y" || "$answer" == "Y" ]] || {
  printf 'Rotation cancelled.\n'
  exit 0
}

if ! NEW_TOKEN_ID="$(omnictl jointoken create "$NEW_TOKEN_NAME")"; then
  fail "unable to create the new join token"
fi

if [[ -z "$NEW_TOKEN_ID" || "$NEW_TOKEN_ID" == *[[:space:]]* ]]; then
  fail "omnictl returned an unexpected result after creating the join token"
fi

if ! omnictl jointoken make-default "$NEW_TOKEN_ID" >/dev/null 2>&1; then
  if omnictl jointoken revoke "$NEW_TOKEN_ID" </dev/null >/dev/null 2>&1; then
    fail "unable to make the new join token default; the new token was revoked"
  fi

  fail "unable to make the new join token default; inspect the Omni token list"
fi

# Never force this operation. If Omni warns that machines still use the old
# token, EOF answers the CLI prompt with its safe default and leaves it active.
if ! omnictl jointoken revoke "$OLD_TOKEN_ID" </dev/null >/dev/null 2>&1; then
  fail "the new token is default, but the previous token was not revoked; inspect Omni before retrying"
fi

if ! TOKEN_LIST="$(omnictl jointoken list)"; then
  fail "rotation commands completed, but their result could not be verified"
fi

verified_default=false
verified_old_revoked=false
while IFS= read -r line; do
  read -r -a columns <<<"$line"
  ((${#columns[@]} >= 2)) || continue

  if [[ "${columns[0]}" == "$NEW_TOKEN_ID" && "${columns[-1]}" == "*" ]]; then
    verified_default=true
  fi

  if [[ "${columns[0]}" == "$OLD_TOKEN_ID" ]]; then
    for column in "${columns[@]}"; do
      if [[ "$column" == "REVOKED" ]]; then
        verified_old_revoked=true
        break
      fi
    done
  fi
done <<<"$TOKEN_LIST"
unset TOKEN_LIST

if [[ "$verified_default" != true || "$verified_old_revoked" != true ]]; then
  fail "rotation commands completed, but Omni did not report the expected final state"
fi

printf 'Omni join token rotation completed successfully.\n'
