#!/usr/bin/env bash
set -euo pipefail

test_root="$(mktemp -d)"
trap 'rm -rf "${test_root}"' EXIT

bin_dir="${test_root}/bin"
inventory="${test_root}/inventory"
key_file="${test_root}/deploy-key"
scp_args_log="${test_root}/scp-args"
rsync_args_log="${test_root}/rsync-args"
ssh_args_log="${test_root}/ssh-args"
mkdir -p "${bin_dir}"
touch "${key_file}"

printf '%s\n' \
  "staging ansible_host=staging.example.test ansible_user=release ansible_private_key_file='${key_file}'" \
  > "${inventory}"

apply_fake_scp() {
  printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s\n'\'' "$@" > "$SCP_ARGS_LOG"' > "${bin_dir}/scp"
  chmod +x "${bin_dir}/scp"
}

apply_fake_scp
export SCP_ARGS_LOG="${scp_args_log}"
export ATDD_REMOTE_INVENTORY="${inventory}"

source_file="${test_root}/evidence.json"
touch "${source_file}"

PATH="${bin_dir}:${PATH}" scripts/atdd_remote_copy.sh \
  "${source_file}" "/tmp/remote evidence.json"

mapfile -t file_args < "${scp_args_log}"
[[ "${file_args[*]}" != *" -r "* ]]
[[ "${file_args[0]}" == "-C" ]]
[[ "${file_args[1]}" == "-i" ]]
[[ "${file_args[2]}" == "${key_file}" ]]
[[ "${file_args[9]}" == "${source_file}" ]]
[[ "${file_args[10]}" == "release@staging.example.test:/tmp/remote evidence.json" ]]

source_dir="${test_root}/acceptance evidence"
mkdir -p "${source_dir}/screenshots"
touch "${source_dir}/evidence.json" "${source_dir}/screenshots/step.png"

PATH="${bin_dir}:${PATH}" scripts/atdd_remote_copy.sh \
  "${source_dir}" "/tmp/remote evidence"

mapfile -t directory_args < "${scp_args_log}"
[[ "${directory_args[0]}" == "-C" ]]
[[ "${directory_args[1]}" == "-r" ]]
[[ "${directory_args[2]}" == "-i" ]]
[[ "${directory_args[10]}" == "${source_dir}" ]]
[[ "${directory_args[11]}" == "release@staging.example.test:/tmp/remote evidence" ]]

missing_source="${test_root}/missing"
if PATH="${bin_dir}:${PATH}" scripts/atdd_remote_copy.sh \
  "${missing_source}" "/tmp/remote" 2> "${test_root}/missing-error"; then
  echo "expected a missing source to fail" >&2
  exit 1
fi

grep -Fq "ATDD remote copy source does not exist: ${missing_source}" \
  "${test_root}/missing-error"

printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s\n'\'' "$@" > "$RSYNC_ARGS_LOG"' > "${bin_dir}/rsync"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf '\''%s\n'\'' "$@" >> "$SSH_ARGS_LOG"' \
  'if [[ "$*" == *"readlink --"* && "$*" != *"new_pipeline="* ]]; then printf '\''%s\n'\'' "${FAKE_CURRENT_TARGET:-}"; fi' \
  'exit 0' \
  > "${bin_dir}/ssh"
chmod +x "${bin_dir}/rsync" "${bin_dir}/ssh"
export RSYNC_ARGS_LOG="${rsync_args_log}"
export SSH_ARGS_LOG="${ssh_args_log}"
export ATDD_REMOTE_COPY_MODE="rsync-snapshots"
export ATDD_REMOTE_COPY_CURRENT_LINK="/opt/example/acceptance_evidence_current"
export FAKE_CURRENT_TARGET="/opt/example/acceptance_evidence_122_455"

PATH="${bin_dir}:${PATH}" scripts/atdd_remote_copy.sh \
  "${source_dir}" "/opt/example/acceptance_evidence_123_456"

