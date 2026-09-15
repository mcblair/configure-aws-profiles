#!/usr/bin/env bash

set -euo pipefail

if [[ -z "${PROFILES:-}" ]]; then
  echo "Error: PROFILES is not set." >&2
  exit 1
fi

if [[ -z "${OIDC_TOKEN:-}" ]]; then
  echo "Error: OIDC_TOKEN is not set." >&2
  exit 1
fi

export DEFAULT_REGION="${DEFAULT_REGION:-us-west-2}"
readonly duration_seconds="${DURATION_SECONDS:-3600}"

# STS accepts session durations from 15 minutes through 12 hours.
if [[ ! "$duration_seconds" =~ ^[0-9]+$ ]] || (( duration_seconds < 900 || duration_seconds > 43200 )); then
  echo "Error: duration-seconds must be an integer from 900 through 43200." >&2
  exit 1
fi

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

# Assumes the role for one profile and writes its credentials and config entries to files in the profile's
# work directory. Profiles run in parallel, and the entries are appended to ~/.aws only after every profile succeeds.
configure_profile() {
  local profile_name="$1"
  local profile_dir="$2"
  local region role_arn credentials access_key_id secret_access_key session_token

  mkdir -p "$profile_dir"
  region="$(PROFILE_NAME="$profile_name" yq e '.[strenv(PROFILE_NAME)].region // strenv(DEFAULT_REGION)' <<<"$PROFILES")"
  role_arn="$(PROFILE_NAME="$profile_name" yq e '.[strenv(PROFILE_NAME)].role-arn // ""' <<<"$PROFILES")"

  if [[ -z "$role_arn" ]]; then
    echo "Error: role-arn is not specified for profile $profile_name." >&2
    return 1
  fi

  echo "Configuring profile $profile_name with region $region and role $role_arn"

  if ! credentials="$(aws sts assume-role-with-web-identity \
    --role-arn "$role_arn" \
    --role-session-name "$profile_name" \
    --web-identity-token "$OIDC_TOKEN" \
    --duration-seconds "$duration_seconds" \
    --region "$region" \
    --output json \
    2>"$profile_dir/error")"; then
    echo "Error: Failed to assume role $role_arn for profile $profile_name: $(<"$profile_dir/error")" >&2
    return 1
  fi

  if ! access_key_id="$(jq -er '.Credentials.AccessKeyId' <<<"$credentials")" ||
    ! secret_access_key="$(jq -er '.Credentials.SecretAccessKey' <<<"$credentials")" ||
    ! session_token="$(jq -er '.Credentials.SessionToken' <<<"$credentials")"; then
    echo "Error: The response for role $role_arn for profile $profile_name does not contain credentials." >&2
    return 1
  fi

  printf '[%s]\naws_access_key_id = %s\naws_secret_access_key = %s\naws_session_token = %s\n' \
    "$profile_name" "$access_key_id" "$secret_access_key" "$session_token" >"$profile_dir/credentials"
  printf '[profile %s]\nregion = %s\n' "$profile_name" "$region" >"$profile_dir/config"

  echo "Assumed role $role_arn for profile $profile_name"
}

pids=()
for index in "${!profile_names[@]}"; do
  configure_profile "${profile_names[$index]}" "$work_dir/$index" &
  pids+=("$!")
done

failed=false
for pid in "${pids[@]}"; do
  if ! wait "$pid"; then
    failed=true
  fi
done

if [[ "$failed" == true ]]; then
  echo "Error: One or more profiles could not be configured, so no profiles were written." >&2
  exit 1
fi

mkdir -p "$HOME/.aws"
for index in "${!profile_names[@]}"; do
  cat "$work_dir/$index/credentials" >>"$HOME/.aws/credentials"
  cat "$work_dir/$index/config" >>"$HOME/.aws/config"
  echo "Successfully configured profile ${profile_names[$index]}"
done
