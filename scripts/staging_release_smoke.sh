#!/bin/sh

set -eu

url="${CI_CD_STAGING_SMOKE_URL:-${STAGING_ENVIRONMENT_URL:-}}"
timeout_seconds="${CI_CD_STAGING_SMOKE_TIMEOUT_SECONDS:-30}"

if [ -z "$url" ]; then
  echo "CI_CD_STAGING_SMOKE_URL or STAGING_ENVIRONMENT_URL is required when staging smoke is enabled" >&2
  exit 2
fi

case "$timeout_seconds" in
  ''|*[!0-9]*)
    echo "CI_CD_STAGING_SMOKE_TIMEOUT_SECONDS must be a positive integer" >&2
    exit 2
    ;;
esac

if [ "$timeout_seconds" -eq 0 ]; then
  echo "CI_CD_STAGING_SMOKE_TIMEOUT_SECONDS must be a positive integer" >&2
  exit 2
fi

response_file="$(mktemp)"
trap 'rm -f "$response_file"' EXIT HUP INT TERM

if ! status_code="$(curl --silent --show-error --location \
  --connect-timeout "$timeout_seconds" \
  --max-time "$timeout_seconds" \
  --output "$response_file" \
  --write-out '%{http_code}' \
  "$url")"; then
  echo "Staging browser smoke could not request $url" >&2
  exit 1
fi

case "$status_code" in
  2??) ;;
  *)
    echo "Staging browser smoke expected a 2xx response from $url, got $status_code" >&2
    exit 1
    ;;
esac

if ! grep -Eqi '<!doctype html|<html([[:space:]>])' "$response_file"; then
  echo "Staging browser smoke expected an HTML document from $url" >&2
  exit 1
fi

echo "Staging browser smoke passed: $url returned HTTP $status_code with HTML."
