#!/usr/bin/env bash
# Reports a deployment to the configured channel.
#
# Extracted from the GitLab template, where it lived inline and so was lost the
# moment delivery moved to another forge — deploys kept working and silently
# stopped being announced.
#
# It reads the same CI_* names the rest of the delivery layer uses, so a forge
# adapter that normalizes its run identity gets notifications for free.
#
# Reporting must never turn a successful release into a failed pipeline, so this
# deliberately disables errexit and always exits 0.
# A deployment has already succeeded or failed by the time this hook runs.
# Reporting must never turn a successful release into a failed pipeline.
set +e
set +u
set +o pipefail
source "$(dirname "${BASH_SOURCE[0]}")/ci_metadata.sh"

: "${CI_CD_APP_NAME:=${CI_PROJECT_NAME:-project}}"
: "${CI_CD_DEPLOY_TARGET:=unknown}"
: "${CI_CD_ALERT_ADAPTER:=}"

if [ "${CI_JOB_STATUS:-success}" = "success" ]; then
  deploy_icon="✅"
  deploy_status="deployed"
  deploy_silent=true
else
  deploy_icon="❌"
  deploy_status="failed"
  deploy_silent=false
fi

release_id="$(cat _build/RELEASE_ID 2>/dev/null || echo unknown)"
app_version="$(cat _build/VERSION 2>/dev/null || echo unknown)"
actor="${GITLAB_USER_LOGIN:-${GITLAB_USER_NAME:-unknown}}"
pipeline_id="${CI_CD_EXECUTION_RUN_ID:-${GITHUB_RUN_ID:-${CI_PIPELINE_ID:-unknown}}}"
job_id="${CI_JOB_ID:-unknown}"

# Use the same immutable range prepared by deployment; never infer a push range.
commit_report="$(python3 "$(dirname "${BASH_SOURCE[0]}")/deployment_commits.py" render "$CI_CD_DEPLOY_TARGET" 2>/dev/null)"
if [ -z "$commit_report" ]; then
  commit_report="Commits: unavailable — deployment report could not be read"
fi
ci_deploy_commit_messages="$(python3 "$(dirname "${BASH_SOURCE[0]}")/deployment_commits.py" messages "$CI_CD_DEPLOY_TARGET" 2>/dev/null || true)"

seconds_from_timestamp() {
  date -u -d "$1" +%s 2>/dev/null || true
}

duration_label() {
  local seconds="$1"

  case "$seconds" in
    ''|*[!0-9]*)
      echo "unknown"
      return
      ;;
  esac

  printf '%sm %ss' "$((seconds / 60))" "$((seconds % 60))"
}

deploy_seconds="unknown"
wait_seconds="unknown"
total_seconds="unknown"

job_created_at="${CI_JOB_CREATED_AT:-}"
job_started_at="${CI_JOB_STARTED_AT:-}"

if [ -n "$job_started_at" ]; then
  job_start_epoch="$(seconds_from_timestamp "$job_started_at")"
fi
timing_file="_build/deployment/${CI_CD_DEPLOY_TARGET}/timing.env"
if [ -f "$timing_file" ]; then
  deploy_start="$(sed -nE 's/^CI_CD_DEPLOY_STARTED_AT_EPOCH=([0-9]+)$/\1/p' "$timing_file")"
  deploy_finish="$(sed -nE 's/^CI_CD_DEPLOY_FINISHED_AT_EPOCH=([0-9]+)$/\1/p' "$timing_file")"
  if [[ "$deploy_start" =~ ^[0-9]+$ && "$deploy_finish" =~ ^[0-9]+$ ]] &&
    [ "$deploy_finish" -ge "$deploy_start" ]; then
    deploy_seconds="$((deploy_finish - deploy_start))"
  fi
fi

if [ -n "$job_created_at" ] && [ -n "$job_started_at" ]; then
  job_created_epoch="$(seconds_from_timestamp "$job_created_at")"
  if [ -n "${job_created_epoch:-}" ] && [ -n "${job_start_epoch:-}" ]; then
    wait_seconds="$((job_start_epoch - job_created_epoch))"
  fi
fi

pipeline_created_at="${CI_CD_EXECUTION_CREATED_AT:-${CI_PIPELINE_CREATED_AT:-}}"
if [ -n "$pipeline_created_at" ]; then
  pipeline_created_epoch="$(seconds_from_timestamp "$pipeline_created_at")"
  if [ -n "${pipeline_created_epoch:-}" ]; then
    total_seconds="$(($(date -u +%s) - pipeline_created_epoch))"
  fi
fi

# Pipeline-to-job start includes dependency waits; it is not runner queue time.

