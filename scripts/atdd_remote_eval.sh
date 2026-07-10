#!/usr/bin/env bash
set -euo pipefail

expr="${1:?Elixir expression required}"
inventory="${ATDD_REMOTE_INVENTORY:-${ACCEPTANCE_REMOTE_INVENTORY:-tmp/atdd_staging.inventory}}"
app_name="${ATDD_REMOTE_APP_NAME:-${ACCEPTANCE_REMOTE_APP_NAME:-${ACCEPTANCE_APP_OTP_NAME:-}}}"
app_root="${ATDD_REMOTE_APP_ROOT:-${ACCEPTANCE_REMOTE_APP_ROOT:-/opt/${app_name}}}"
env_dir="${ATDD_REMOTE_ENV_DIR:-${ACCEPTANCE_REMOTE_ENV_DIR:-/etc/${app_name}}}"
env_file="${ATDD_REMOTE_ENV_FILE:-${ACCEPTANCE_REMOTE_ENV_FILE:-${env_dir}/${app_name}.env}}"
app_user="${ATDD_REMOTE_APP_USER:-${ACCEPTANCE_REMOTE_APP_USER:-${app_name}}}"
slot_file="${ATDD_REMOTE_SLOT_FILE:-${app_root}/ACTIVE_SLOT}"
# Hosts with a different slot layout (e.g. blue/green colors living directly
# under the app root, per-color env files under /etc/default) override these
# patterns; {{slot}} is replaced with the slot file's content on the host.
slot_dir_pattern="${ATDD_REMOTE_SLOT_DIR_PATTERN:-${ACCEPTANCE_REMOTE_SLOT_DIR_PATTERN:-${app_root}/slots/{{slot}}}}"
slot_env_pattern="${ATDD_REMOTE_SLOT_ENV_PATTERN:-${ACCEPTANCE_REMOTE_SLOT_ENV_PATTERN:-${env_dir}/${app_name}-{{slot}}.env}}"

if [[ -z "${app_name}" ]]; then
  echo "ATDD remote app name is required; set ATDD_REMOTE_APP_NAME or ACCEPTANCE_APP_OTP_NAME" >&2
  exit 2
fi

if [[ ! -f "${inventory}" ]]; then
  echo "ATDD remote inventory does not exist: ${inventory}" >&2
  exit 1
fi

inventory_value() {
  local key="$1"
  awk -v key="${key}" '
    !/^[[:space:]]*(#|\[|$)/ {
      for (i = 1; i <= NF; i++) {
        split($i, pair, "=")
        if (pair[1] == key) {
          value = substr($i, length(key) + 2)
          gsub(/^'\''|'\''$/, "", value)
          print value
          exit
        }
      }
    }
  ' "${inventory}"
}

host_line="$(awk '!/^[[:space:]]*(#|\[|$)/ { print; exit }' "${inventory}")"
host_alias="$(awk '{ print $1; exit }' <<<"${host_line}")"
host="$(inventory_value ansible_host)"
user="$(inventory_value ansible_user)"
key_file="$(inventory_value ansible_private_key_file)"

host="${host:-${host_alias}}"
user="${user:-deploy}"
key_file="${ATDD_REMOTE_SSH_KEY_FILE:-${ACCEPTANCE_REMOTE_SSH_KEY_FILE:-${key_file/#\~/${HOME}}}}"

if [[ -z "${key_file}" || ! -f "${key_file}" ]]; then
  echo "ATDD remote SSH private key does not exist: ${key_file}" >&2
  exit 1
fi

ssh_opts=(
  -i "${key_file}"
  -o IdentitiesOnly=yes
  -o IdentityAgent=none
  -o StrictHostKeyChecking=accept-new
)

expr_b64="$(printf '%s' "${expr}" | base64 -w 0)"

ssh "${ssh_opts[@]}" "${user}@${host}" \
  ATDD_EVAL_B64="${expr_b64}" \
  ATDD_APP_ROOT="${app_root}" \
  ATDD_ENV_DIR="${env_dir}" \
  ATDD_ENV_FILE="${env_file}" \
  ATDD_APP_USER="${app_user}" \
  ATDD_APP_NAME="${app_name}" \
  ATDD_SLOT_FILE="${slot_file}" \
  ATDD_SLOT_DIR_PATTERN="${slot_dir_pattern}" \
  ATDD_SLOT_ENV_PATTERN="${slot_env_pattern}" \
  'bash -s' <<'REMOTE'
set -euo pipefail

expr="$(printf '%s' "${ATDD_EVAL_B64}" | base64 -d)"
slot=""
release_dir="${ATDD_APP_ROOT}/current"
slot_env=""

if [[ -f "${ATDD_SLOT_FILE}" ]]; then
  slot="$(cat "${ATDD_SLOT_FILE}")"
  # sed rather than ${var//…}: literal braces inside a brace-pattern
  # substitution parse ambiguously across bash versions.
  release_dir="$(printf '%s' "${ATDD_SLOT_DIR_PATTERN}" | sed "s|{{slot}}|${slot}|g")"
  slot_env="$(printf '%s' "${ATDD_SLOT_ENV_PATTERN}" | sed "s|{{slot}}|${slot}|g")"
fi

run_as_app_user() {
  if [[ "$(id -un)" == "${ATDD_APP_USER}" ]]; then
    env "$@"
  else
    sudo -u "${ATDD_APP_USER}" env "$@"
  fi
}

run_as_app_user \
    ATDD_EVAL_EXPR="${expr}" \
    ATDD_APP_ROOT="${ATDD_APP_ROOT}" \
    ATDD_ENV_DIR="${ATDD_ENV_DIR}" \
    ATDD_ENV_FILE="${ATDD_ENV_FILE}" \
    ATDD_APP_NAME="${ATDD_APP_NAME}" \
    ATDD_RELEASE_SLOT="${slot}" \
    ATDD_RELEASE_DIR="${release_dir}" \
    ATDD_SLOT_ENV_FILE="${slot_env}" \
  bash -lc '
    set -euo pipefail
    set -a
    if [[ -f "${ATDD_ENV_FILE}" ]]; then
      source "${ATDD_ENV_FILE}"
    fi
    if [[ -n "${ATDD_SLOT_ENV_FILE}" && -f "${ATDD_SLOT_ENV_FILE}" ]]; then
      source "${ATDD_SLOT_ENV_FILE}"
    fi
    set +a
    cd "${ATDD_RELEASE_DIR}"
    bin/${ATDD_APP_NAME} eval "${ATDD_EVAL_EXPR}"
  '
REMOTE
