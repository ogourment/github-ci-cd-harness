#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/scripts/intensive_command_lock.sh"
fixtures="$(mktemp -d)"
holder_pid=''
trap '[[ -z "$holder_pid" ]] || kill "$holder_pid" 2>/dev/null || true; rm -rf "$fixtures"' EXIT

RESOURCE_LOCK_DIR="$fixtures" "$script" test-command -- true

# The smoke invocation above leaves its holder record behind. Remove it so the
# background holder below can use a newly written record as its ready signal.
rm -f "$fixtures/test-command.lock"
RESOURCE_LOCK_DIR="$fixtures" "$script" test-command -- sleep 2 &
holder_pid=$!
for _ in $(seq 1 50); do
  [[ -s "$fixtures/test-command.lock" ]] && break
  sleep 0.02
done

set +e
busy_output="$(RESOURCE_LOCK_DIR="$fixtures" "$script" test-command -- true 2>&1)"
busy_status=$?
set -e
[[ "$busy_status" -eq 2 ]]
[[ "$busy_output" == *"RESOURCE BUSY: intensive command 'test-command' is already running."* ]]
[[ "$busy_output" == *'Current holder: pid='* ]]

wait "$holder_pid"
holder_pid=''
RESOURCE_LOCK_DIR="$fixtures" "$script" test-command -- true

RESOURCE_LOCK_BACKEND=mkdir RESOURCE_LOCK_DIR="$fixtures" "$script" portable-command -- sleep 2 &
holder_pid=$!
for _ in $(seq 1 50); do
  [[ -s "$fixtures/portable-command.lockdir/holder" ]] && break
  sleep 0.02
done

set +e
portable_busy_output="$(RESOURCE_LOCK_BACKEND=mkdir RESOURCE_LOCK_DIR="$fixtures" "$script" portable-command -- true 2>&1)"
portable_busy_status=$?
set -e
[[ "$portable_busy_status" -eq 2 ]]
[[ "$portable_busy_output" == *"RESOURCE BUSY: intensive command 'portable-command' is already running."* ]]

wait "$holder_pid"
holder_pid=''
RESOURCE_LOCK_BACKEND=mkdir RESOURCE_LOCK_DIR="$fixtures" "$script" portable-command -- true

RESOURCE_LOCK_BACKEND=mkdir RESOURCE_LOCK_DIR="$fixtures" "$script" waiting-command -- sleep 1 &
holder_pid=$!
for _ in $(seq 1 50); do
  [[ -s "$fixtures/waiting-command.lockdir/holder" ]] && break
  sleep 0.02
done
wait_output="$(
  RESOURCE_INTENSIVE_LOCK_WAIT=1 RESOURCE_LOCK_BACKEND=mkdir RESOURCE_LOCK_DIR="$fixtures" \
    "$script" waiting-command -- true 2>&1
)"
[[ "$wait_output" == *"RESOURCE WAIT: intensive command 'waiting-command' is already running"* ]]
wait "$holder_pid"
holder_pid=''

printf '%s\n' 'intensive_command_lock_test: passed'
