#!/usr/bin/env bash
# Sends an already-composed message file to the configured channel.
#
# The acceptance run writes its summary to a file and, on GitLab, a later job
# sent it. That send lived in the pipeline template, so moving forges silently
# dropped acceptance notifications while the summary kept being written.
#
# Usage: notify_message.sh MESSAGE_FILE [silent]
#
# Reporting must never fail the pipeline that produced the result, so this
# always exits 0.
set +e
set +u

message_file="${1:-}"
silent="${2:-false}"

if [ -z "$message_file" ] || [ ! -s "$message_file" ]; then
  echo "notify: no message at ${message_file:-<unset>}; nothing to send"
  exit 0
fi

message="$(cat "$message_file")"

if [ -n "${CI_CD_ALERT_ADAPTER:-}" ] && [ -x "${CI_CD_ALERT_HELPER:-}" ]; then
  summary_path="/tmp/ci-cd-alert-summary-$$.txt"
  head -n 1 "$message_file" >"$summary_path"
  export CI_CD_ALERT_SUMMARY_PATH="$summary_path"
  export CI_CD_ALERT_DETAILS_PATH="$message_file"
  "$CI_CD_ALERT_HELPER" acceptance "/tmp/ci-cd-alert-event-$$.json" || true
elif [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
  curl -fsS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${message}" \
    --data-urlencode "parse_mode=HTML" \
    --data-urlencode "disable_notification=${silent}" >/dev/null ||
    echo "notify: Telegram send failed; the result itself is unaffected"
else
  printf '%b\n' "$message"
fi

exit 0
