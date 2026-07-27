#!/bin/sh
set -eu

usage() {
  echo "usage: ci_cd_alert_event.sh <kind> <event-file>" >&2
  exit 64
}

[ "$#" -eq 2 ] || usage

kind="$1"
event_file="$2"

: "${CI_CD_ALERT_ADAPTER:?CI_CD_ALERT_ADAPTER is required}"
: "${CI_CD_ALERT_STATUS:=unknown}"
: "${CI_CD_ALERT_SEVERITY:=warning}"
: "${CI_CD_ALERT_SUMMARY_PATH:?CI_CD_ALERT_SUMMARY_PATH is required}"
: "${CI_CD_ALERT_DETAILS_PATH:=}"
: "${CI_CD_ALERT_EVIDENCE_PATH:=}"
: "${CI_CD_ALERT_OCCURRED_AT:=${CI_JOB_STARTED_AT:-}}"

if [ -z "$CI_CD_ALERT_OCCURRED_AT" ]; then
  CI_CD_ALERT_OCCURRED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
fi

if ! command -v "$CI_CD_ALERT_ADAPTER" >/dev/null 2>&1; then
  echo "alert adapter is not executable: $CI_CD_ALERT_ADAPTER" >&2
  exit 69
fi

if [ ! -s "$CI_CD_ALERT_SUMMARY_PATH" ]; then
  echo "alert summary is missing: $CI_CD_ALERT_SUMMARY_PATH" >&2
  exit 66
fi

json_string() {
  awk '
    BEGIN { first = 1 }
    {
      gsub(/\\/, "\\\\")
      gsub(/"/, "\\\"")
      gsub(/\t/, "\\t")
      gsub(/\r/, "\\r")
      if (!first) {
        printf "\\n"
      }
      printf "%s", $0
      first = 0
    }
  ' "$1"
}

json_literal() {
  value="$1"
  escaped_file="${event_file}.value.$$"
  printf '%s' "$value" >"$escaped_file"
  json_string "$escaped_file"
  rm -f "$escaped_file"
}

read_optional_file() {
  file="$1"
  if [ -n "$file" ] && [ -f "$file" ]; then
    json_string "$file"
  fi
}

project_id="${CI_PROJECT_ID:-unknown}"
pipeline_id="${CI_PIPELINE_ID:-unknown}"
job_id="${CI_JOB_ID:-unknown}"
environment="${CI_CD_ALERT_ENVIRONMENT:-${CI_CD_DEPLOY_TARGET:-${ACCEPTANCE_TARGET:-unknown}}}"
application="${CI_CD_ALERT_APPLICATION:-${CI_CD_APP_NAME:-${ACCEPTANCE_APP_NAME:-${CI_PROJECT_NAME:-unknown}}}}"
host="${CI_CD_ALERT_HOST:-${CI_CD_DEPLOY_HOST:-unknown}}"
release_id="${CI_CD_ALERT_RELEASE_ID:-unknown}"
release_version="${CI_CD_ALERT_RELEASE_VERSION:-unknown}"
event_id="gitlab:${project_id}:${pipeline_id}:${job_id}:${kind}:${CI_CD_ALERT_STATUS}:${environment}"
fingerprint="gitlab:${project_id}:${application}:${environment}:${kind}"
correlation_key="gitlab-pipeline:${project_id}:${pipeline_id}"
commit_url="${CI_PROJECT_URL:-}/-/commit/${CI_COMMIT_SHA:-unknown}"

event_dir="$(dirname "$event_file")"
mkdir -p "$event_dir"
event_tmp="${event_file}.tmp.$$"
trap 'rm -f "$event_tmp" "${event_file}.value.$$"' EXIT HUP INT TERM

{
  printf '{\n'
  printf '  "contract": "ops-alert-event.v1",\n'
  printf '  "id": "%s",\n' "$(json_literal "$event_id")"
  printf '  "idempotency_key": "%s",\n' "$(json_literal "$event_id")"
  printf '  "occurred_at": "%s",\n' "$(json_literal "$CI_CD_ALERT_OCCURRED_AT")"
  printf '  "timezone": "UTC",\n'
  printf '  "source": {"type": "gitlab-ci", "project_id": "%s", "project_path": "%s"},\n' \
    "$(json_literal "$project_id")" "$(json_literal "${CI_PROJECT_PATH:-unknown}")"
  printf '  "kind": "%s",\n' "$(json_literal "$kind")"
  printf '  "severity": "%s",\n' "$(json_literal "$CI_CD_ALERT_SEVERITY")"
  printf '  "status": "%s",\n' "$(json_literal "$CI_CD_ALERT_STATUS")"
  printf '  "application": "%s",\n' "$(json_literal "$application")"
  printf '  "environment": "%s",\n' "$(json_literal "$environment")"
  printf '  "host": "%s",\n' "$(json_literal "$host")"
  printf '  "pipeline": {"id": "%s", "url": "%s"},\n' \
    "$(json_literal "$pipeline_id")" "$(json_literal "${CI_PIPELINE_URL:-unknown}")"
  printf '  "job": {"id": "%s", "name": "%s", "url": "%s"},\n' \
    "$(json_literal "$job_id")" "$(json_literal "${CI_JOB_NAME:-unknown}")" \
    "$(json_literal "${CI_JOB_URL:-unknown}")"
  printf '  "release": {"id": "%s", "version": "%s"},\n' \
    "$(json_literal "$release_id")" "$(json_literal "$release_version")"
  printf '  "commit": {"sha": "%s", "ref": "%s", "url": "%s"},\n' \
    "$(json_literal "${CI_COMMIT_SHA:-unknown}")" "$(json_literal "${CI_COMMIT_REF_NAME:-unknown}")" \
    "$(json_literal "$commit_url")"
  printf '  "fingerprint": "%s",\n' "$(json_literal "$fingerprint")"
  printf '  "correlation_key": "%s",\n' "$(json_literal "$correlation_key")"
  printf '  "summary": "%s",\n' "$(json_string "$CI_CD_ALERT_SUMMARY_PATH")"
  printf '  "details": "%s",\n' "$(read_optional_file "$CI_CD_ALERT_DETAILS_PATH")"
  printf '  "evidence": {"path": "%s", "url": "%s"}\n' \
    "$(json_literal "$CI_CD_ALERT_EVIDENCE_PATH")" \
    "$(json_literal "${CI_CD_ALERT_EVIDENCE_URL:-}")"
  printf '}\n'
} >"$event_tmp"

mv "$event_tmp" "$event_file"
"$CI_CD_ALERT_ADAPTER" "$event_file"
