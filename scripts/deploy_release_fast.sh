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
: "${CI_CD_HOST_DEPLOY_NOTIFY:=true}"

release_id="$(cat _build/RELEASE_ID)"
version="$(cat _build/VERSION)"

remote_env_prefix="${CI_CD_REMOTE_ENV_PREFIX:-$(printf '%s' "$CI_CD_OTP_APP" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9_' '_')}"

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

epoch_from_timestamp() {
  if [ -z "${1:-}" ]; then
    return 1
  fi

  date -u -d "$1" +%s 2>/dev/null
}

gitlab_api_json() {
  if [ -z "${CI_API_V4_URL:-}" ] || [ -z "${CI_PROJECT_ID:-}" ] || [ -z "${CI_JOB_TOKEN:-}" ]; then
    return 1
  fi

  curl -fsS --header "JOB-TOKEN: ${CI_JOB_TOKEN}" "$1" 2>/dev/null
}

json_field() {
  python3 -c '
from __future__ import annotations

import json
import sys

field = sys.argv[1]
try:
    payload = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)

value = payload.get(field)
if value:
    print(value)
' "$1"
}

job_timestamp() {
  field="$1"

  case "$field" in
    created_at)
      if [ -n "${CI_JOB_CREATED_AT:-}" ]; then
        printf '%s\n' "$CI_JOB_CREATED_AT"
        return 0
      fi
      ;;
    started_at)
      if [ -n "${CI_JOB_STARTED_AT:-}" ]; then
        printf '%s\n' "$CI_JOB_STARTED_AT"
        return 0
      fi
      ;;
  esac

  if [ -n "${CI_JOB_ID:-}" ]; then
    gitlab_api_json "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/jobs/${CI_JOB_ID}" | json_field "$field"
  fi
}

pipeline_timestamp() {
  if [ -n "${CI_PIPELINE_CREATED_AT:-}" ]; then
    printf '%s\n' "$CI_PIPELINE_CREATED_AT"
    return 0
  fi

  if [ -n "${CI_PIPELINE_ID:-}" ]; then
    gitlab_api_json "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/pipelines/${CI_PIPELINE_ID}" |
      json_field created_at
  fi
}

duration_between() {
  start="$(epoch_from_timestamp "${1:-}")" || return 1
  end="$(epoch_from_timestamp "${2:-}")" || return 1

  if [ "$end" -lt "$start" ]; then
    return 1
  fi

  printf '%s\n' "$((end - start))"
}

job_wait_seconds() {
  created_at="$(job_timestamp created_at || true)"
  started_at="$(job_timestamp started_at || true)"

  if [ -n "$created_at" ] && [ -n "$started_at" ]; then
    duration_between "$created_at" "$started_at"
    return
  fi

  pipeline_created_at="$(pipeline_timestamp || true)"
  if [ -n "$pipeline_created_at" ]; then
    duration_between "$pipeline_created_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi
}

pipeline_created_epoch() {
  pipeline_created_at="$(pipeline_timestamp || true)"
  epoch_from_timestamp "$pipeline_created_at"
}

commit_messages() {
  before_sha="${CI_COMMIT_BEFORE_SHA:-}"

  if [ -n "$before_sha" ] &&
    [ "$before_sha" != "0000000000000000000000000000000000000000" ] &&
    git cat-file -e "${before_sha}^{commit}" 2>/dev/null; then
    messages="$(git log --format=%s "${before_sha}..${CI_COMMIT_SHA:-HEAD}")"
    if [ -n "$messages" ]; then
      printf '%s\n' "$messages"
      return
    fi
  fi

  git log -1 --format=%s "${CI_COMMIT_SHA:-HEAD}"
}

remote_env_assignment() {
  name="$1"
  value="$2"
  printf '%s=%s' "$name" "$value"
}

