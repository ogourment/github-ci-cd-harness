#!/usr/bin/env bash
set -euo pipefail

source_path="${1:?Source path required}"
destination_path="${2:?Destination path required}"
inventory="${ATDD_REMOTE_INVENTORY:-${ACCEPTANCE_REMOTE_INVENTORY:-tmp/atdd_staging.inventory}}"
copy_mode="${ATDD_REMOTE_COPY_MODE:-scp}"
current_link="${ATDD_REMOTE_COPY_CURRENT_LINK:-}"
stats_file="${ATDD_REMOTE_COPY_STATS_FILE:-}"

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

  snapshot_parent=""
  snapshot_basename=""
  validate_snapshot_path() {
    local label="$1"
    local path="$2"

    if [[ "${path}" != /* || "${path}" == "/" || "${path}" == */ ||
      "${path}" == *//* || "${path}" == */./* || "${path}" == */../* ||
      ! "${path}" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
      echo "ATDD rsync snapshot ${label} is not a safe absolute path: ${path}" >&2
      exit 1
    fi

    snapshot_parent="${path%/*}"
    snapshot_basename="${path##*/}"
    if [[ -z "${snapshot_parent}" || "${snapshot_parent}" == "/" ]]; then
      echo "ATDD rsync snapshot ${label} parent must not be root: ${path}" >&2
      exit 1
    fi
  }

  validate_snapshot_path destination "${destination_path}"
  destination_parent="${snapshot_parent}"
  destination_basename="${snapshot_basename}"
  if [[ ! "${destination_basename}" =~ ^acceptance_evidence_([0-9]{1,18})_([0-9]{1,18})$ ]]; then
    echo "ATDD rsync snapshot destination must be named acceptance_evidence_<pipeline>_<job>: ${destination_path}" >&2
    exit 1
  fi
  destination_pipeline_id="${BASH_REMATCH[1]}"
  destination_job_id="${BASH_REMATCH[2]}"

  validate_snapshot_path current-link "${current_link}"
  current_parent="${snapshot_parent}"
  current_basename="${snapshot_basename}"
  if [[ "${current_basename}" != "acceptance_evidence_current" ]]; then
    echo "ATDD rsync snapshot current link must be named acceptance_evidence_current: ${current_link}" >&2
    exit 1
  fi
  if [[ "${destination_path}" == "${current_link}" || "${destination_parent}" != "${current_parent}" ]]; then
    echo "ATDD rsync snapshot destination and current link must be distinct siblings" >&2
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

  remote_quote() {
    local value="${1//\'/\'\\\'\'}"
    printf "'%s'" "${value}"
  }

  quoted_link="$(remote_quote "${current_link}")"
  current_target="$(ssh "${ssh_opts[@]}" "${user}@${host}" \
    "set -eu; link=${quoted_link}; if [ -L \"\${link}\" ]; then readlink -- \"\${link}\"; elif [ -e \"\${link}\" ]; then echo 'ATDD snapshot current path exists but is not a symlink' >&2; exit 1; fi")"

  advance_current=true
  if [[ -n "${current_target}" ]]; then
    validate_snapshot_path current-target "${current_target}"
    current_target_parent="${snapshot_parent}"
    current_target_basename="${snapshot_basename}"
    if [[ "${current_target_parent}" != "${destination_parent}" ||
      ! "${current_target_basename}" =~ ^acceptance_evidence_([0-9]{1,18})_([0-9]{1,18})$ ]]; then
      echo "ATDD rsync snapshot current symlink target is outside the snapshot parent or malformed: ${current_target}" >&2
      exit 1
    fi

    current_pipeline_id="${BASH_REMATCH[1]}"
    current_job_id="${BASH_REMATCH[2]}"
    if ((10#${destination_pipeline_id} < 10#${current_pipeline_id})) ||
      { ((10#${destination_pipeline_id} == 10#${current_pipeline_id})) &&
        ((10#${destination_job_id} < 10#${current_job_id})); }; then
      advance_current=false
    fi
  fi

  printf -v rsync_rsh '%q ' ssh "${ssh_opts[@]}"
  rsync_opts=(
    --archive
    # Acceptance screenshots are regenerated with fresh mtimes even when
    # their bytes are unchanged. Do not preserve those timestamps: rsync
    # otherwise refuses to hard-link identical files from --link-dest.
    --no-times
    --checksum
    --compress
    --delete-delay
    --delay-updates
    --partial
    --protect-args
    --stats
  )

  # A successful previous snapshot is a transfer basis and hard-link source.
  # Identical files therefore cross neither the network nor consume another
  # file's worth of remote storage. The first run remains a normal full copy.
  if [[ -n "${current_target}" ]] &&
    ssh "${ssh_opts[@]}" "${user}@${host}" test -d "${current_target}"; then
    rsync_opts+=("--link-dest=${current_target}")
  fi

  if [[ -n "${stats_file}" ]]; then
    mkdir -p -- "$(dirname -- "${stats_file}")"
    stats_temporary="$(mktemp "${stats_file}.tmp.XXXXXX")"
    cleanup_stats() {
      rm -f -- "${stats_temporary}"
    }
    trap cleanup_stats EXIT

    LC_ALL=C rsync "${rsync_opts[@]}" \
      -e "${rsync_rsh% }" \
      "${source_path%/}/" \
      "${user}@${host}:${destination_path%/}/" \
      > "${stats_temporary}"
    cat -- "${stats_temporary}"
    mv -f -- "${stats_temporary}" "${stats_file}"
    trap - EXIT
  else
    LC_ALL=C rsync "${rsync_opts[@]}" \
      -e "${rsync_rsh% }" \
      "${source_path%/}/" \
      "${user}@${host}:${destination_path%/}/"
  fi

  quoted_destination="$(remote_quote "${destination_path}")"
  quoted_parent="$(remote_quote "${destination_parent}")"
  # Only advance the basis after rsync completed. A retry can safely resume the
  # same destination, while a failed transfer leaves the last complete basis.
  # Re-check the IDs remotely so even a caller outside the resource group
  # cannot win a race by moving the link backward after our initial read.
  if [[ "${advance_current}" == "true" ]]; then
    ssh "${ssh_opts[@]}" "${user}@${host}" \
      "set -eu; link=${quoted_link}; destination=${quoted_destination}; parent=${quoted_parent}; new_pipeline=${destination_pipeline_id}; new_job=${destination_job_id}; if [ -L \"\${link}\" ]; then current=\$(readlink -- \"\${link}\"); [ \"\${current%/*}\" = \"\${parent}\" ] || { echo 'ATDD snapshot current symlink target escaped its parent' >&2; exit 1; }; current_basename=\${current##*/}; current_ids=\${current_basename#acceptance_evidence_}; current_pipeline=\${current_ids%%_*}; current_job=\${current_ids#*_}; case \"\${current_pipeline}:\${current_job}\" in *[!0-9:]*|:*|*:) echo 'ATDD snapshot current symlink target is malformed' >&2; exit 1;; esac; if [ \"\${current_pipeline}\" -gt \"\${new_pipeline}\" ] || { [ \"\${current_pipeline}\" -eq \"\${new_pipeline}\" ] && [ \"\${current_job}\" -gt \"\${new_job}\" ]; }; then echo \"ATDD rsync snapshot current link remains on newer pipeline \${current_pipeline}, job \${current_job}\" >&2; exit 0; fi; elif [ -e \"\${link}\" ]; then echo 'ATDD snapshot current path exists but is not a symlink' >&2; exit 1; fi; temporary=\"\${link}.tmp.\$\$\"; rm -f \"\${temporary}\"; ln -s \"\${destination}\" \"\${temporary}\"; mv -Tf \"\${temporary}\" \"\${link}\""
  else
    echo "ATDD rsync snapshot current link remains on newer pipeline ${current_pipeline_id}, job ${current_job_id}" >&2
  fi
elif [[ "${copy_mode}" == "scp" ]]; then
  scp -C "${copy_opts[@]}" "${ssh_opts[@]}" "${source_path}" "${user}@${host}:${destination_path}"
else
  echo "Unsupported ATDD remote copy mode: ${copy_mode}" >&2
  exit 1
fi
