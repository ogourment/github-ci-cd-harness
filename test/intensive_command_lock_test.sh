#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$root/scripts/intensive_command_lock.sh"
tmp="$(mktemp -d)"
holder_pid=''
trap '[[ -z "$holder_pid" ]] || kill "$holder_pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT
[[ -x "$script" ]]

RESOURCE_LOCK_BACKEND=mkdir RESOURCE_LOCK_DIR="$tmp" "$script" shared -- sleep 1 &
holder_pid=$!
for _ in $(seq 1 50); do [[ -s "$tmp/shared.lockdir/holder" ]] && break; sleep 0.02; done
set +e
busy="$(RESOURCE_LOCK_BACKEND=mkdir RESOURCE_LOCK_DIR="$tmp" "$script" shared -- true 2>&1)"
status=$?
set -e
[[ "$status" -eq 2 && "$busy" == *'RESOURCE BUSY'* && "$busy" == *'Current holder: pid='* ]]
wait "$holder_pid"; holder_pid=''

RESOURCE_LOCK_BACKEND=mkdir RESOURCE_LOCK_DIR="$tmp" "$script" waiting -- sleep 1 &
holder_pid=$!
for _ in $(seq 1 50); do [[ -s "$tmp/waiting.lockdir/holder" ]] && break; sleep 0.02; done
wait_message="$(RESOURCE_INTENSIVE_LOCK_WAIT=1 RESOURCE_LOCK_BACKEND=mkdir RESOURCE_LOCK_DIR="$tmp" "$script" waiting -- true 2>&1)"
[[ "$wait_message" == *'RESOURCE WAIT'* ]]
wait "$holder_pid"; holder_pid=''

mkdir "$tmp/stale.lockdir"; printf 'pid=999999 command=old\n' >"$tmp/stale.lockdir/holder"
RESOURCE_LOCK_BACKEND=mkdir RESOURCE_LOCK_DIR="$tmp" "$script" stale -- true
[[ ! -d "$tmp/stale.lockdir" ]]
RESOURCE_INTENSIVE_LOCK=off "$script" bypass -- true
echo 'intensive_command_lock_test: passed'