mapfile -t rsync_args < "${rsync_args_log}"
rsync_args_joined=" ${rsync_args[*]} "
[[ "${rsync_args_joined}" == *" --archive "* ]]
[[ "${rsync_args_joined}" == *" --checksum "* ]]
[[ "${rsync_args_joined}" == *" --compress "* ]]
[[ "${rsync_args_joined}" == *" --delete-delay "* ]]
[[ "${rsync_args_joined}" == *" --delay-updates "* ]]
[[ "${rsync_args_joined}" == *" --partial "* ]]
[[ "${rsync_args_joined}" == *" --protect-args "* ]]
[[ "${rsync_args_joined}" == *" --link-dest=/opt/example/acceptance_evidence_122_455 "* ]]
[[ "${rsync_args_joined}" == *" ${source_dir}/ "* ]]
[[ "${rsync_args_joined}" == *" release@staging.example.test:/opt/example/acceptance_evidence_123_456/ "* ]]

grep -Fq 'command -v rsync >/dev/null 2>&1' "${ssh_args_log}"
grep -Fq 'test' "${ssh_args_log}"
grep -Fq '/opt/example/acceptance_evidence_current' "${ssh_args_log}"
grep -Fq '/opt/example/acceptance_evidence_123_456' "${ssh_args_log}"

if PATH="${bin_dir}:${PATH}" ATDD_REMOTE_COPY_CURRENT_LINK= \
  scripts/atdd_remote_copy.sh "${source_dir}" "/opt/example/other" \
  2> "${test_root}/missing-current-link-error"; then
  echo "expected rsync snapshot mode without a current link to fail" >&2
  exit 1
fi

grep -Fq "ATDD_REMOTE_COPY_CURRENT_LINK is required" \
  "${test_root}/missing-current-link-error"

expect_invalid_snapshot_path() {
  local destination="$1"
  local link="$2"
  local expected="$3"
  local error_file="${test_root}/invalid-$RANDOM"
  if PATH="${bin_dir}:${PATH}" ATDD_REMOTE_COPY_CURRENT_LINK="${link}" \
    scripts/atdd_remote_copy.sh "${source_dir}" "${destination}" 2> "${error_file}"; then
    echo "expected invalid snapshot paths to fail: ${destination} ${link}" >&2
    exit 1
  fi
  grep -Fq "${expected}" "${error_file}"
}

expect_invalid_snapshot_path \
  "relative/acceptance_evidence_1_2" "/opt/example/acceptance_evidence_current" \
  "not a safe absolute path"
expect_invalid_snapshot_path \
  "/acceptance_evidence_1_2" "/acceptance_evidence_current" \
  "parent must not be root"
expect_invalid_snapshot_path \
  "/opt/example/not-evidence" "/opt/example/acceptance_evidence_current" \
  "must be named acceptance_evidence_<pipeline>_<job>"
expect_invalid_snapshot_path \
  "/opt/example/acceptance_evidence_1_2" "/opt/other/acceptance_evidence_current" \
  "must be distinct siblings"
expect_invalid_snapshot_path \
  "/opt/example/acceptance_evidence_1_2" "/opt/example/not-current" \
  "must be named acceptance_evidence_current"

export FAKE_CURRENT_TARGET="/opt/other/acceptance_evidence_122_455"
expect_invalid_snapshot_path \
  "/opt/example/acceptance_evidence_123_456" "/opt/example/acceptance_evidence_current" \
  "current symlink target is outside the snapshot parent"

# Serialized older pipelines may still execute later, but cannot move the
# shared current symlink backward.
: > "${ssh_args_log}"
export FAKE_CURRENT_TARGET="/opt/example/acceptance_evidence_200_10"
PATH="${bin_dir}:${PATH}" scripts/atdd_remote_copy.sh \
  "${source_dir}" "/opt/example/acceptance_evidence_199_999" \
  2> "${test_root}/older-pipeline-error"
grep -Fq "current link remains on newer pipeline 200, job 10" \
  "${test_root}/older-pipeline-error"
if grep -Fq 'mv -Tf' "${ssh_args_log}"; then
  echo "expected an older pipeline not to update the current symlink" >&2
  exit 1
fi

grep -Fq 'resource_group: "$CI_PROJECT_PATH_SLUG-acceptance-evidence"' \
  templates/acceptance.yml

echo "atdd_remote_copy_test: passed"
