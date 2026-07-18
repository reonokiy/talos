#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="${repo_root}/scripts/rotate-omni-join-token.sh"
fixture_path="${repo_root}/tests/fixtures"
test_root=$(mktemp -d)
tests_run=0

cleanup_tests() {
  rm -rf "$test_root"
}

trap cleanup_tests EXIT

fail_test() {
  printf 'not ok - %s\n' "$1" >&2
  if [[ -n "${OUTPUT:-}" ]]; then
    printf '%s\n' "$OUTPUT" >&2
  fi
  exit 1
}

pass_test() {
  tests_run=$((tests_run + 1))
  printf 'ok %d - %s\n' "$tests_run" "$1"
}

setup_case() {
  local name=$1
  local scenario=$2

  CASE_DIR="${test_root}/${name}"
  mkdir -p "${CASE_DIR}/tokens" "${CASE_DIR}/xdg"
  printf 'old-token-id\n' >"${CASE_DIR}/default"
  printf 'old\nfalse\n' >"${CASE_DIR}/tokens/old-token-id"
  if [[ "$scenario" == third_default_before_revoke ]]; then
    printf 'third\nfalse\n' >"${CASE_DIR}/tokens/third-token-id"
  fi
  printf '%s\n' "$scenario" >"${CASE_DIR}/scenario"
  : >"${CASE_DIR}/calls"
  OUTPUT=''
  STATUS=0
}

run_rotation() {
  local token_name=${1:-rotation-test}

  set +e
  OUTPUT=$(
    OMNI_FAKE_STATE="$CASE_DIR" \
      XDG_STATE_HOME="${CASE_DIR}/xdg" \
      PATH="${fixture_path}:$PATH" \
      bash -c '
        # shellcheck source=/dev/null
        source "$1"
        require_interactive() { return 0; }
        confirm_rotation() { return 0; }
        sleep() { return 0; }
        main "$2"
      ' _ "$script" "$token_name" 2>&1
  )
  STATUS=$?
  set -e
}

assert_status() {
  local expected=$1
  local label=$2

  [[ "$STATUS" == "$expected" ]] || fail_test "$label: expected status $expected, got $STATUS"
}

assert_file_line() {
  local file=$1
  local line=$2
  local expected=$3
  local label=$4
  local actual=''

  actual=$(sed -n "${line}p" "$file")
  [[ "$actual" == "$expected" ]] || fail_test "$label: expected $expected, got $actual"
}

assert_contains() {
  local value=$1
  local expected=$2
  local label=$3

  [[ "$value" == *"$expected"* ]] || fail_test "$label: missing $expected"
}

assert_not_contains() {
  local value=$1
  local unexpected=$2
  local label=$3

  [[ "$value" != *"$unexpected"* ]] || fail_test "$label: leaked or invoked $unexpected"
}

assert_no_unsafe_calls() {
  local calls=$1
  local label=$2

  assert_not_contains "$calls" '--force' "$label force flag"
  assert_not_contains "$calls" ' -f' "$label short force flag"
  assert_not_contains "$calls" 'jointoken list' "$label projected status read"
  assert_not_contains "$calls" 'jointoken revoke new-token-id' "$label new-token revoke"
  assert_not_contains "$calls" 'jointoken delete' "$label token delete"
  assert_not_contains "$calls" 'delete JoinTokens.omni.sidero.dev' "$label generic token delete"
  assert_not_contains "$calls" 'jointoken unrevoke' "$label token unrevoke"
  assert_not_contains "$calls" 'jointoken make-default old-token-id' "$label old-default restore"
}

assert_output_redacted() {
  local label=$1

  assert_not_contains "$OUTPUT" old-token-id "$label previous ID output"
  assert_not_contains "$OUTPUT" new-token-id "$label new ID output"
  assert_not_contains "$OUTPUT" intruder-token-id "$label intruder ID output"
}