html_escape() {
  printf '%s' "$1" | sed -e 's/&/\\&amp;/g' -e 's/</\\&lt;/g' -e 's/>/\\&gt;/g'
}

active_color=""
health_file="_build/deployment/${CI_CD_DEPLOY_TARGET}/health.json"
if [ -s "$health_file" ]; then
  active_color="$(sed -nE 's/.*"color":"([^"]+)".*/\1/p' "$health_file" | tail -n 1)"
fi

color_chip() {
  case "$1" in
    blue) printf '🔵 blue' ;;
    green) printf '🟢 green' ;;
    *) printf '%s' "$1" ;;
  esac
}

message="${deploy_icon} <b>[${CI_CD_DEPLOY_TARGET}] ${CI_CD_APP_NAME} <code>v${app_version}</code> ${deploy_status}</b>"
message+=$'\n'"Pipeline: <code>${pipeline_id}</code> job <code>${job_id}</code>"
message+=$'\n'"Release: <code>${release_id}</code>"
if [ -n "$active_color" ]; then
  message+=$'\n'"Active color: $(html_escape "$(color_chip "$active_color")")"
fi
message+=$'\n'"Actor: <code>${actor}</code>"
message+=$'\n'"Timing: deploy=<code>$(duration_label "${deploy_seconds}")</code> wait=<code>$(duration_label "${wait_seconds}")</code> total=<code>$(duration_label "${total_seconds}")</code>"

message+=$'\n'"${commit_report}"
report_url="${CI_CD_EXECUTION_RUN_URL:-${CI_PIPELINE_URL:-}}"
if [ -n "$report_url" ]; then
  message+=$'\n'"Deployment report: <a href=\"$(html_escape "$report_url")\">pipeline artifacts</a>"
fi

if [ -n "$CI_CD_ALERT_ADAPTER" ]; then
  alert_summary_path="/tmp/ci-cd-alert-summary-${CI_JOB_ID:-unknown}.txt"
  alert_details_path="/tmp/ci-cd-alert-details-${CI_JOB_ID:-unknown}.txt"
  alert_event_path="/tmp/ci-cd-alert-event-${CI_JOB_ID:-unknown}.json"

  printf '%s\n' "${CI_CD_APP_NAME} ${CI_CD_DEPLOY_TARGET} ${deploy_status}" >"$alert_summary_path"
  {
    printf 'Release: %s\n' "$release_id"
    printf 'Version: %s\n' "$app_version"
    printf 'Actor: %s\n' "$actor"
    printf 'Timing: deploy=%s wait=%s total=%s\n' \
      "$(duration_label "${deploy_seconds}")" \
      "$(duration_label "${wait_seconds}")" \
      "$(duration_label "${total_seconds}")"
    if [ -n "${ci_deploy_commit_messages:-}" ]; then
      printf 'Commits:\n%s\n' "$ci_deploy_commit_messages"
    fi
  } >"$alert_details_path"

  if [ "$deploy_status" = "deployed" ]; then
    export CI_CD_ALERT_STATUS=success
    export CI_CD_ALERT_SEVERITY=info
  else
    export CI_CD_ALERT_STATUS=failed
    export CI_CD_ALERT_SEVERITY=critical
  fi
  export CI_CD_ALERT_SUMMARY_PATH="$alert_summary_path"
  export CI_CD_ALERT_DETAILS_PATH="$alert_details_path"
  export CI_CD_ALERT_EVIDENCE_PATH="$health_file"
  export CI_CD_ALERT_EVIDENCE_URL="${CI_CD_HEALTH_URL:-}"
  export CI_CD_ALERT_APPLICATION="$CI_CD_APP_NAME"
  export CI_CD_ALERT_ENVIRONMENT="$CI_CD_DEPLOY_TARGET"
  export CI_CD_ALERT_HOST="${CI_CD_DEPLOY_HOST:-unknown}"
  export CI_CD_ALERT_RELEASE_ID="$release_id"
  export CI_CD_ALERT_RELEASE_VERSION="$app_version"

  alert_helper="${CI_CD_ALERT_HELPER:-$(dirname "${BASH_SOURCE[0]}")/ci_cd_alert_event.sh}"
  if [ -x "$alert_helper" ]; then
    "$alert_helper" deployment "$alert_event_path"
  else
    echo "deploy alert failed: helper is not executable at $alert_helper"
  fi
elif [ "${TELEGRAM_BOT_TOKEN:-}" != "" ] && [ "${TELEGRAM_CHAT_ID:-}" != "" ]; then
  curl -fsS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${message}" \
    --data-urlencode "parse_mode=HTML" \
    --data-urlencode "disable_notification=${deploy_silent}" >/dev/null || true
else
  printf '%b\n' "${message}"
fi

exit 0
