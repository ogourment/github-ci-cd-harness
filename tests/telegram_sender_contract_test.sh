#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
acceptance_template="${root}/templates/acceptance.yml"
cd_template="${root}/templates/cd.yml"
ansible_notifier="${root}/ansible/roles/phoenix_blue_green/templates/phoenix_telegram_notify.sh.j2"

printf '%s\n' 'asserting acceptance sender disables Telegram link previews for message links'
grep -Fq 'sendMessage' "$acceptance_template"
grep -Fq 'text@${acceptance_message_path}' "$acceptance_template"
grep -Fq 'disable_notification=${acceptance_notify_silent}' "$acceptance_template"
grep -Fq 'link_preview_options={"is_disabled":true}' "$acceptance_template"

printf '%s\n' 'asserting acceptance evidence payload still emits HTML links'
grep -Fq 'Evidence report: <a href=' "$acceptance_template"
grep -Fq 'Live evidence: <a href=' "$acceptance_template"

printf '%s\n' 'asserting deploy senders do not include link previews or link-rich message payloads'
! grep -Fq 'link_preview_options=' "$cd_template"
! grep -Fq '<a href=' "$cd_template"
! grep -Fq 'link_preview_options=' "$ansible_notifier"
! grep -Fq '<a href=' "$ansible_notifier"

printf '%s\n' 'telegram sender contract tests: passed'
