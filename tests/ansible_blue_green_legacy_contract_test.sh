#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
role="${root}/ansible/roles/phoenix_blue_green"
defaults="${role}/defaults/main.yml"
tasks="${role}/tasks/main.yml"
deploy="${role}/templates/phoenix_deploy.sh.j2"
service="${role}/templates/phoenix@.service.j2"
notify="${role}/templates/phoenix_telegram_notify.sh.j2"
standby="${role}/templates/phoenix_standby_end.sh.j2"
rollback="${role}/templates/phoenix_rollback.sh.j2"
environment="${role}/templates/phoenix.env.j2"

for expected in \
  'deploy_release_artifact_kind: "directory"' \
  'deploy_slot_layout: "symlink"' \
  'deploy_archive_strip_components: 1' \
  'release_seed_after_migrate: true' \
  'app_slot_env_file_template: "{{ app_env_file }}_%s"' \
  'app_service_environment_files:' \
  'app_service_exec_start:' \
  'app_service_on_failure: ""' \
  'app_slot_metadata_env_file_template: ""' \
  'nginx_upstream_keepalive: 0' \
  'phoenix_release_node_env_var: "RELEASE_NODE"' \
  'phoenix_release_node_template: "{{ otp_app_name }}_%s"' \
  'deployment_history_path: ""'; do
  grep -Fq "${expected}" "${defaults}"
done

grep -Fq "deploy_release_artifact_kind in ['directory', 'archive']" "${tasks}"
grep -Fq "deploy_slot_layout in ['symlink', 'directory']" "${tasks}"
grep -Fq "app_slot_env_file_template is search('%s')" "${tasks}"
grep -Fq 'nginx_upstream_keepalive | int >= 0' "${tasks}"
grep -Fq "phoenix_release_node_env_var is match('^[A-Z][A-Z0-9_]*$')" "${tasks}"
grep -Fq "phoenix_release_node_template is search('%s')" "${tasks}"
grep -Fq "app_slot_env_file_template | replace('%s', item.color)" "${tasks}"
grep -Fq 'keepalive {{ nginx_upstream_keepalive }};' "${tasks}"

grep -Fq '{% for environment_file in app_service_environment_files %}' "${service}"
grep -Fq 'EnvironmentFile={{ environment_file }}' "${service}"
grep -Fq '{% if app_service_on_failure %}' "${service}"
grep -Fq 'OnFailure={{ app_service_on_failure }}' "${service}"
grep -Fq 'ExecStart={{ app_service_exec_start }}' "${service}"
grep -Fq 'SLOT_ENV_FILE_TEMPLATE="{{ app_slot_env_file_template }}"' "${notify}"
grep -Fq 'ENV_FILE="${SLOT_ENV_FILE_TEMPLATE/\%s/${CURRENT_COLOR}}"' "${notify}"

grep -Fq 'ARTIFACT_KIND="{{ deploy_release_artifact_kind }}"' "${deploy}"
grep -Fq 'SLOT_LAYOUT="{{ deploy_slot_layout }}"' "${deploy}"
grep -Fq 'ARCHIVE_STRIP_COMPONENTS={{ deploy_archive_strip_components }}' "${deploy}"
grep -Fq 'slot_env_file()' "${deploy}"
grep -Fq 'slot_metadata_env_file()' "${deploy}"
grep -Fq 'TARGET_METADATA_ENV_FILE="$(slot_metadata_env_file "${TARGET_COLOR}")"' "${deploy}"
grep -Fq 'mv "${tmp_env}" "${TARGET_METADATA_ENV_FILE}"' "${deploy}"
grep -Fq 'tar -xzf "${ARCHIVE_PATH}"' "${deploy}"
grep -Fq 'case "${SLOT_LAYOUT}" in' "${deploy}"
grep -Fq 'directory)' "${deploy}"
grep -Fq 'mv "${candidate_dir}" "${RELEASE_DIR}"' "${deploy}"
grep -Fq '{% if release_seed_after_migrate %}' "${deploy}"
grep -Fq '{% if deployment_history_path %}' "${deploy}"
grep -Fq 'ARCHIVE_SHA256="$(sha256sum "${ARCHIVE_PATH}"' "${deploy}"
grep -Fq 'app_version: $app_version' "${deploy}"
grep -Fq 'git_messages: ($git_messages | split("\n")' "${deploy}"
grep -Fq 'slot: $slot' "${deploy}"
grep -Fq 'chown "${DEPLOY_USER}:${DEPLOY_USER}" "${HISTORY_PATH}"' "${deploy}"
grep -Fq 'chmod 0640 "${HISTORY_PATH}"' "${deploy}"
grep -Fq 'keepalive {{ nginx_upstream_keepalive }};' "${deploy}"
grep -Fq 'keepalive {{ nginx_upstream_keepalive }};' "${standby}"
grep -Fq 'keepalive {{ nginx_upstream_keepalive }};' "${rollback}"
grep -Fq "{{ phoenix_release_node_env_var }}=\"{{ phoenix_release_node_template | replace('%s', slot_color) }}\"" "${environment}"

printf 'ansible blue/green legacy contract: ok\n'