assert_journal_present_without_ids() {
  local label=$1
  local journal=''
  local path="${CASE_DIR}/xdg/talos/rotate-omni-join-token.state"

  [[ -f "$path" ]] || fail_test "$label: recovery state is missing"
  journal=$(<"$path")
  assert_not_contains "$journal" old-token-id "$label journal previous ID"
  assert_not_contains "$journal" new-token-id "$label journal new ID"
  assert_not_contains "$journal" intruder-token-id "$label journal intruder ID"
}

assert_clean_success_state() {
  local label=$1
  local calls=''

  assert_file_line "${CASE_DIR}/default" 1 new-token-id "$label default"
  assert_file_line "${CASE_DIR}/tokens/old-token-id" 2 true "$label old state"
  assert_file_line "${CASE_DIR}/tokens/new-token-id" 2 false "$label new state"
  [[ ! -e "${CASE_DIR}/xdg/talos/rotate-omni-join-token.state" ]] || fail_test "$label: recovery state remains"

  calls=$(<"${CASE_DIR}/calls")
  assert_no_unsafe_calls "$calls" "$label"
  assert_output_redacted "$label"
}

test_successful_rotation() {
  setup_case success success
  run_rotation
  assert_status 0 success
  assert_clean_success_state success
  pass_test 'successful rotation uses authoritative source resources'
}

test_make_default_error_after_commit() {
  local calls=''

  setup_case make-committed make_default_committed_error
  run_rotation
  assert_status 0 make-committed
  assert_clean_success_state make-committed
  calls=$(<"${CASE_DIR}/calls")
  assert_contains "$calls" 'jointoken revoke old-token-id' 'make-committed old revoke'
  pass_test 'make-default transport error is reconciled after server commit'
}

test_make_default_error_before_commit_resumes() {
  local calls=''

  setup_case make-uncommitted make_default_uncommitted_error
  run_rotation
  assert_status 1 make-uncommitted
  assert_file_line "${CASE_DIR}/default" 1 old-token-id 'make-uncommitted default'
  assert_file_line "${CASE_DIR}/tokens/old-token-id" 2 false 'make-uncommitted old state'
  assert_file_line "${CASE_DIR}/tokens/new-token-id" 2 false 'make-uncommitted new state'
  assert_journal_present_without_ids make-uncommitted
  calls=$(<"${CASE_DIR}/calls")
  assert_no_unsafe_calls "$calls" make-uncommitted
  assert_not_contains "$calls" 'jointoken revoke old-token-id' 'make-uncommitted premature revoke'
  assert_output_redacted make-uncommitted

  printf 'success\n' >"${CASE_DIR}/scenario"
  run_rotation
  assert_status 0 make-uncommitted-resume
  assert_clean_success_state make-uncommitted-resume
  pass_test 'unobserved make-default keeps both tokens active and resumes idempotently'
}

test_make_default_late_commit_is_not_compensated() {
  local calls=''

  setup_case make-late make_default_late_commit
  run_rotation
  assert_status 1 make-late
  assert_file_line "${CASE_DIR}/default" 1 new-token-id 'make-late eventual default'
  assert_file_line "${CASE_DIR}/tokens/old-token-id" 2 false 'make-late old state'
  assert_file_line "${CASE_DIR}/tokens/new-token-id" 2 false 'make-late new state'
  assert_journal_present_without_ids make-late
  calls=$(<"${CASE_DIR}/calls")
  assert_no_unsafe_calls "$calls" make-late
  assert_not_contains "$calls" 'jointoken revoke old-token-id' 'make-late premature revoke'

  printf 'success\n' >"${CASE_DIR}/scenario"
  run_rotation
  assert_status 0 make-late-resume
  assert_clean_success_state make-late-resume
  pass_test 'a late make-default commit cannot race with destructive compensation'
}

