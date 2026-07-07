#!/usr/bin/env bash
set -euo pipefail

target="${1:?target required}"

: "${CI_CD_OTP_APP:?CI_CD_OTP_APP is required}"
: "${CI_CD_DEPLOY_HOST:?CI_CD_DEPLOY_HOST is required}"
: "${CI_CD_DEPLOY_SSH_HOST:=${CI_CD_DEPLOY_HOST}}"
: "${CI_CD_DEPLOY_SSH_USER:=deploy}"
: "${CI_CD_DEPLOY_SSH_PRIVATE_KEY:?CI_CD_DEPLOY_SSH_PRIVATE_KEY is required}"
: "${CI_CD_RELEASE_ARTIFACT_KIND:=directory}"
: "${CI_CD_RELEASE_ARTIFACT_PATH:=_build/prod/rel/${CI_CD_OTP_APP}}"
: "${CI_CD_REMOTE_RELEASES_ROOT:=/home/deploy/releases}"
: "${CI_CD_REMOTE_DEPLOY_SCRIPT:?CI_CD_REMOTE_DEPLOY_SCRIPT is required}"
: "${CI_CD_RUN_MIGRATIONS:=migrate}"

release_id="$(cat _build/RELEASE_ID)"
version="$(cat _build/VERSION)"

install -m 700 -d ~/.ssh
printf '%s\n' "$CI_CD_DEPLOY_SSH_PRIVATE_KEY" > ~/.ssh/gitlab_ci_cd_deploy_key
chmod 600 ~/.ssh/gitlab_ci_cd_deploy_key
ssh-keyscan -H "$CI_CD_DEPLOY_SSH_HOST" >> ~/.ssh/known_hosts

ssh_opts=(
  -i "$HOME/.ssh/gitlab_ci_cd_deploy_key"
  -o IdentitiesOnly=yes
  -o IdentityAgent=none
)

retry() {
  local attempt=1 max_attempts=4 sleep_seconds=5

  while true; do
    "$@" && return 0

    if [ "$attempt" -ge "$max_attempts" ]; then
      return 1
    fi

    echo "Command failed; retrying in ${sleep_seconds}s (attempt ${attempt}/${max_attempts})" >&2
    sleep "$sleep_seconds"
    attempt=$((attempt + 1))
    sleep_seconds=$((sleep_seconds * 2))
  done
}

case "$CI_CD_RELEASE_ARTIFACT_KIND" in
  directory)
    remote_release_dir="${CI_CD_REMOTE_RELEASES_ROOT%/}/${release_id}"
    retry ssh "${ssh_opts[@]}" "$CI_CD_DEPLOY_SSH_USER@$CI_CD_DEPLOY_SSH_HOST" "mkdir -p '$remote_release_dir'"
    retry rsync -az --delete -e "ssh -i $HOME/.ssh/gitlab_ci_cd_deploy_key -o IdentitiesOnly=yes -o IdentityAgent=none" \
      "${CI_CD_RELEASE_ARTIFACT_PATH%/}/" \
      "$CI_CD_DEPLOY_SSH_USER@$CI_CD_DEPLOY_SSH_HOST:$remote_release_dir/"
    retry ssh "${ssh_opts[@]}" "$CI_CD_DEPLOY_SSH_USER@$CI_CD_DEPLOY_SSH_HOST" \
      "sudo '$CI_CD_REMOTE_DEPLOY_SCRIPT' '$release_id' '$CI_CD_RUN_MIGRATIONS'"
    ;;
  archive)
    archive="$(cat _build/RELEASE_ARCHIVE)"
    remote_archive_dir="${CI_CD_REMOTE_ARCHIVE_DIR:-/var/tmp/${CI_CD_OTP_APP}_deploy}"
    remote_archive="${remote_archive_dir}/${CI_CD_OTP_APP}-${release_id}.tar.gz"
    retry ssh "${ssh_opts[@]}" "$CI_CD_DEPLOY_SSH_USER@$CI_CD_DEPLOY_SSH_HOST" "install -m 700 -d '$remote_archive_dir'"
    retry scp "${ssh_opts[@]}" "$archive" "$CI_CD_DEPLOY_SSH_USER@$CI_CD_DEPLOY_SSH_HOST:$remote_archive"
    retry ssh "${ssh_opts[@]}" "$CI_CD_DEPLOY_SSH_USER@$CI_CD_DEPLOY_SSH_HOST" \
      "sudo '$CI_CD_REMOTE_DEPLOY_SCRIPT' '$remote_archive' '$release_id' '$CI_CD_RUN_MIGRATIONS'"
    ;;
  *)
    echo "Unsupported CI_CD_RELEASE_ARTIFACT_KIND: $CI_CD_RELEASE_ARTIFACT_KIND" >&2
    exit 2
    ;;
esac

if [ -n "${CI_CD_HEALTH_URL:-}" ]; then
  retry curl -fsSL "$CI_CD_HEALTH_URL" | tee "/tmp/${CI_CD_OTP_APP}_${target}_health.json"
  grep -q "\"version\":\"${version}\"" "/tmp/${CI_CD_OTP_APP}_${target}_health.json"
  grep -q "\"release_id\":\"${release_id}\"" "/tmp/${CI_CD_OTP_APP}_${target}_health.json"
fi

if [ -n "${CI_CD_WEBSOCKET_BASE_URL:-}" ] && [ -f scripts/check_live_websocket.py ]; then
  retry python3 scripts/check_live_websocket.py "$CI_CD_WEBSOCKET_BASE_URL"
fi
