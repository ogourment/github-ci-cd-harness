#!/usr/bin/env bash
set -euo pipefail

phase="${1:-}"
command="${2:-}"
timing_path="${ACCEPTANCE_FAST_TIMING_PATH:-tmp/atdd-fast/timing.env}"

case "$phase" in
  setup|test|teardown) ;;
  *)
    printf 'Usage: %s <setup|test|teardown> <command>\n' "$0" >&2
    exit 64
    ;;
esac

[[ -n "$command" ]] || {
  printf 'Acceptance fast %s command is required.\n' "$phase" >&2
  exit 64
}

mkdir -p "$(dirname "$timing_path")"

workspace_kb() {
  local path size total=0

  for path in deps _build/test assets/node_modules .npm .mix .hex tmp; do
    if [ -e "$path" ]; then
      size="$(du -sk "$path" | awk '{print $1}')"
      total=$((total + size))
    fi
  done

  printf '%s\n' "$total"
}

started_at="$(date +%s)"
before_kb="$(workspace_kb)"
peak_kb="$before_kb"

printf 'acceptance_fast_%s_started_at_epoch=%s\n' "$phase" "$started_at" >>"$timing_path"
printf 'acceptance_fast_%s_workspace_before_kb=%s\n' "$phase" "$before_kb" >>"$timing_path"

bash -lc "$command" &
command_pid=$!

while kill -0 "$command_pid" 2>/dev/null; do
  current_kb="$(workspace_kb)"
  if [ "$current_kb" -gt "$peak_kb" ]; then
    peak_kb="$current_kb"
  fi
  sleep 1
done

set +e
wait "$command_pid"
command_status=$?
set -e

ended_at="$(date +%s)"
after_kb="$(workspace_kb)"
if [ "$after_kb" -gt "$peak_kb" ]; then
  peak_kb="$after_kb"
fi

printf 'acceptance_fast_%s_finished_at_epoch=%s\n' "$phase" "$ended_at" >>"$timing_path"
printf 'acceptance_fast_%s_elapsed_seconds=%s\n' "$phase" "$((ended_at - started_at))" >>"$timing_path"
printf 'acceptance_fast_%s_workspace_after_kb=%s\n' "$phase" "$after_kb" >>"$timing_path"
printf 'acceptance_fast_%s_workspace_peak_kb=%s\n' "$phase" "$peak_kb" >>"$timing_path"
printf 'acceptance_fast_%s_exit_code=%s\n' "$phase" "$command_status" >>"$timing_path"

exit "$command_status"
