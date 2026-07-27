#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
acceptance_template="${root}/templates/acceptance.yml"
cd_template="${root}/templates/cd.yml"
alert_helper="${root}/scripts/ci_cd_alert_event.sh"
readme="${root}/README.md"
version="$(cat "${root}/VERSION")"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

adapter="${tmp}/adapter with spaces"
cat >"$adapter" <<'SH'
#!/bin/sh
cp "$1" "$ADAPTER_CAPTURE"
SH
chmod +x "$adapter"

summary="${tmp}/summary.txt"
details="${tmp}/details.txt"
event="${tmp}/event.json"
capture="${tmp}/captured.json"
injection="${tmp}/must-not-exist"

printf '%s\n' "Acceptance passed; \$(touch \"$injection\")" >"$summary"
printf '%s\n' 'Evidence is available.' >"$details"

ADAPTER_CAPTURE="$capture" \
CI_CD_ALERT_ADAPTER="$adapter" \
CI_CD_ALERT_STATUS=success \
CI_CD_ALERT_SEVERITY=info \
CI_CD_ALERT_SUMMARY_PATH="$summary" \
CI_CD_ALERT_DETAILS_PATH="$details" \
CI_CD_ALERT_EVIDENCE_PATH=tmp/atdd/evidence.json \
CI_CD_ALERT_EVIDENCE_URL=https://ci.example/evidence \
CI_CD_ALERT_APPLICATION='Example App' \
CI_CD_ALERT_ENVIRONMENT=staging \
CI_PROJECT_ID=42 \
CI_PROJECT_PATH=group/example \
CI_PROJECT_URL=https://gitlab.example/group/example \
CI_PIPELINE_ID=101 \
CI_PIPELINE_URL=https://gitlab.example/pipelines/101 \
CI_JOB_ID=202 \
CI_JOB_NAME=acceptance_gate \
CI_JOB_URL=https://gitlab.example/jobs/202 \
CI_COMMIT_SHA=abcdef123456 \
CI_COMMIT_REF_NAME=main \
CI_JOB_STARTED_AT=2026-07-27T18:00:00Z \
  "$root/scripts/ci_cd_alert_event.sh" acceptance "$event"

cmp "$event" "$capture"
test ! -e "$injection"
grep -Fq '"contract": "ops-alert-event.v1"' "$event"
grep -Fq '"id": "gitlab:42:101:202:acceptance:success:staging"' "$event"
grep -Fq '"idempotency_key": "gitlab:42:101:202:acceptance:success:staging"' "$event"
grep -Fq '"occurred_at": "2026-07-27T18:00:00Z"' "$event"
grep -Fq '"timezone": "UTC"' "$event"
grep -Fq '"severity": "info"' "$event"
grep -Fq '"pipeline": {"id": "101", "url": "https://gitlab.example/pipelines/101"}' "$event"
grep -Fq '"job": {"id": "202", "name": "acceptance_gate", "url": "https://gitlab.example/jobs/202"}' "$event"
grep -Fq '"commit": {"sha": "abcdef123456", "ref": "main", "url": "https://gitlab.example/group/example/-/commit/abcdef123456"}' "$event"
grep -Fq '"summary": "Acceptance passed; $(touch' "$event"
grep -Fq '"evidence": {"path": "tmp/atdd/evidence.json", "url": "https://ci.example/evidence"}' "$event"

grep -Fq '"$CI_CD_ALERT_ADAPTER" "$event_file"' "$alert_helper"
grep -Fq '"$alert_helper" acceptance "$alert_event_path"' "$acceptance_template"
grep -Fq '"$alert_helper" deployment "$alert_event_path"' "$cd_template"
grep -Fq 'CI_CD_HARNESS_REF is required when CI_CD_ALERT_ADAPTER is set' "$acceptance_template"
grep -Fq "CI_CD_HARNESS_REF: \"v${version}\"" "$cd_template"
[[ "$(grep -Fc "ref: v${version}" "$readme")" -eq 2 ]]
grep -Fq 'ACCEPTANCE_NOTIFY_COMMAND is deprecated; use CI_CD_ALERT_ADAPTER' "$acceptance_template"
grep -Fq 'elif [ -n "$ACCEPTANCE_NOTIFY_COMMAND" ]' "$acceptance_template"
grep -Fq 'elif [ -n "${TELEGRAM_BOT_TOKEN:-}" ]' "$acceptance_template"
grep -Fq 'elif [ "${TELEGRAM_BOT_TOKEN:-}" != "" ]' "$cd_template"
! grep -F 'sh -c "$CI_CD_ALERT_ADAPTER"' "$acceptance_template" "$cd_template" "$alert_helper"

printf '%s\n' 'alert delivery hook tests: passed'
