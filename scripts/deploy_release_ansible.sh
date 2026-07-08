#!/usr/bin/env bash
set -euo pipefail

target="${1:?target required}"

: "${CI_CD_OTP_APP:?CI_CD_OTP_APP is required}"
: "${CI_CD_DEPLOY_SSH_PRIVATE_KEY:?CI_CD_DEPLOY_SSH_PRIVATE_KEY is required}"
: "${CI_CD_RELEASE_ARTIFACT_KIND:=directory}"
: "${CI_CD_RELEASE_ARTIFACT_PATH:=_build/prod/rel/${CI_CD_OTP_APP}}"

CI_CD_DEPLOY_HOST="${CI_CD_DEPLOY_HOST:-}"
CI_CD_DEPLOY_SSH_HOST="${CI_CD_DEPLOY_SSH_HOST:-$CI_CD_DEPLOY_HOST}"

if [ -z "${CI_CD_DEPLOY_SSH_HOST}" ]; then
  echo "CI_CD_DEPLOY_SSH_HOST or CI_CD_DEPLOY_HOST is required" >&2
  exit 2
fi

CI_CD_DEPLOY_SSH_USER="${CI_CD_DEPLOY_SSH_USER:-deploy}"

CI_CD_DEPLOY_INVENTORY_FILE="${CI_CD_ANSIBLE_INVENTORY:-}"
ansible_inventory_tmp=""

if [ -z "${CI_CD_DEPLOY_INVENTORY_FILE}" ]; then
  ansible_inventory_tmp="$(mktemp)"
  trap 'rm -f "${ansible_inventory_tmp}"' EXIT
  cat > "${ansible_inventory_tmp}" <<EOF
[${target}]
${CI_CD_DEPLOY_SSH_HOST:-${CI_CD_DEPLOY_HOST}} ansible_user=${CI_CD_DEPLOY_SSH_USER:-deploy}
EOF
  CI_CD_DEPLOY_INVENTORY_FILE="${ansible_inventory_tmp}"
fi

install -m 700 -d ~/.ssh
printf '%s\n' "$CI_CD_DEPLOY_SSH_PRIVATE_KEY" > ~/.ssh/gitlab_ci_cd_deploy_key
chmod 600 ~/.ssh/gitlab_ci_cd_deploy_key

export CI_CD_RELEASE_ID="$(cat _build/RELEASE_ID)"
export CI_CD_RELEASE_VERSION="$(cat _build/VERSION)"
export CI_CD_RELEASE_ARTIFACT_KIND
export CI_CD_RELEASE_ARTIFACT_PATH

if [ "$CI_CD_RELEASE_ARTIFACT_KIND" = "archive" ]; then
  export CI_CD_RELEASE_ARCHIVE="$(cat _build/RELEASE_ARCHIVE)"
fi

ansible-playbook \
  -i "$CI_CD_DEPLOY_INVENTORY_FILE" \
  -e "target_hosts=${target}" \
  -e "ansible_private_key_file=$HOME/.ssh/gitlab_ci_cd_deploy_key" \
  .gitlab-ci-cd-harness/ansible/playbooks/phoenix_blue_green.yml