remote_deploy_command() {
  remote_script="$1"
  shift

  git_sha="${CI_COMMIT_SHA:-$(git rev-parse HEAD)}"
  git_ref="${CI_COMMIT_REF_NAME:-$(git rev-parse --abbrev-ref HEAD)}"
  git_subject="${CI_COMMIT_TITLE:-$(git log -1 --format=%s HEAD)}"
  git_messages="$(commit_messages)"
  git_messages_env="${git_messages//$'\n'/\\n}"
  deploy_actor="${GITLAB_USER_LOGIN:-gitlab-ci}"
  deploy_app_name="${CI_CD_APP_NAME:-${ACCEPTANCE_APP_NAME:-${CI_PROJECT_TITLE:-$CI_CD_OTP_APP}}}"
  ci_job_wait_seconds="$(job_wait_seconds || true)"
  ci_pipeline_created_epoch="$(pipeline_created_epoch || true)"

  command=(
    sudo env
    "$(remote_env_assignment "${remote_env_prefix}_APP_NAME" "$deploy_app_name")"
    "$(remote_env_assignment "${remote_env_prefix}_APP_VERSION" "$version")"
    "$(remote_env_assignment "${remote_env_prefix}_GIT_SHA" "$git_sha")"
    "$(remote_env_assignment "${remote_env_prefix}_GIT_REF" "$git_ref")"
    "$(remote_env_assignment "${remote_env_prefix}_GIT_SUBJECT" "$git_subject")"
    "$(remote_env_assignment "${remote_env_prefix}_GIT_MESSAGES" "$git_messages_env")"
    "$(remote_env_assignment "${remote_env_prefix}_DEPLOY_ACTOR" "$deploy_actor")"
    "$(remote_env_assignment "${remote_env_prefix}_CI_PIPELINE_ID" "${CI_PIPELINE_ID:-}")"
    "$(remote_env_assignment "${remote_env_prefix}_CI_JOB_ID" "${CI_JOB_ID:-}")"
    "$(remote_env_assignment "${remote_env_prefix}_CI_JOB_WAIT_SECONDS" "$ci_job_wait_seconds")"
    "$(remote_env_assignment "${remote_env_prefix}_CI_PIPELINE_CREATED_AT_EPOCH" "$ci_pipeline_created_epoch")"
    "$(remote_env_assignment "${remote_env_prefix}_HOST_DEPLOY_NOTIFY" "$CI_CD_HOST_DEPLOY_NOTIFY")"
    "$remote_script"
    "$@"
  )

  printf '%q ' "${command[@]}"
}

case "$CI_CD_RELEASE_ARTIFACT_KIND" in
  directory)
    remote_release_dir="${CI_CD_REMOTE_RELEASES_ROOT%/}/${release_id}"
    retry ssh "${ssh_opts[@]}" "$CI_CD_DEPLOY_SSH_USER@$CI_CD_DEPLOY_SSH_HOST" "mkdir -p '$remote_release_dir'"
    retry rsync -az --delete -e "ssh -i $HOME/.ssh/gitlab_ci_cd_deploy_key -o IdentitiesOnly=yes -o IdentityAgent=none" \
      "${CI_CD_RELEASE_ARTIFACT_PATH%/}/" \
      "$CI_CD_DEPLOY_SSH_USER@$CI_CD_DEPLOY_SSH_HOST:$remote_release_dir/"
    remote_command="$(remote_deploy_command "$CI_CD_REMOTE_DEPLOY_SCRIPT" "$release_id" "$CI_CD_RUN_MIGRATIONS")"
    retry ssh "${ssh_opts[@]}" "$CI_CD_DEPLOY_SSH_USER@$CI_CD_DEPLOY_SSH_HOST" "$remote_command"
    ;;
  archive)
    archive="$(cat _build/RELEASE_ARCHIVE)"
    remote_archive_dir="${CI_CD_REMOTE_ARCHIVE_DIR:-/var/tmp/${CI_CD_OTP_APP}_deploy}"
    remote_archive="${remote_archive_dir}/${CI_CD_OTP_APP}-${release_id}.tar.gz"
    retry ssh "${ssh_opts[@]}" "$CI_CD_DEPLOY_SSH_USER@$CI_CD_DEPLOY_SSH_HOST" "install -m 700 -d '$remote_archive_dir'"
    retry scp "${ssh_opts[@]}" "$archive" "$CI_CD_DEPLOY_SSH_USER@$CI_CD_DEPLOY_SSH_HOST:$remote_archive"
    remote_command="$(remote_deploy_command "$CI_CD_REMOTE_DEPLOY_SCRIPT" "$remote_archive" "$release_id" "$CI_CD_RUN_MIGRATIONS")"
    retry ssh "${ssh_opts[@]}" "$CI_CD_DEPLOY_SSH_USER@$CI_CD_DEPLOY_SSH_HOST" "$remote_command"
    ;;
  *)
    echo "Unsupported CI_CD_RELEASE_ARTIFACT_KIND: $CI_CD_RELEASE_ARTIFACT_KIND" >&2
    exit 2
    ;;
esac

if [ -n "${CI_CD_HEALTH_URL:-}" ]; then
  health_file="/tmp/${CI_CD_OTP_APP}_${target}_health.json"
  retry curl -fsSL "$CI_CD_HEALTH_URL" | tee "$health_file"
  .gitlab-ci-cd-harness/scripts/verify_health_identity.sh \
    "$health_file" "$version" "$release_id" "${CI_PIPELINE_ID:-unknown}"
fi

if [ -n "${CI_CD_WEBSOCKET_BASE_URL:-}" ] && [ -f scripts/check_live_websocket.py ]; then
  retry python3 scripts/check_live_websocket.py "$CI_CD_WEBSOCKET_BASE_URL"
fi
