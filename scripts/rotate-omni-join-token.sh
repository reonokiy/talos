#!/usr/bin/env bash

DEFAULT_TOKEN_TYPE='DefaultJoinTokens.omni.sidero.dev'
JOIN_TOKEN_TYPE='JoinTokens.omni.sidero.dev'
DEFAULT_TOKEN_RESOURCE_ID='default'
STATE_VERSION='2'

OLD_TOKEN_ID=''
OLD_TOKEN_FINGERPRINT=''
NEW_TOKEN_ID=''
NEW_TOKEN_NAME=''
NEW_TOKEN_FINGERPRINT=''
STATE_PHASE=''
STATE_DIR=''
STATE_FILE=''
LOCK_DIR=''
LOCK_HELD=false
HASH_TOOL=''
CURRENT_DEFAULT=''
TOKEN_NAME=''
TOKEN_REVOKED=''
TOKEN_IDS=''
FINGERPRINT=''
FIND_COUNT=0
FIND_ID=''
OLD_FIND_COUNT=0
NEW_FIND_COUNT=0
NEW_NAME_COUNT=0
COMMAND_OUTPUT=''

usage() {
  cat <<'EOF'
Usage: rotate-omni-join-token.sh [new-token-name]

Create a new Omni SideroLink join token, make it the default, and revoke the
previous default. The name defaults to a 16-character UTC timestamp such as
20260715T120000Z.

If an interrupted rotation has local recovery state, rerun the same command to
reconcile it. Recovery state contains a token name and SHA-256 fingerprints,
never a join-token ID. An interruption before the new fingerprint is recorded
fails closed and requires manual inspection.
EOF
}

cleanup() {
  OLD_TOKEN_ID=''
  NEW_TOKEN_ID=''
  TOKEN_IDS=''
  COMMAND_OUTPUT=''

  if [[ "$LOCK_HELD" == true ]]; then
    rmdir "$LOCK_DIR" >/dev/null 2>&1 || true
  fi
}

die() {
  printf 'Error: %s\n' "$1" >&2

  if [[ -n "$STATE_FILE" && -f "$STATE_FILE" ]]; then
    printf 'Recovery state remains at %s; rerun this task to reconcile it before starting another rotation.\n' \
      "$STATE_FILE" >&2
  fi

  exit 1
}

valid_id() {
  [[ -n "$1" && "$1" != *[[:space:]]* ]]
}

validate_name() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,15}$ ]]
}

require_interactive() {
  [[ -t 0 && -t 1 ]] || die "run this task from an interactive terminal"
}

confirm_rotation() {
  local prompt=$1
  local answer=''

  printf '%s [y/N] ' "$prompt"
  IFS= read -r answer
  [[ "$answer" == y || "$answer" == Y ]]
}

