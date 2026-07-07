#!/usr/bin/env bash
set -euo pipefail

target="${1:?target required}"

: "${CI_CD_OTP_APP:?CI_CD_OTP_APP is required}"
: "${CI_CD_ANSIBLE_INVENTORY:?CI_CD_ANSIBLE_INVENTORY is required}"
: "${CI_CD_DEPLOY_SSH_PRIVATE_KEY:?CI_CD_DEPLOY_SSH_PRIVATE_KEY is required}"
: "${CI_CD_RELEASE_ARTIFACT_KIND:=directory}"
: "${CI_CD_RELEASE_ARTIFACT_PATH:=_build/prod/rel/${CI_CD_OTP_APP}}"

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
  -i "$CI_CD_ANSIBLE_INVENTORY" \
  -e "target_hosts=${target}" \
  -e "ansible_private_key_file=$HOME/.ssh/gitlab_ci_cd_deploy_key" \
  .gitlab-ci-cd-harness/ansible/playbooks/phoenix_blue_green.yml