test_revoke_refusal_keeps_staged_rotation() {
  local calls=''

  setup_case revoke-refused revoke_refused
  run_rotation
  assert_status 1 revoke-refused
  assert_file_line "${CASE_DIR}/default" 1 new-token-id 'revoke-refused default'
  assert_file_line "${CASE_DIR}/tokens/old-token-id" 2 false 'revoke-refused old state'
  assert_file_line "${CASE_DIR}/tokens/new-token-id" 2 false 'revoke-refused new state'
  assert_journal_present_without_ids revoke-refused
  calls=$(<"${CASE_DIR}/calls")
  assert_no_unsafe_calls "$calls" revoke-refused
  assert_contains "$OUTPUT" machine-a 'revoke-refused diagnostic'
  assert_output_redacted revoke-refused

  printf 'success\n' >"${CASE_DIR}/scenario"
  run_rotation
  assert_status 0 revoke-refused-resume
  assert_clean_success_state revoke-refused-resume
  pass_test 'warning refusal leaves a resumable new-default/old-active stage'
}

test_revoke_error_after_commit() {
  setup_case revoke-committed revoke_committed_error
  run_rotation
  assert_status 0 revoke-committed
  assert_clean_success_state revoke-committed
  pass_test 'revoke transport error is reconciled after server commit'
}

test_revoke_late_commit_is_not_rolled_back() {
  local calls=''

  setup_case revoke-late revoke_late_commit
  run_rotation
  assert_status 1 revoke-late
  assert_file_line "${CASE_DIR}/default" 1 new-token-id 'revoke-late default'
  assert_file_line "${CASE_DIR}/tokens/old-token-id" 2 true 'revoke-late eventual old state'
  assert_journal_present_without_ids revoke-late
  calls=$(<"${CASE_DIR}/calls")
  assert_no_unsafe_calls "$calls" revoke-late

  printf 'success\n' >"${CASE_DIR}/scenario"
  run_rotation
  assert_status 0 revoke-late-resume
  assert_clean_success_state revoke-late-resume
  pass_test 'a late revoke commit cannot race with rollback or unrevoke'
}

test_revoked_token_became_default() {
  local calls=''

  setup_case revoked-default revoked_token_became_default
  run_rotation
  assert_status 0 revoked-default
  assert_clean_success_state revoked-default
  calls=$(<"${CASE_DIR}/calls")
  assert_not_contains "$calls" 'jointoken unrevoke' 'revoked-default unsafe unrevoke'
  assert_not_contains "$calls" 'jointoken delete' 'revoked-default unsafe delete'
  pass_test 'a concurrently restored revoked default is replaced, never unrevoked'
}

test_create_error_after_commit() {
  setup_case create-committed create_committed_error
  run_rotation
  assert_status 0 create-committed
  assert_clean_success_state create-committed
  pass_test 'create transport error recovers the uniquely named source resource in-process'
}

test_uncertain_state_resumes_without_ids_on_disk() {
  local calls=''

  setup_case uncertain authority_unavailable_after_make
  run_rotation
  assert_status 1 uncertain-first
  assert_file_line "${CASE_DIR}/default" 1 new-token-id 'uncertain committed default'
  calls=$(<"${CASE_DIR}/calls")
  assert_no_unsafe_calls "$calls" uncertain-first
  assert_not_contains "$calls" 'jointoken revoke old-token-id' 'uncertain premature revoke'
  assert_journal_present_without_ids uncertain-first
  assert_output_redacted uncertain-first

  printf 'success\n' >"${CASE_DIR}/scenario"
  run_rotation
  assert_status 0 uncertain-resume
  assert_clean_success_state uncertain-resume
  pass_test 'uncertain switching resumes from two SHA-256 fingerprints only'
}

test_creating_phase_fails_closed() {
  local calls=''

  setup_case creating create_unobserved
  run_rotation
  assert_status 1 creating-first
  assert_journal_present_without_ids creating-first

  printf 'success\n' >"${CASE_DIR}/scenario"
  : >"${CASE_DIR}/calls"
  run_rotation
  assert_status 1 creating-empty-resume
  calls=$(<"${CASE_DIR}/calls")
  assert_not_contains "$calls" jointoken 'creating-empty retry mutation'

  printf 'rotation-test\nfalse\n' >"${CASE_DIR}/tokens/intruder-token-id"
  : >"${CASE_DIR}/calls"
  run_rotation
  assert_status 1 creating-name-resume
  calls=$(<"${CASE_DIR}/calls")
  assert_not_contains "$calls" jointoken 'creating-name token adoption'
  assert_output_redacted creating-name
  pass_test 'creating state without a new fingerprint never retries or adopts by name'
}

