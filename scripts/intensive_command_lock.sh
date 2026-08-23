#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -lt 3 || "$2" != "--" ]]; then
  printf 'Usage: %s <lock-name> -- <command> [args...]\n' "$0" >&2
  exit 64
fi
lock_name="$1"; shift 2
wait_for_lock="${RESOURCE_INTENSIVE_LOCK_WAIT:-0}"
if [[ "$wait_for_lock" != "0" && "$wait_for_lock" != "1" ]]; then
  printf '%s\n' 'RESOURCE_INTENSIVE_LOCK_WAIT must be 0 or 1.' >&2
  exit 64
fi
[[ "${RESOURCE_INTENSIVE_LOCK:-on}" != "off" ]] || exec "$@"

safe_lock_name="$(printf '%s' "$lock_name" | tr -c '[:alnum:]_.-' '_')"
lock_dir="${RESOURCE_LOCK_DIR:-${XDG_RUNTIME_DIR:-/tmp}/ci-cd-harness-locks}"
mkdir -p "$lock_dir"
lock_path="$lock_dir/$safe_lock_name.lock"

report_busy() {
  printf "RESOURCE BUSY: intensive command '%s' is already running.\n" "$lock_name" >&2
  [[ -z "$1" ]] || printf 'Current holder: %s\n' "$1" >&2
  printf '%s\n' 'Wait for it to finish instead of running concurrent suites against the same local resources.' >&2
  exit 2
}
report_wait() {
  printf "RESOURCE WAIT: intensive command '%s' is already running; waiting for its lock.\n" "$lock_name" >&2
  [[ -z "$1" ]] || printf 'Current holder: %s\n' "$1" >&2
}

if [[ "${RESOURCE_LOCK_BACKEND:-auto}" != "mkdir" ]] && command -v flock >/dev/null 2>&1; then
  exec 9>>"$lock_path"
  if ! flock -n 9; then
    holder="$(cat "$lock_path" 2>/dev/null || true)"
    if [[ "$wait_for_lock" == "1" ]]; then report_wait "$holder"; flock 9; else report_busy "$holder"; fi
  fi
  : >"$lock_path"
  printf 'pid=%s command=' "$$" >&9; printf '%q ' "$@" >&9; printf '\n' >&9
  exec "$@"
fi

mkdir_lock_path="$lock_dir/$safe_lock_name.lockdir"
wait_announced=false
while ! mkdir "$mkdir_lock_path" 2>/dev/null; do
  holder="$(cat "$mkdir_lock_path/holder" 2>/dev/null || true)"
  holder_pid="$(printf '%s' "$holder" | sed -n 's/^pid=\([0-9][0-9]*\).*/\1/p')"
  if [[ -n "$holder_pid" ]] && ! kill -0 "$holder_pid" 2>/dev/null; then
    rm -rf "$mkdir_lock_path"
  elif [[ "$wait_for_lock" == "1" ]]; then
    if [[ "$wait_announced" == false ]]; then report_wait "$holder"; wait_announced=true; fi
    sleep 2
  else
    report_busy "$holder"
  fi
done
printf 'pid=%s command=' "$$" >"$mkdir_lock_path/holder"
printf '%q ' "$@" >>"$mkdir_lock_path/holder"; printf '\n' >>"$mkdir_lock_path/holder"
trap 'rm -rf "$mkdir_lock_path"' EXIT
trap 'exit 130' HUP INT TERM
"$@"
