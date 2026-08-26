#!/usr/bin/env bash

set -euo pipefail

readonly repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly script="$repo_root/scripts/get-oidc-token.sh"
readonly fake_bin="$repo_root/tests/fake-bin"
test_root="$(mktemp -d)"
output=""

cleanup() {
  rm -rf "$test_root"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" == *"$needle"* ]] || fail "expected output to contain: $needle"
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" != *"$needle"* ]] || fail "expected output not to contain: $needle"
}

run_case() {
  local name="$1"
  local scenario="$2"
  local expected_status="$3"
  local expected_calls="$4"
  local case_root="$test_root/$name"
  local status=0

  mkdir -p "$case_root"
  : >"$case_root/github-env"

  output="$(
    PATH="$fake_bin:$PATH" \
      ACTIONS_ID_TOKEN_REQUEST_URL="https://example.test/oidc?request=1" \
      ACTIONS_ID_TOKEN_REQUEST_TOKEN="test-request-token" \
      GITHUB_ENV="$case_root/github-env" \
      OIDC_TOKEN_MAX_ATTEMPTS=3 \
      OIDC_TOKEN_RETRY_BASE_DELAY_SECONDS=0 \
      FAKE_CURL_SCENARIO="$scenario" \
      FAKE_CURL_STATE="$case_root/calls" \
      bash "$script" 2>&1
  )" || status=$?

  [[ "$status" == "$expected_status" ]] || fail "$name returned $status, expected $expected_status; output: $output"
  [[ "$(<"$case_root/calls")" == "$expected_calls" ]] || fail "$name made the wrong number of requests"
  assert_not_contains "$output" "test-request-token"
}

run_case success success 0 1
[[ "$(<"$test_root/success/github-env")" == "OIDC_TOKEN=test.oidc.token" ]] || fail "success did not write the token"

run_case transient_http transient-http 0 2
assert_contains "$output" "HTTP 502"
assert_contains "$output" "retrying"
assert_not_contains "$output" "upstream unavailable"

run_case malformed_success malformed-success 0 2
assert_contains "$output" "HTTP 200 with an invalid token payload"
assert_not_contains "$output" "temporary proxy response"

run_case transport_error transport-error 0 2
assert_contains "$output" "transport error (curl exit 56)"

run_case permanent_http permanent-http 1 1
assert_contains "$output" "HTTP 401"
assert_not_contains "$output" "retrying"
assert_not_contains "$output" "unauthorized"

run_case exhausted exhausted 1 3
assert_contains "$output" "after 3 attempt(s): HTTP 503"
assert_not_contains "$output" "service unavailable"

missing_permission_status=0
missing_permission_output="$(
  ACTIONS_ID_TOKEN_REQUEST_URL="https://example.test/oidc?request=1" \
    ACTIONS_ID_TOKEN_REQUEST_TOKEN="" \
    GITHUB_ENV="$test_root/missing-permission-env" \
    bash "$script" 2>&1
)" || missing_permission_status=$?
[[ "$missing_permission_status" == 1 ]] || fail "missing permission returned $missing_permission_status, expected 1"
assert_contains "$missing_permission_output" "Ensure 'id-token: write' permission is granted"

echo "PASS: 7 OIDC token retrieval tests"