test_new_fingerprint_mismatch_fails_closed() {
  local calls=''

  setup_case fingerprint-mismatch authority_unavailable_after_make
  run_rotation
  assert_status 1 fingerprint-first
  rm -f "${CASE_DIR}/tokens/new-token-id"
  printf 'rotation-test\nfalse\n' >"${CASE_DIR}/tokens/intruder-token-id"
  printf 'old-token-id\n' >"${CASE_DIR}/default"
  printf 'success\n' >"${CASE_DIR}/scenario"
  : >"${CASE_DIR}/calls"

  run_rotation
  assert_status 1 fingerprint-mismatch
  calls=$(<"${CASE_DIR}/calls")
  assert_not_contains "$calls" jointoken 'fingerprint-mismatch mutation'
  assert_journal_present_without_ids fingerprint-mismatch
  assert_output_redacted fingerprint-mismatch
  pass_test 'a same-name token with the wrong fingerprint is never adopted'
}

test_third_party_default_fails_closed() {
  local calls=''

  setup_case third-default third_default_before_revoke
  run_rotation
  assert_status 1 third-default
  assert_file_line "${CASE_DIR}/default" 1 third-token-id 'third-default owner'
  assert_file_line "${CASE_DIR}/tokens/old-token-id" 2 false 'third-default old state'
  assert_file_line "${CASE_DIR}/tokens/new-token-id" 2 false 'third-default new state'
  calls=$(<"${CASE_DIR}/calls")
  assert_no_unsafe_calls "$calls" third-default
  assert_not_contains "$calls" 'jointoken revoke old-token-id' 'third-default revoke'
  assert_journal_present_without_ids third-default
  pass_test 'a third-party default stops the rotation before revocation'
}

test_noninteractive_and_name_guards() {
  setup_case noninteractive success

  set +e
  OUTPUT=$(
    OMNI_FAKE_STATE="$CASE_DIR" \
      XDG_STATE_HOME="${CASE_DIR}/xdg" \
      PATH="${fixture_path}:$PATH" \
      bash "$script" rotation-test </dev/null 2>&1
  )
  STATUS=$?
  set -e
  assert_status 1 noninteractive
  [[ ! -s "${CASE_DIR}/calls" ]] || fail_test 'noninteractive: omnictl was invoked'

  setup_case long-name success
  run_rotation 12345678901234567
  assert_status 1 long-name
  [[ ! -s "${CASE_DIR}/calls" ]] || fail_test 'long-name: omnictl was invoked'
  pass_test 'noninteractive execution and names over 16 characters fail closed'
}

test_bash_32_syntax_heuristic() {
  local source_text=''

  source_text=$(<"$script")
  assert_not_contains "$source_text" '[-1]' 'Bash 3.2 negative array index'
  assert_not_contains "$source_text" 'mapfile' 'Bash 3.2 mapfile'
  assert_not_contains "$source_text" 'readarray' 'Bash 3.2 readarray'
  assert_not_contains "$source_text" 'declare -A' 'Bash 3.2 associative array'
  assert_not_contains "$source_text" 'local -n' 'Bash 3.2 nameref'
  pass_test 'common Bash 4-only syntax is absent (heuristic)'
}

printf '1..15\n'
test_successful_rotation
test_make_default_error_after_commit
test_make_default_error_before_commit_resumes
test_make_default_late_commit_is_not_compensated
test_revoke_refusal_keeps_staged_rotation
test_revoke_error_after_commit
test_revoke_late_commit_is_not_rolled_back
test_revoked_token_became_default
test_create_error_after_commit
test_uncertain_state_resumes_without_ids_on_disk
test_creating_phase_fails_closed
test_new_fingerprint_mismatch_fails_closed
test_third_party_default_fails_closed
test_noninteractive_and_name_guards
test_bash_32_syntax_heuristic
