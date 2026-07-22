#!/usr/bin/env bash
set -euo pipefail

test_root="$(mktemp -d)"
trap 'rm -rf "${test_root}"' EXIT

bin_dir="${test_root}/bin"
inventory="${test_root}/inventory"
key_file="${test_root}/deploy-key"
scp_args_log="${test_root}/scp-args"
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
[[ "${file_args[0]}" == "-i" ]]
[[ "${file_args[1]}" == "${key_file}" ]]
[[ "${file_args[8]}" == "${source_file}" ]]
[[ "${file_args[9]}" == "release@staging.example.test:/tmp/remote evidence.json" ]]

source_dir="${test_root}/acceptance evidence"
mkdir -p "${source_dir}/screenshots"
touch "${source_dir}/evidence.json" "${source_dir}/screenshots/step.png"

PATH="${bin_dir}:${PATH}" scripts/atdd_remote_copy.sh \
  "${source_dir}" "/tmp/remote evidence"

mapfile -t directory_args < "${scp_args_log}"
[[ "${directory_args[0]}" == "-r" ]]
[[ "${directory_args[1]}" == "-i" ]]
[[ "${directory_args[9]}" == "${source_dir}" ]]
[[ "${directory_args[10]}" == "release@staging.example.test:/tmp/remote evidence" ]]

missing_source="${test_root}/missing"
if PATH="${bin_dir}:${PATH}" scripts/atdd_remote_copy.sh \
  "${missing_source}" "/tmp/remote" 2> "${test_root}/missing-error"; then
  echo "expected a missing source to fail" >&2
  exit 1
fi

grep -Fq "ATDD remote copy source does not exist: ${missing_source}" \
  "${test_root}/missing-error"

echo "atdd_remote_copy_test: passed"
