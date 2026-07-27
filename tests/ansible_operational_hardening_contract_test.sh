#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
role="${root}/ansible/roles/phoenix_blue_green"
defaults="${role}/defaults/main.yml"
tasks="${role}/tasks/main.yml"
deploy="${role}/templates/phoenix_deploy.sh.j2"
rollback="${role}/templates/phoenix_rollback.sh.j2"
standby="${role}/templates/phoenix_standby_end.sh.j2"
notifier="${role}/templates/phoenix_telegram_notify.sh.j2"
failure_alert="${role}/templates/phoenix_failure_alert.sh.j2"
health_watch="${role}/templates/phoenix_health_watch.sh.j2"
alert_unit="${role}/templates/phoenix-alert@.service.j2"
watch_service="${role}/templates/phoenix-health-watch.service.j2"
watch_timer="${role}/templates/phoenix-health-watch.timer.j2"

for expected in \
  'telegram_verify_on_provision: false' \
  'app_manage_failure_alert_unit: false' \
  'app_failure_alert_cooldown_sec: 300' \
  'app_failure_journal_lines: 40' \
  'app_health_watch_interval_sec: 0' \
  'app_health_watch_failure_threshold: 3' \
  'app_health_watch_action_cooldown_sec: 300' \
  'deploy_operation_lock_path:'; do
  grep -Fq "${expected}" "${defaults}"
done

for template in \
  "${failure_alert}" "${health_watch}" "${alert_unit}" \
  "${watch_service}" "${watch_timer}"; do
  test -f "${template}"
done

grep -Fq 'name: Verify Telegram bot and chat access' "${tasks}"
grep -Fq 'no_log: true' "${tasks}"
grep -Fq 'name: Initialize per-slot deployment metadata files' "${tasks}"
grep -Fq 'name: Read committed color' "${tasks}"
grep -Fq "item.item == (committed_color_file.content | b64decode | trim)" "${tasks}"
grep -Fq 'name: Enable recurring health watch timer' "${tasks}"
grep -Fq 'name: Disable recurring health watch timer when monitoring is off' "${tasks}"

grep -Fq 'telegram_request getMe' "${notifier}"
grep -Fq 'telegram_request getChat' "${notifier}"
grep -Fq "jq -e '.ok == true'" "${notifier}"
grep -Fq 'Telegram message delivered: message_id=' "${notifier}"
grep -Fq "printf 'Telegram %s failed: HTTP %s: %s" "${notifier}"
! grep -Fq '>/dev/null 2>&1 || true' "${notifier}"

grep -Fq 'event "service_failure"' "${failure_alert}"
grep -Fq 'ExecMainCode' "${failure_alert}"
grep -Fq 'ExecMainStatus' "${failure_alert}"
grep -Fq 'NRestarts' "${failure_alert}"
grep -Fq 'journal_tail' "${failure_alert}"
grep -Fq '._COMM != "systemd"' "${failure_alert}"
grep -Fq 'main process terminated by signal' "${failure_alert}"
grep -Fq 'Failure captured; Telegram alert suppressed' "${failure_alert}"
grep -Fq 'Investigate: <code>journalctl -u %s --since "-15 min"</code>' "${failure_alert}"
grep -Fq 'TELEGRAM_SILENT=false "${NOTIFY_SCRIPT}"' "${failure_alert}"

grep -Fq 'direct readiness ${readiness_status}' "${health_watch}"
grep -Fq 'direct readiness color ${readiness_color:-missing}; expected ${CURRENT_COLOR}' "${health_watch}"
grep -Fq 'public readiness color ${public_readiness_color:-missing}; expected ${CURRENT_COLOR}' "${health_watch}"
grep -Fq 'public smoke ${smoke_status}' "${health_watch}"
grep -Fq 'failure_count < FAILURE_THRESHOLD' "${health_watch}"
grep -Fq 'systemctl is-active --quiet "${STANDBY_SERVICE}"' "${health_watch}"
grep -Fq 'write_live_only_upstream "${STANDBY_PORT}"' "${health_watch}"
grep -Fq 'printf '\''%s\n'\'' "${STANDBY_COLOR}" > "${CURRENT_COLOR_FILE}"' "${health_watch}"
grep -Fq 'append_event "failed over to healthy standby"' "${health_watch}"
grep -Fq 'systemctl restart "${CURRENT_SERVICE}"' "${health_watch}"
grep -Fq 'append_event "restarted active service; no healthy standby"' "${health_watch}"

for serialized in "${deploy}" "${rollback}" "${standby}" "${health_watch}"; do
  grep -Fq 'OPERATION_LOCK_PATH="{{ deploy_operation_lock_path }}"' "${serialized}"
  grep -Fq 'flock' "${serialized}"
done

fixture="$(mktemp -d)"
trap 'rm -rf "${fixture}"' EXIT
sed -n '/^probe_committed_color()/,/^}$/p' "${health_watch}" > "${fixture}/probe.sh"
cat > "${fixture}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=""
headers=""
url=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    --dump-header) headers="$2"; shift 2 ;;
    --connect-timeout|--max-time|--write-out) shift 2 ;;
    --silent|--show-error|--location) shift ;;
    *) url="$1"; shift ;;
  esac
done
if [[ "${url}" == http://127.0.0.1:* ]]; then
  printf '{"color":"blue"}\n' > "${output}"
  printf '200'
elif [[ "${url}" == */api/health/ready ]]; then
  printf '{"color":"blue"}\n' > "${output}"
  printf '200'
else
  printf 'HTTP/1.1 500 Internal Server Error\r\nContent-Type: text/html\r\n\r\n' > "${headers}"
  printf '<html><body>broken</body></html>\n' > "${output}"
  printf '500'
fi
EOF
chmod +x "${fixture}/curl"

PATH="${fixture}:${PATH}"
CURRENT_PORT=4210
CURRENT_COLOR="blue"
HEALTH_PATH="/api/health/ready"
PUBLIC_BASE_URL="https://fixture.example"
PUBLIC_SMOKE_PATH="/"
PUBLIC_SMOKE_CONTENT_TYPE="text/html"
PUBLIC_SMOKE_TIMEOUT_SEC=2
# shellcheck source=/dev/null
source "${fixture}/probe.sh"
if probe_committed_color; then
  echo "health watch accepted a public HTTP 500" >&2
  exit 1
fi
test "${probe_failure}" = "public smoke 500"

printf 'ansible operational hardening contract: ok\n'
