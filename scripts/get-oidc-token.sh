#!/usr/bin/env bash

set -euo pipefail

readonly max_attempts="${OIDC_TOKEN_MAX_ATTEMPTS:-4}"
readonly base_delay_seconds="${OIDC_TOKEN_RETRY_BASE_DELAY_SECONDS:-1}"

if [[ -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]]; then
  echo "Error: ACTIONS_ID_TOKEN_REQUEST_TOKEN is not set. Ensure 'id-token: write' permission is granted." >&2
  exit 1
fi

if [[ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]]; then
  echo "Error: ACTIONS_ID_TOKEN_REQUEST_URL is not set. Ensure 'id-token: write' permission is granted." >&2
  exit 1
fi

if [[ -z "${GITHUB_ENV:-}" ]]; then
  echo "Error: GITHUB_ENV is not set." >&2
  exit 1
fi

if [[ ! "$max_attempts" =~ ^[1-9][0-9]*$ ]] || (( max_attempts > 10 )); then
  echo "Error: OIDC_TOKEN_MAX_ATTEMPTS must be an integer from 1 through 10." >&2
  exit 1
fi

if [[ ! "$base_delay_seconds" =~ ^[0-9]+$ ]] || (( base_delay_seconds > 30 )); then
  echo "Error: OIDC_TOKEN_RETRY_BASE_DELAY_SECONDS must be an integer from 0 through 30." >&2
  exit 1
fi

query_separator="?"
if [[ "$ACTIONS_ID_TOKEN_REQUEST_URL" == *"?"* ]]; then
  query_separator="&"
fi
readonly token_request_url="${ACTIONS_ID_TOKEN_REQUEST_URL}${query_separator}audience=sts.amazonaws.com"

response_file="$(mktemp)"
curl_error_file="$(mktemp)"
cleanup() {
  rm -f "$response_file" "$curl_error_file"
}
trap cleanup EXIT

attempt=1
while (( attempt <= max_attempts )); do
  : >"$response_file"
  : >"$curl_error_file"

  curl_exit=0
  http_status="$(curl \
    --silent \
    --show-error \
    --connect-timeout 5 \
    --max-time 15 \
    --output "$response_file" \
    --write-out '%{http_code}' \
    "$token_request_url" \
    --header "Authorization: Bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
    2>"$curl_error_file")" || curl_exit=$?

  retryable=false
  if (( curl_exit != 0 )); then
    failure="transport error (curl exit $curl_exit)"
    retryable=true
  elif [[ "$http_status" =~ ^2[0-9][0-9]$ ]]; then
    oidc_token=""
    if oidc_token="$(jq -er \
      'if (.value | type) == "string" and (.value | length) > 0 then .value else error("missing token value") end' \
      "$response_file" 2>/dev/null)"; then
      printf 'OIDC_TOKEN=%s\n' "$oidc_token" >>"$GITHUB_ENV"
      exit 0
    fi

    failure="HTTP $http_status with an invalid token payload"
    retryable=true
  else
    failure="HTTP ${http_status:-unknown}"
    case "$http_status" in
      408 | 429 | 5??)
        retryable=true
        ;;
    esac
  fi

  if [[ "$retryable" != true ]] || (( attempt == max_attempts )); then
    echo "Error: Failed to retrieve a valid OIDC token after $attempt attempt(s): $failure." >&2
    exit 1
  fi

  jitter_seconds=$((RANDOM % (base_delay_seconds + 1)))
  delay_seconds=$((base_delay_seconds * (1 << (attempt - 1)) + jitter_seconds))
  echo "Warning: OIDC token request attempt $attempt/$max_attempts failed ($failure); retrying in ${delay_seconds}s." >&2
  sleep "$delay_seconds"
  ((attempt += 1))
done
