#!/usr/bin/env bash
set -euo pipefail

hook="${1:-}"
timeout_seconds="${2:-}"
event="${3:-}"
deployment_id="${4:-}"
release_id="${5:-}"
pipeline_id="${6:-}"
environment="${7:-}"
current_color="${8:-}"
target_color="${9:-}"
expires_at_epoch="${10:-}"
state_file="${11:-}"

[[ -n "${hook}" || -n "${state_file}" ]] || exit 0
[[ "${timeout_seconds}" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid lifecycle timeout: ${timeout_seconds}" >&2; exit 64; }

case "${event}" in
  begin-deployment|deployment-complete|deployment-aborted) ;;
  *) echo "Unsupported deployment lifecycle event: ${event}" >&2; exit 64 ;;
esac

if [[ -n "${state_file}" ]]; then
  [[ "${state_file}" == /* ]] || { echo "Lifecycle state file must be absolute: ${state_file}" >&2; exit 64; }

  case "${event}" in
    begin-deployment)
      state_tmp="$(mktemp "${state_file}.XXXXXX")"
      trap 'rm -f "${state_tmp}"' EXIT
      printf '%s\n%s\n' "${deployment_id}" "${expires_at_epoch}" > "${state_tmp}"
      chmod 0644 "${state_tmp}"
      mv "${state_tmp}" "${state_file}"
      trap - EXIT
      ;;
    deployment-complete|deployment-aborted)
      if [[ -f "${state_file}" ]] && [[ "$(head -n 1 "${state_file}")" == "${deployment_id}" ]]; then
        rm -f "${state_file}"
      fi
      ;;
  esac
fi

[[ -n "${hook}" ]] || exit 0
[[ -x "${hook}" ]] || { echo "Deployment lifecycle hook is not executable: ${hook}" >&2; exit 66; }

env \
  CI_CD_DEPLOYMENT_EVENT="${event}" \
  CI_CD_DEPLOYMENT_ID="${deployment_id}" \
  CI_CD_DEPLOYMENT_RELEASE_ID="${release_id}" \
  CI_CD_DEPLOYMENT_PIPELINE_ID="${pipeline_id}" \
  CI_CD_DEPLOYMENT_ENVIRONMENT="${environment}" \
  CI_CD_DEPLOYMENT_CURRENT_COLOR="${current_color}" \
  CI_CD_DEPLOYMENT_TARGET_COLOR="${target_color}" \
  CI_CD_DEPLOYMENT_EXPIRES_AT_EPOCH="${expires_at_epoch}" \
  timeout --signal=TERM "${timeout_seconds}s" "${hook}" "${event}"
