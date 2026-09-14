#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 post|wait-safe|wait-active <curl-config> <url> [timeout-sec] [interval-sec]" >&2
  exit 64
}

ACTION="${1:-}"
CURL_CONFIG="${2:-}"
URL="${3:-}"
TIMEOUT_SEC="${4:-60}"
INTERVAL_SEC="${5:-2}"

[[ -n "${ACTION}" && -r "${CURL_CONFIG}" && -n "${URL}" ]] || usage
[[ "${TIMEOUT_SEC}" =~ ^[0-9]+$ && "${INTERVAL_SEC}" =~ ^[0-9]+$ ]] || usage

request() {
  local method="$1"
  curl --fail --silent --show-error --max-time 5 \
    --config "${CURL_CONFIG}" \
    --request "${method}" \
    "${URL}"
}

case "${ACTION}" in
  post)
    request POST
    ;;

  wait-safe|wait-active)
    deadline=$(( $(date +%s) + TIMEOUT_SEC ))

    while true; do
      body="$(request GET || true)"

      if [[ "${ACTION}" == "wait-safe" ]] &&
         jq -e '.state == "draining" and .safe_to_stop == true' <<<"${body}" >/dev/null 2>&1; then
        printf '%s\n' "${body}"
        exit 0
      fi

      if [[ "${ACTION}" == "wait-active" ]] &&
         jq -e '.state == "active" and .claim_new_work == true' <<<"${body}" >/dev/null 2>&1; then
        printf '%s\n' "${body}"
        exit 0
      fi

      if [[ $(date +%s) -ge ${deadline} ]]; then
        echo "ERROR: application lifecycle ${ACTION} timed out after ${TIMEOUT_SEC}s at ${URL}" >&2
        exit 75
      fi

      sleep "${INTERVAL_SEC}"
    done
    ;;

  *)
    usage
    ;;
esac
