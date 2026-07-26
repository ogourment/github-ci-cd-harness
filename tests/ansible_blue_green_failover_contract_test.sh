#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runtime_role="${root}/ansible/roles/phoenix_blue_green"
web_role="${root}/ansible/roles/web"
deploy="${runtime_role}/templates/phoenix_deploy.sh.j2"
rollback="${runtime_role}/templates/phoenix_rollback.sh.j2"
standby_end="${runtime_role}/templates/phoenix_standby_end.sh.j2"
runtime_defaults="${runtime_role}/defaults/main.yml"
web_defaults="${web_role}/defaults/main.yml"
web_template="${web_role}/templates/app.nginx.j2"
tasks="${runtime_role}/tasks/main.yml"

for expected in \
  'deploy_standby_sec: 0' \
  'deploy_public_base_url: "https://{{ server_name }}"' \
  'deploy_public_identity_path: "{{ deploy_health_path }}"' \
  'deploy_public_smoke_path: "/"' \
  'nginx_upstream_max_fails: 1' \
  'nginx_upstream_fail_timeout: "5s"'; do
  grep -Fq "${expected}" "${runtime_defaults}"
done

for expected in \
  'nginx_connection_upgrade_var:' \
  'nginx_proxy_next_upstream: "error timeout invalid_header"' \
  'nginx_proxy_next_upstream_tries: 2'; do
  grep -Fq "${expected}" "${web_defaults}"
done

grep -Fq 'map $http_upgrade ${{ nginx_connection_upgrade_var }} {' "${web_template}"
grep -Fq "''      '';" "${web_template}"
grep -Fq 'proxy_set_header Connection ${{ nginx_connection_upgrade_var }};' "${web_template}"
! grep -Fq 'proxy_set_header Connection "upgrade";' "${web_template}"
! grep -Eq 'proxy_next_upstream.*http_50[0234]' "${web_template}"

grep -Fq 'src: phoenix_standby_end.sh.j2' "${tasks}"
grep -Fq 'dest: "{{ deploy_standby_end_script }}"' "${tasks}"
test -f "${standby_end}"

upstream_line="$(grep -n 'write_live_only_upstream' "${standby_end}" | tail -1 | cut -d: -f1)"
stop_line="$(grep -n 'systemctl stop "${STANDBY_SERVICE}"' "${standby_end}" | tail -1 | cut -d: -f1)"
test "${upstream_line}" -lt "${stop_line}"

grep -Fq 'cancel_standby_timer' "${deploy}"
cancel_line="$(grep -n 'cancel_standby_timer' "${deploy}" | tail -1 | cut -d: -f1)"
stage_line="$(grep -n 'echo "==> Staging release..."' "${deploy}" | cut -d: -f1)"
test "${cancel_line}" -lt "${stage_line}"

grep -Fq 'verify_public_candidate' "${deploy}"
verify_line="$(grep -n 'if ! verify_public_candidate; then' "${deploy}" | cut -d: -f1)"
restore_line="$(grep -n '^  restore_current_upstream$' "${deploy}" | cut -d: -f1)"
candidate_stop_line="$(grep -n '^  systemctl stop "${TARGET_SERVICE}" || true$' "${deploy}" | tail -1 | cut -d: -f1)"
commit_line="$(grep -n 'echo "${TARGET_COLOR}" > "${CURRENT_COLOR_FILE}"' "${deploy}" | cut -d: -f1)"
test "${verify_line}" -lt "${commit_line}"
test "${verify_line}" -lt "${restore_line}"
test "${restore_line}" -lt "${candidate_stop_line}"
test "${candidate_stop_line}" -lt "${commit_line}"

grep -Fq 'Content-Type' "${deploy}"
grep -Fq 'EXPECTED_VERSION' "${deploy}"
grep -Fq 'RELEASE_ID' "${deploy}"
grep -Fq 'CI_PIPELINE_ID' "${deploy}"
grep -Fq 'TARGET_COLOR' "${deploy}"
grep -Fq 'restore_current_upstream' "${deploy}"
grep -Fq 'systemd-run' "${deploy}"

grep -Fq 'cancel_standby_timer' "${rollback}"
rollback_cancel_line="$(grep -n '^cancel_standby_timer$' "${rollback}" | cut -d: -f1)"
rollback_restart_line="$(grep -n 'systemctl restart "${TARGET_SERVICE}"' "${rollback}" | cut -d: -f1)"
test "${rollback_cancel_line}" -lt "${rollback_restart_line}"

fixture="$(mktemp -d)"
trap 'rm -rf "${fixture}"' EXIT
sed -n '/^verify_public_candidate()/,/^# --- Pick idle/p' "${deploy}" |
  sed '$d' > "${fixture}/verify_public_candidate.sh"
cat > "${fixture}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=""
headers=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    --dump-header) headers="$2"; shift 2 ;;
    --connect-timeout|--max-time|--write-out) shift 2 ;;
    --silent|--show-error|--location|--fail) shift ;;
    *) shift ;;
  esac
done
printf 'HTTP/1.1 500 Internal Server Error\r\nContent-Type: text/html\r\n\r\n' > "${headers}"
printf '<html><body>broken candidate</body></html>\n' > "${output}"
printf '500'
EOF
chmod +x "${fixture}/curl"

PATH="${fixture}:${PATH}"
PUBLIC_BASE_URL="https://fixture.example"
PUBLIC_SMOKE_PATH="/"
PUBLIC_IDENTITY_PATH="/health/ready"
PUBLIC_SMOKE_CONTENT_TYPE="text/html"
PUBLIC_SMOKE_TIMEOUT_SEC=2
# shellcheck source=/dev/null
source "${fixture}/verify_public_candidate.sh"
if verify_public_candidate; then
  echo "public verification accepted a fixture returning HTTP 500" >&2
  exit 1
fi

printf 'ansible blue/green failover contract: ok\n'
