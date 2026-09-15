#!/usr/bin/env bash

set -euo pipefail

readonly repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly configure_script="$repo_root/scripts/configure-aws-profiles.sh"
readonly verify_script="$repo_root/scripts/verify-aws-profiles.sh"
readonly fake_bin="$repo_root/tests/fake-bin"
test_root="$(mktemp -d)"
output=""
status=0
case_root=""
tests=0

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
  [[ "$haystack" == *"$needle"* ]] || fail "expected output to contain: $needle; output: $haystack"
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" != *"$needle"* ]] || fail "expected output not to contain: $needle"
}

# Runs a script with the fake aws command and a temporary HOME. Extra arguments are environment assignments.
run_script() {
  local name="$1"
  local script="$2"
  shift 2

  case_root="$test_root/$name"
  mkdir -p "$case_root/home"
  : >"$case_root/aws-calls"
  status=0
  output="$(
    env PATH="$fake_bin:$PATH" \
      HOME="$case_root/home" \
      OIDC_TOKEN="test.oidc.token" \
      FAKE_AWS_STATE="$case_root/aws-calls" \
      "$@" \
      bash "$script" 2>&1
  )" || status=$?
  ((tests += 1))
}

assert_status() {
  [[ "$status" == "$1" ]] || fail "$(basename "$case_root") returned $status, expected $1; output: $output"
}

readonly two_profiles='dev:
  role-arn: arn:aws:iam::123456789012:role/DevRole
  region: us-east-1
prod:
  role-arn: arn:aws:iam::123456789012:role/ProdRole'

run_script configures_profiles "$configure_script" PROFILES="$two_profiles" DURATION_SECONDS=7200
assert_status 0
credentials="$(<"$case_root/home/.aws/credentials")"
config="$(<"$case_root/home/.aws/config")"
assert_contains "$credentials" $'[dev]\naws_access_key_id = AKIA-dev\naws_secret_access_key = secret-dev\naws_session_token = session-dev'
assert_contains "$credentials" $'[prod]\naws_access_key_id = AKIA-prod'
assert_contains "$config" $'[profile dev]\nregion = us-east-1'
assert_contains "$config" $'[profile prod]\nregion = us-west-2'
assert_contains "$(<"$case_root/aws-calls")" "dev arn:aws:iam::123456789012:role/DevRole 7200 us-east-1"
assert_contains "$(<"$case_root/aws-calls")" "prod arn:aws:iam::123456789012:role/ProdRole 7200 us-west-2"
assert_not_contains "$output" "secret-dev"
assert_not_contains "$output" "session-dev"
assert_not_contains "$output" "test.oidc.token"

run_script default_duration "$configure_script" PROFILES="$two_profiles"
assert_status 0
assert_contains "$(<"$case_root/aws-calls")" "dev arn:aws:iam::123456789012:role/DevRole 3600 us-east-1"

run_script sts_error "$configure_script" \
  PROFILES=$'dev:\n  role-arn: arn:aws:iam::123456789012:role/DevRole\ndenied:\n  role-arn: arn:aws:iam::123456789012:role/DeniedRole' \
  DURATION_SECONDS=7200
assert_status 1
assert_contains "$output" "Error: Failed to assume role arn:aws:iam::123456789012:role/DeniedRole for profile denied: An error occurred (ValidationError) when calling the AssumeRoleWithWebIdentity operation: The requested DurationSeconds exceeds the MaxSessionDuration set for this role."
assert_contains "$output" "no profiles were written"
[[ ! -e "$case_root/home/.aws/credentials" ]] || fail "credentials were written although a profile failed"
assert_not_contains "$output" "secret-dev"
assert_not_contains "$output" "test.oidc.token"

run_script malformed_response "$configure_script" PROFILES=$'broken:\n  role-arn: arn:aws:iam::123456789012:role/MalformedRole'
assert_status 1
assert_contains "$output" "Error: The response for role arn:aws:iam::123456789012:role/MalformedRole for profile broken does not contain credentials."

run_script missing_role_arn "$configure_script" PROFILES=$'dev:\n  region: us-east-1'
assert_status 1
assert_contains "$output" "Error: role-arn is not specified for profile dev."
[[ ! -s "$case_root/aws-calls" ]] || fail "missing_role_arn called STS"

run_script invalid_duration "$configure_script" PROFILES="$two_profiles" DURATION_SECONDS=100
assert_status 1
assert_contains "$output" "Error: duration-seconds must be an integer from 900 through 43200."
[[ ! -s "$case_root/aws-calls" ]] || fail "invalid_duration called STS"

run_script verifies_profiles "$verify_script" PROFILES="$two_profiles"
assert_status 0
assert_contains "$output" "Profile dev is valid"
assert_contains "$output" "Profile prod is valid"
assert_contains "$(<"$case_root/aws-calls")" "dev us-east-1"
assert_contains "$(<"$case_root/aws-calls")" "prod us-west-2"

run_script verification_error "$verify_script" \
  PROFILES=$'dev:\n  role-arn: arn:aws:iam::123456789012:role/DevRole\nexpired:\n  role-arn: arn:aws:iam::123456789012:role/ExpiredRole'
assert_status 1
assert_contains "$output" "Error: Verification failed for profile expired: An error occurred (ExpiredToken) when calling the GetCallerIdentity operation: The security token included in the request is expired"
assert_contains "$output" "Profile dev is valid"

echo "PASS: $tests AWS profile tests"
