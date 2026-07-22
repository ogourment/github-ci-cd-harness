#!/usr/bin/env bash
set -euo pipefail

source_path="${1:?Source path required}"
destination_path="${2:?Destination path required}"
inventory="${ATDD_REMOTE_INVENTORY:-${ACCEPTANCE_REMOTE_INVENTORY:-tmp/atdd_staging.inventory}}"

if [[ ! -f "${source_path}" && ! -d "${source_path}" ]]; then
  echo "ATDD remote copy source does not exist: ${source_path}" >&2
  exit 1
fi

copy_opts=()
if [[ -d "${source_path}" ]]; then
  copy_opts=(-r)
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

scp "${copy_opts[@]}" "${ssh_opts[@]}" "${source_path}" "${user}@${host}:${destination_path}"
