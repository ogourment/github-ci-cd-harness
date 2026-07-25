#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fast_deploy="${root}/scripts/deploy_release_fast.sh"
host_deploy="${root}/ansible/roles/phoenix_blue_green/templates/phoenix_deploy.sh.j2"

grep -Fq 'remote_env_assignment "${remote_env_prefix}_CI_PIPELINE_URL" "${CI_PIPELINE_URL:-}"' "${fast_deploy}"
grep -Fq 'git log --format="%h %s" "${before_sha}..${CI_COMMIT_SHA:-HEAD}"' "${fast_deploy}"
grep -Fq 'git log -1 --format="%h %s" "${CI_COMMIT_SHA:-HEAD}"' "${fast_deploy}"

for suffix in GIT_SHA GIT_REF GIT_SUBJECT GIT_MESSAGES CI_PIPELINE_URL; do
  grep -Fq "metadata_value ${suffix}" "${host_deploy}"
done

for variable in GIT_SHA_ENV_VAR GIT_REF_ENV_VAR GIT_SUBJECT_ENV_VAR GIT_MESSAGES_ENV_VAR PIPELINE_URL_ENV_VAR DEPLOYED_AT_ENV_VAR; do
  grep -Fq "append_runtime_env \"\${${variable}}\"" "${host_deploy}"
done

grep -Fq 'CI_COMMIT_SHA="${GIT_SHA}"' "${host_deploy}"
grep -Fq 'CI_COMMIT_TITLE="${GIT_SUBJECT}"' "${host_deploy}"
grep -Fq 'CI_DEPLOY_COMMIT_MESSAGES="${GIT_MESSAGES}"' "${host_deploy}"
grep -Fq 'CI_DEPLOY_COMMIT_MESSAGES_B64="${CI_DEPLOY_COMMIT_MESSAGES_B64}"' "${host_deploy}"
grep -Fq 'CI_PIPELINE_URL="${CI_PIPELINE_URL}"' "${host_deploy}"

fixtures="$(mktemp -d)"
trap 'rm -rf "${fixtures}"' EXIT
writer="${fixtures}/writer.sh"
runtime_env="${fixtures}/runtime.env"
injection_marker="${fixtures}/injected"

awk '/^append_runtime_env\(\) \{/{capture=1} capture{print} capture && /^\}/{exit}' \
  "${host_deploy}" > "${writer}"
# shellcheck source=/dev/null
source "${writer}"

hostile_value="Fix \"quoted\" \$HOME; \`touch ${injection_marker}\`; apostrophe's intact"
append_runtime_env TEST_DEPLOY_METADATA "${hostile_value}" "${runtime_env}"
unset TEST_DEPLOY_METADATA
# shellcheck source=/dev/null
source "${runtime_env}"

[[ "${TEST_DEPLOY_METADATA}" == "${hostile_value}" ]]
[[ ! -e "${injection_marker}" ]]

printf 'deployment metadata contract: ok\n'
