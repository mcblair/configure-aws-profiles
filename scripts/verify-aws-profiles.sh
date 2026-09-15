#!/usr/bin/env bash

set -euo pipefail

if [[ -z "${PROFILES:-}" ]]; then
  echo "Error: PROFILES is not set." >&2
  exit 1
fi

export DEFAULT_REGION="${DEFAULT_REGION:-us-west-2}"

profile_names_output="$(yq e 'keys | .[]' <<<"$PROFILES")"
mapfile -t profile_names <<<"$profile_names_output"
if [[ -z "${profile_names[0]:-}" ]]; then
  echo "Error: PROFILES does not define any profiles." >&2
  exit 1
fi

work_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

# Calls sts:GetCallerIdentity with one profile's credentials. Profiles are verified in parallel.
verify_profile() {
  local profile_name="$1"
  local error_file="$2"
  local region

  region="$(PROFILE_NAME="$profile_name" yq e '.[strenv(PROFILE_NAME)].region // strenv(DEFAULT_REGION)' <<<"$PROFILES")"

  echo "Verifying profile $profile_name in region $region"

  if ! aws sts get-caller-identity --profile "$profile_name" --region "$region" --output json >/dev/null 2>"$error_file"; then
    echo "Error: Verification failed for profile $profile_name: $(<"$error_file")" >&2
    return 1
  fi

  echo "Profile $profile_name is valid"
}

pids=()
for index in "${!profile_names[@]}"; do
  verify_profile "${profile_names[$index]}" "$work_dir/$index.error" &
  pids+=("$!")
done

failed=false
for pid in "${pids[@]}"; do
  if ! wait "$pid"; then
    failed=true
  fi
done

if [[ "$failed" == true ]]; then
  echo "Error: One or more profiles failed verification." >&2
  exit 1
fi