configure_state_paths() {
  local state_home=''

  if [[ -n "${XDG_STATE_HOME:-}" ]]; then
    state_home=$XDG_STATE_HOME
  elif [[ -n "${HOME:-}" ]]; then
    state_home="${HOME}/.local/state"
  else
    die "HOME is not set and XDG_STATE_HOME is unavailable"
  fi

  case "$state_home" in
    /*) ;;
    *) die "the recovery-state directory must be an absolute path" ;;
  esac

  STATE_DIR="${state_home}/talos"
  STATE_FILE="${STATE_DIR}/rotate-omni-join-token.state"
  LOCK_DIR="${STATE_FILE}.lock"

  [[ ! -L "$STATE_DIR" ]] || die "the recovery-state directory must not be a symbolic link"
  mkdir -p "$STATE_DIR" || die "unable to create the recovery-state directory"
  [[ -d "$STATE_DIR" && ! -L "$STATE_DIR" ]] || die "the recovery-state path is not a private directory"
  chmod 700 "$STATE_DIR" || die "unable to protect the recovery-state directory"
  [[ ! -e "$STATE_FILE" || -f "$STATE_FILE" ]] || die "the recovery-state path is not a regular file"
}

acquire_lock() {
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    die "another rotation is running, or a stale lock exists at $LOCK_DIR"
  fi

  LOCK_HELD=true
}

select_hash_tool() {
  if command -v sha256sum >/dev/null 2>&1; then
    HASH_TOOL='sha256sum'
  elif command -v shasum >/dev/null 2>&1; then
    HASH_TOOL='shasum'
  else
    die "sha256sum or shasum is required for private recovery state"
  fi
}

fingerprint_id() {
  local value=$1
  local output=''

  if [[ "$HASH_TOOL" == sha256sum ]]; then
    output=$(printf %s "$value" | sha256sum) || return 1
  else
    output=$(printf %s "$value" | shasum -a 256) || return 1
  fi

  FINGERPRINT=${output%% *}
  [[ "$FINGERPRINT" =~ ^[0-9a-f]{64}$ ]]
}

write_state() {
  local temporary=''

  validate_name "$NEW_TOKEN_NAME" || die "refusing to write invalid recovery state"
  [[ "$OLD_TOKEN_FINGERPRINT" =~ ^[0-9a-f]{64}$ ]] || die "refusing to write invalid recovery state"
  [[ -z "$NEW_TOKEN_FINGERPRINT" || "$NEW_TOKEN_FINGERPRINT" =~ ^[0-9a-f]{64}$ ]] || \
    die "refusing to write invalid recovery state"

  case "$STATE_PHASE" in
    prepared | creating)
      [[ -z "$NEW_TOKEN_FINGERPRINT" ]] || die "refusing to write inconsistent recovery state"
      ;;
    rotating)
      [[ -n "$NEW_TOKEN_FINGERPRINT" ]] || die "refusing to write incomplete recovery state"
      ;;
    *) die "refusing to write invalid recovery state" ;;
  esac
  [[ ! -L "$STATE_FILE" ]] || die "the recovery-state file must not be a symbolic link"

  temporary=$(mktemp "${STATE_DIR}/.rotate-omni-join-token.XXXXXX") || die "unable to create recovery state"
  chmod 600 "$temporary" || {
    rm -f "$temporary"
    die "unable to protect recovery state"
  }

  if ! printf '%s\n%s\n%s\n%s\n%s\n' \
    "$STATE_VERSION" "$NEW_TOKEN_NAME" "$OLD_TOKEN_FINGERPRINT" "$NEW_TOKEN_FINGERPRINT" \
    "$STATE_PHASE" >"$temporary"; then
    rm -f "$temporary"
    die "unable to write recovery state"
  fi

  if ! mv -f "$temporary" "$STATE_FILE"; then
    rm -f "$temporary"
    die "unable to commit recovery state"
  fi
}

load_state() {
  local version=''
  local extra=''

  [[ -f "$STATE_FILE" && ! -L "$STATE_FILE" ]] || die "the recovery-state file is invalid"

  exec 3<"$STATE_FILE" || die "unable to read recovery state"
  IFS= read -r version <&3 || true
  IFS= read -r NEW_TOKEN_NAME <&3 || true
  IFS= read -r OLD_TOKEN_FINGERPRINT <&3 || true
  IFS= read -r NEW_TOKEN_FINGERPRINT <&3 || true
  IFS= read -r STATE_PHASE <&3 || true
  IFS= read -r extra <&3 || true
  exec 3<&-

  [[ "$version" == "$STATE_VERSION" && -z "$extra" ]] || die "invalid recovery-state format"
  validate_name "$NEW_TOKEN_NAME" || die "invalid token name in recovery state"
  [[ "$OLD_TOKEN_FINGERPRINT" =~ ^[0-9a-f]{64}$ ]] || die "invalid token fingerprint in recovery state"
  [[ -z "$NEW_TOKEN_FINGERPRINT" || "$NEW_TOKEN_FINGERPRINT" =~ ^[0-9a-f]{64}$ ]] || \
    die "invalid new-token fingerprint in recovery state"

  case "$STATE_PHASE" in
    prepared | creating)
      [[ -z "$NEW_TOKEN_FINGERPRINT" ]] || die "inconsistent recovery-state phase"
      ;;
    rotating)
      [[ -n "$NEW_TOKEN_FINGERPRINT" ]] || die "incomplete recovery-state phase"
      ;;
    *) die "invalid recovery-state phase" ;;
  esac
}

clear_state() {
  rm -f "$STATE_FILE" || die "unable to remove completed recovery state"
}

get_default_once() {
  # omnictl's YAML-backed JSONPath writer renders the Go field TokenId as
  # "tokenid", not the protobuf JSON name "tokenId".
  omnictl get "$DEFAULT_TOKEN_TYPE" "$DEFAULT_TOKEN_RESOURCE_ID" \
    -o=jsonpath='{.spec.tokenid}' 2>/dev/null
}

read_default() {
  local attempt=1
  local value=''

  CURRENT_DEFAULT=''

  while ((attempt <= 3)); do
    if value=$(get_default_once) && valid_id "$value"; then
      CURRENT_DEFAULT=$value
      return 0
    fi

    attempt=$((attempt + 1))
    sleep 1
  done

  return 1
}

get_token_name_once() {
  omnictl get "$JOIN_TOKEN_TYPE" "$1" -o=jsonpath='{.spec.name}' 2>/dev/null
}

read_token_name() {
  local id=$1
  local attempt=1
  local value=''

  TOKEN_NAME=''

  while ((attempt <= 3)); do
    if value=$(get_token_name_once "$id"); then
      TOKEN_NAME=$value
      return 0
    fi

    attempt=$((attempt + 1))
    sleep 1
  done

  return 1
}

get_token_revoked_once() {
  omnictl get "$JOIN_TOKEN_TYPE" "$1" -o=jsonpath='{.spec.revoked}' 2>/dev/null
}

read_token_revoked() {
  local id=$1
  local attempt=1
  local value=''

  TOKEN_REVOKED=''

  while ((attempt <= 3)); do
    if value=$(get_token_revoked_once "$id") && [[ "$value" == true || "$value" == false ]]; then
      TOKEN_REVOKED=$value
      return 0
    fi

    attempt=$((attempt + 1))
    sleep 1
  done

  return 1
}

list_token_ids() {
  local value=''

  TOKEN_IDS=''
  if value=$(omnictl get "$JOIN_TOKEN_TYPE" -o=jsonpath='{.metadata.id}' 2>/dev/null); then
    TOKEN_IDS=$value
    return 0
  fi

  return 1
}

find_token_by_name() {
  local wanted=$1
  local id=''

  FIND_COUNT=0
  FIND_ID=''
  list_token_ids || return 1

  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    valid_id "$id" || return 1
    read_token_name "$id" || return 1

    if [[ "$TOKEN_NAME" == "$wanted" ]]; then
      FIND_COUNT=$((FIND_COUNT + 1))
      FIND_ID=$id
    fi
  done <<<"$TOKEN_IDS"

  return 0
}

restore_ids_from_state() {
  local id=''
  local id_name=''

  OLD_TOKEN_ID=''
  NEW_TOKEN_ID=''
  OLD_FIND_COUNT=0
  NEW_FIND_COUNT=0
  NEW_NAME_COUNT=0
  list_token_ids || die "unable to enumerate authoritative join-token resources"

  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    valid_id "$id" || die "Omni returned an invalid join-token ID"
    fingerprint_id "$id" || die "unable to fingerprint a join-token ID"
    read_token_name "$id" || die "unable to read a join-token source resource"
    id_name=$TOKEN_NAME

    if [[ "$FINGERPRINT" == "$OLD_TOKEN_FINGERPRINT" ]]; then
      OLD_FIND_COUNT=$((OLD_FIND_COUNT + 1))
      OLD_TOKEN_ID=$id
    fi

    if [[ "$id_name" == "$NEW_TOKEN_NAME" ]]; then
      NEW_NAME_COUNT=$((NEW_NAME_COUNT + 1))
    fi

    if [[ -n "$NEW_TOKEN_FINGERPRINT" && "$FINGERPRINT" == "$NEW_TOKEN_FINGERPRINT" ]]; then
      NEW_FIND_COUNT=$((NEW_FIND_COUNT + 1))
      NEW_TOKEN_ID=$id
    fi
  done <<<"$TOKEN_IDS"

  ((OLD_FIND_COUNT <= 1)) || die "multiple join tokens match the previous-token fingerprint"
  ((NEW_FIND_COUNT <= 1)) || die "multiple join tokens match the new-token recovery identity"
  ((NEW_NAME_COUNT <= 1)) || die "multiple join tokens share the recovery name; resolve them manually"

  if [[ -n "$NEW_TOKEN_FINGERPRINT" ]]; then
    if [[ -n "$NEW_TOKEN_ID" ]]; then
      read_token_name "$NEW_TOKEN_ID" || die "unable to verify the recovered new token"
      [[ "$TOKEN_NAME" == "$NEW_TOKEN_NAME" ]] || die "the recovered new token name was changed"
    elif ((NEW_NAME_COUNT > 0)); then
      die "the recovery name was reused by a different token"
    fi
  elif [[ "$STATE_PHASE" == prepared && $NEW_NAME_COUNT -ne 0 ]]; then
    die "a token claimed the prepared recovery name before creation started"
  fi

  [[ -z "$OLD_TOKEN_ID" || "$OLD_TOKEN_ID" != "$NEW_TOKEN_ID" ]] || die "recovery state identifies the same token as old and new"
}

report_command_output() {
  local output=$COMMAND_OUTPUT

  if [[ -n "$OLD_TOKEN_ID" ]]; then
    output=${output//"$OLD_TOKEN_ID"/[previous-token]}
  fi

  if [[ -n "$NEW_TOKEN_ID" ]]; then
    output=${output//"$NEW_TOKEN_ID"/[new-token]}
  fi

  [[ -z "$output" ]] || printf '%s\n' "$output" >&2
}

run_make_default() {
  COMMAND_OUTPUT=$(omnictl jointoken make-default "$1" 2>&1) || true
}

run_revoke_previous() {
  COMMAND_OUTPUT=$(omnictl jointoken revoke "$OLD_TOKEN_ID" </dev/null 2>&1) || true
}

complete_rotation() {
  read_default || die "unable to verify the final default join token"
  [[ "$CURRENT_DEFAULT" == "$NEW_TOKEN_ID" ]] || die "the new token is no longer default"
  read_token_revoked "$NEW_TOKEN_ID" || die "unable to verify the new join token"
  [[ "$TOKEN_REVOKED" == false ]] || die "the new default join token is revoked"

  if [[ -n "$OLD_TOKEN_ID" ]]; then
    read_token_revoked "$OLD_TOKEN_ID" || die "unable to verify the previous join token"
    [[ "$TOKEN_REVOKED" == true ]] || die "the previous join token is still active"
  fi

  read_default || die "unable to perform the final default-token check"
  [[ "$CURRENT_DEFAULT" == "$NEW_TOKEN_ID" ]] || die "the default changed during final verification"

  clear_state
  printf 'Omni join token rotation completed successfully.\n'
  exit 0
}

restore_new_default_after_revocation() {
  read_token_revoked "$NEW_TOKEN_ID" || die "unable to verify the replacement token"
  [[ "$TOKEN_REVOKED" == false ]] || die "both the previous and replacement tokens are revoked"
  read_default || die "unable to recheck the revoked default before repair"
  [[ "$CURRENT_DEFAULT" == "$OLD_TOKEN_ID" ]] || \
    die "another writer changed the default before repair; no override was attempted"

  run_make_default "$NEW_TOKEN_ID"
  if read_default && [[ "$CURRENT_DEFAULT" == "$NEW_TOKEN_ID" ]]; then
    complete_rotation
  fi

  report_command_output
  die "the previous token is revoked but the replacement token could not be restored as default"
}

recover_created_token() {
  local expected_id=$1
  local attempt=1
  local had_authoritative_read=false

  while ((attempt <= 3)); do
    if find_token_by_name "$NEW_TOKEN_NAME"; then
      had_authoritative_read=true

      case "$FIND_COUNT" in
        0) ;;
        1)
          if [[ -n "$expected_id" && "$FIND_ID" != "$expected_id" ]]; then
            die "the create result conflicts with the authoritative join-token resource"
          fi

          NEW_TOKEN_ID=$FIND_ID
          return 0
          ;;
        *) die "multiple join tokens share the new recovery name" ;;
      esac
    fi

    attempt=$((attempt + 1))
    sleep 1
  done

  [[ "$had_authoritative_read" == true ]] || die "the create result is uncertain and join tokens cannot be inspected"
  return 1
}

record_new_token_identity() {
  fingerprint_id "$NEW_TOKEN_ID" || die "unable to fingerprint the new token"

  if [[ -n "$NEW_TOKEN_FINGERPRINT" && "$FINGERPRINT" != "$NEW_TOKEN_FINGERPRINT" ]]; then
    die "the new token no longer matches recovery state"
  fi

  NEW_TOKEN_FINGERPRINT=$FINGERPRINT
  STATE_PHASE='rotating'
  write_state
}

ensure_new_token() {
  local created=''
  local expected_id=''

  if [[ -n "$NEW_TOKEN_ID" ]]; then
    read_token_name "$NEW_TOKEN_ID" || die "the recorded new token cannot be read"
    [[ "$TOKEN_NAME" == "$NEW_TOKEN_NAME" ]] || die "the recorded new token has an unexpected name"
    read_token_revoked "$NEW_TOKEN_ID" || die "the recorded new token state cannot be read"
    [[ "$TOKEN_REVOKED" == false ]] || die "the recorded new token is revoked"
    record_new_token_identity
    return 0
  fi

  find_token_by_name "$NEW_TOKEN_NAME" || die "unable to inspect join-token names before creation"
  case "$FIND_COUNT" in
    0) ;;
    1) die "a token claimed the recovery name before creation started" ;;
    *) die "multiple join tokens share the recovery name" ;;
  esac

  read_default || die "unable to recheck the default before creating a token"
  [[ "$CURRENT_DEFAULT" == "$OLD_TOKEN_ID" ]] || die "another writer changed the default before token creation"
  read_token_revoked "$OLD_TOKEN_ID" || die "unable to recheck the previous token before creation"
  [[ "$TOKEN_REVOKED" == false ]] || die "the current default token is revoked"

  [[ "$STATE_PHASE" == prepared ]] || die "recovery state does not permit creating another token"
  STATE_PHASE='creating'
  write_state

  if created=$(omnictl jointoken create "$NEW_TOKEN_NAME" 2>/dev/null); then
    if valid_id "$created"; then
      expected_id=$created
    fi
  fi

  if ! recover_created_token "$expected_id"; then
    die "the create result was not observed; inspect Omni manually because the request may still commit"
  fi

  read_token_name "$NEW_TOKEN_ID" || die "the new token cannot be read after creation"
  [[ "$TOKEN_NAME" == "$NEW_TOKEN_NAME" ]] || die "the new token has an unexpected name"
  read_token_revoked "$NEW_TOKEN_ID" || die "the new token state cannot be read after creation"
  [[ "$TOKEN_REVOKED" == false ]] || die "the new token is already revoked"
  record_new_token_identity
}

make_new_default() {
  read_default || die "unable to read the authoritative default before switching"
  [[ "$CURRENT_DEFAULT" == "$OLD_TOKEN_ID" ]] || {
    [[ "$CURRENT_DEFAULT" == "$NEW_TOKEN_ID" ]] && return 0
    die "another writer changed the default before switching"
  }

  read_token_revoked "$OLD_TOKEN_ID" || die "unable to verify the previous token before switching"
  [[ "$TOKEN_REVOKED" == false ]] || die "the previous default token is revoked"
  read_token_revoked "$NEW_TOKEN_ID" || die "unable to verify the new token before switching"
  [[ "$TOKEN_REVOKED" == false ]] || die "the new token is revoked"
  read_default || die "unable to recheck the default before switching"
  [[ "$CURRENT_DEFAULT" == "$OLD_TOKEN_ID" ]] || die "the default changed immediately before switching"

  run_make_default "$NEW_TOKEN_ID"
  if ! read_default; then
    report_command_output
    die "the make-default result is uncertain; no token was revoked or deleted"
  fi

  if [[ "$CURRENT_DEFAULT" == "$NEW_TOKEN_ID" ]]; then
    return 0
  fi

  if [[ "$CURRENT_DEFAULT" == "$OLD_TOKEN_ID" ]]; then
    report_command_output
    die "the replacement was not observed as default; both tokens remain active and recovery state was kept"
  fi

  report_command_output
  die "another writer changed the default during switching; no token was revoked"
}

revoke_previous() {
  read_default || die "unable to verify the default before revoking the previous token"
  [[ "$CURRENT_DEFAULT" == "$NEW_TOKEN_ID" ]] || die "the new token is no longer default; no token was revoked"
  read_token_revoked "$NEW_TOKEN_ID" || die "unable to verify the new default token"
  [[ "$TOKEN_REVOKED" == false ]] || die "the new default token is revoked"
  read_token_revoked "$OLD_TOKEN_ID" || die "unable to verify the previous token"

  if [[ "$TOKEN_REVOKED" == true ]]; then
    complete_rotation
  fi

  read_default || die "unable to recheck the default immediately before revocation"
  [[ "$CURRENT_DEFAULT" == "$NEW_TOKEN_ID" ]] || die "the default changed; the previous token was not revoked"

  # Never force this operation. EOF accepts the safe default if Omni reports
  # machines which still depend on the previous token.
  run_revoke_previous
  if ! read_token_revoked "$OLD_TOKEN_ID"; then
    report_command_output
    die "the revoke result is uncertain; no compensating mutation was attempted"
  fi

  read_default || die "the revoke result committed, but the default cannot be reconciled"
  if [[ "$TOKEN_REVOKED" == true ]]; then
    if [[ "$CURRENT_DEFAULT" == "$NEW_TOKEN_ID" ]]; then
      complete_rotation
    fi

    if [[ "$CURRENT_DEFAULT" == "$OLD_TOKEN_ID" ]]; then
      restore_new_default_after_revocation
    fi

    die "another writer changed the default while the previous token was revoked"
  fi

  report_command_output
  die "the previous token remains active; the replacement stays default, so resolve warnings and rerun this task"
}

resume_rotation() {
  restore_ids_from_state

  [[ "$STATE_PHASE" != creating ]] || \
    die "token creation may still be in flight and no new-token fingerprint was recorded; inspect Omni manually"

  if [[ -z "$OLD_TOKEN_ID" ]]; then
    [[ -n "$NEW_TOKEN_ID" ]] || die "neither token from recovery state can be found"
    read_default || die "unable to reconcile the default after the previous token disappeared"
    [[ "$CURRENT_DEFAULT" == "$NEW_TOKEN_ID" ]] || die "the previous token disappeared while another token became default"
    complete_rotation
  fi

  read_token_revoked "$OLD_TOKEN_ID" || die "unable to inspect the previous token while resuming"
  if [[ "$TOKEN_REVOKED" == true ]]; then
    [[ -n "$NEW_TOKEN_ID" ]] || die "the previous token is revoked but the new token cannot be found"
    read_default || die "unable to reconcile a completed revocation"

    if [[ "$CURRENT_DEFAULT" == "$NEW_TOKEN_ID" ]]; then
      complete_rotation
    fi

    if [[ "$CURRENT_DEFAULT" == "$OLD_TOKEN_ID" ]]; then
      restore_new_default_after_revocation
    fi

    die "another writer controls the default while the previous token is revoked"
  fi

  if [[ -n "$NEW_TOKEN_ID" ]]; then
    read_token_revoked "$NEW_TOKEN_ID" || die "unable to inspect the new token while resuming"
    [[ "$TOKEN_REVOKED" == false ]] || die "the new token is revoked; inspect Omni manually"
  fi

  read_default || die "unable to reconcile the default while resuming"
  if [[ -z "$NEW_TOKEN_ID" ]]; then
    [[ "$CURRENT_DEFAULT" == "$OLD_TOKEN_ID" ]] || die "the default changed before the new token was created"
    ensure_new_token
  elif [[ "$CURRENT_DEFAULT" != "$OLD_TOKEN_ID" && "$CURRENT_DEFAULT" != "$NEW_TOKEN_ID" ]]; then
    die "another writer controls the default; no token was changed"
  fi

  make_new_default
  revoke_previous
}

main() {
  local requested_name=''

  set +x
  set -euo pipefail
  umask 077

  trap cleanup EXIT
  trap 'exit 130' HUP INT TERM

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

  require_interactive
  command -v omnictl >/dev/null 2>&1 || die "omnictl is not available"
  select_hash_tool
  configure_state_paths
  acquire_lock

  requested_name=${1-}

  if [[ -f "$STATE_FILE" ]]; then
    load_state

    if [[ -n "$requested_name" && "$requested_name" != "$NEW_TOKEN_NAME" ]]; then
      die "an incomplete rotation exists under a different token name"
    fi

    if ! confirm_rotation "Resume and reconcile the interrupted rotation for token \"$NEW_TOKEN_NAME\"?"; then
      printf 'Rotation left unchanged.\n'
      exit 0
    fi

    resume_rotation
  else

    NEW_TOKEN_NAME=${requested_name:-$(date -u +%Y%m%dT%H%M%SZ)}
    validate_name "$NEW_TOKEN_NAME" || \
      die "the token name must be 1-16 letters, digits, dots, underscores, or hyphens and start with a letter or digit"

    read_default || die "unable to read the authoritative default join token"
    OLD_TOKEN_ID=$CURRENT_DEFAULT
    read_token_revoked "$OLD_TOKEN_ID" || die "unable to read the current default token state"
    [[ "$TOKEN_REVOKED" == false ]] || die "the current default join token is already revoked"

    find_token_by_name "$NEW_TOKEN_NAME" || die "unable to inspect existing join-token names"
    ((FIND_COUNT == 0)) || die "a join token with the requested name already exists"

    if ! confirm_rotation "Create token \"$NEW_TOKEN_NAME\", make it default, and revoke the previous default?"; then
      printf 'Rotation cancelled.\n'
      exit 0
    fi

    read_default || die "unable to recheck the default after confirmation"
    [[ "$CURRENT_DEFAULT" == "$OLD_TOKEN_ID" ]] || die "the default changed while waiting for confirmation"
    read_token_revoked "$OLD_TOKEN_ID" || die "unable to recheck the previous token after confirmation"
    [[ "$TOKEN_REVOKED" == false ]] || die "the current default token was revoked while waiting for confirmation"

  fingerprint_id "$OLD_TOKEN_ID" || die "unable to fingerprint the previous token"
  OLD_TOKEN_FINGERPRINT=$FINGERPRINT
    STATE_PHASE='prepared'
    write_state

    ensure_new_token
    make_new_default
    revoke_previous
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
