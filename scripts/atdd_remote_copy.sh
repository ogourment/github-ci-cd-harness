#!/usr/bin/env bash
set -euo pipefail

source_path="${1:?Source path required}"
destination_path="${2:?Destination path required}"
inventory="${ATDD_REMOTE_INVENTORY:-${ACCEPTANCE_REMOTE_INVENTORY:-tmp/atdd_staging.inventory}}"
copy_mode="${ATDD_REMOTE_COPY_MODE:-scp}"
current_link="${ATDD_REMOTE_COPY_CURRENT_LINK:-}"

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

if [[ "${copy_mode}" == "rsync-snapshots" ]]; then
  if [[ ! -d "${source_path}" ]]; then
    echo "ATDD rsync snapshot source must be a directory: ${source_path}" >&2
    exit 1
  fi

  if [[ -z "${current_link}" ]]; then
    echo "ATDD_REMOTE_COPY_CURRENT_LINK is required for rsync-snapshots mode" >&2
    exit 1
  fi

  if ! command -v rsync >/dev/null 2>&1; then
    echo "ATDD rsync snapshot mode requires rsync in the CI job" >&2
    exit 1
  fi

  if ! ssh "${ssh_opts[@]}" "${user}@${host}" 'command -v rsync >/dev/null 2>&1'; then
    echo "ATDD rsync snapshot mode requires rsync on ${host}" >&2
    exit 1
  fi

  printf -v rsync_rsh '%q ' ssh "${ssh_opts[@]}"
  rsync_opts=(
    --archive
    --checksum
    --compress
    --delete-delay
    --delay-updates
    --partial
    --protect-args
  )

  # A successful previous snapshot is a transfer basis and hard-link source.
  # Identical files therefore cross neither the network nor consume another
  # file's worth of remote storage. The first run remains a normal full copy.
  if ssh "${ssh_opts[@]}" "${user}@${host}" test -d "${current_link}"; then
    rsync_opts+=("--link-dest=${current_link}")
  fi

  rsync "${rsync_opts[@]}" \
    -e "${rsync_rsh% }" \
    "${source_path%/}/" \
    "${user}@${host}:${destination_path%/}/"

  remote_quote() {
    local value="${1//\'/\'\\\'\'}"
    printf "'%s'" "${value}"
  }

  quoted_link="$(remote_quote "${current_link}")"
  quoted_destination="$(remote_quote "${destination_path}")"
  # Only advance the basis after rsync completed. A retry can safely resume the
  # same destination, while a failed transfer leaves the last complete basis.
  ssh "${ssh_opts[@]}" "${user}@${host}" \
    "set -eu; link=${quoted_link}; destination=${quoted_destination}; temporary=\"\${link}.tmp.\$\$\"; rm -f \"\${temporary}\"; ln -s \"\${destination}\" \"\${temporary}\"; mv -Tf \"\${temporary}\" \"\${link}\""
elif [[ "${copy_mode}" == "scp" ]]; then
  scp -C "${copy_opts[@]}" "${ssh_opts[@]}" "${source_path}" "${user}@${host}:${destination_path}"
else
  echo "Unsupported ATDD remote copy mode: ${copy_mode}" >&2
  exit 1
fi
