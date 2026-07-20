#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/scripts/resource_preflight.sh"
fixtures="$(mktemp -d)"
trap 'rm -rf "$fixtures"' EXIT

write_meminfo() {
  local path="$1" total="$2" available="$3" swap_total="$4" swap_free="$5"
  cat >"$path" <<EOF
MemTotal:       $total kB
MemAvailable:   $available kB
SwapTotal:      $swap_total kB
SwapFree:       $swap_free kB
EOF
}

write_psi() {
  local path="$1" some="$2" full="$3"
  cat >"$path" <<EOF
some avg10=$some avg60=0.00 avg300=0.00 total=0
full avg10=$full avg60=0.00 avg300=0.00 total=0
EOF
}

write_vmstat() {
  local path="$1" swap_in="$2" swap_out="$3"
  cat >"$path" <<EOF
pswpin $swap_in
pswpout $swap_out
EOF
}

write_psi "$fixtures/no-pressure" 0.00 0.00
write_vmstat "$fixtures/vmstat-before" 100 200
write_vmstat "$fixtures/vmstat-idle" 100 200

run_preflight() {
  RESOURCE_PREFLIGHT_PSI_PATH="$fixtures/no-pressure" \
    RESOURCE_PREFLIGHT_VMSTAT_PATH="$fixtures/vmstat-before" \
    RESOURCE_PREFLIGHT_VMSTAT_AFTER_PATH="$fixtures/vmstat-idle" \
    RESOURCE_PREFLIGHT_SAMPLE_SECONDS=0 \
    RESOURCE_PREFLIGHT_MEMINFO_PATH="$1" \
    "$script"
}

write_meminfo "$fixtures/healthy" 33554432 25165824 8388608 8388608
run_preflight "$fixtures/healthy"

write_meminfo "$fixtures/stale-swap" 33554432 15204352 8388608 1342177
stale_output="$(RESOURCE_PREFLIGHT_VERBOSE=1 run_preflight "$fixtures/stale-swap" 2>&1)"
[[ "$stale_output" == *'RESOURCE INFO:'* ]]
[[ "$stale_output" == *'no active memory pressure'* ]]

write_meminfo "$fixtures/warning" 33554432 3145728 8388608 3145728
warning_output="$(run_preflight "$fixtures/warning" 2>&1)"
[[ "$warning_output" == *'RESOURCE WARNING:'* ]]
[[ "$warning_output" == *'active swap I/O 0 pages/sample'* ]]

write_meminfo "$fixtures/incident" 33554432 2791572 8388608 172
set +e
critical_output="$(run_preflight "$fixtures/incident" 2>&1)"
critical_status=$?
set -e
[[ "$critical_status" -eq 2 ]]
[[ "$critical_output" == *'Refusing this intensive command'* ]]

write_meminfo "$fixtures/small" 4194304 1048576 0 0
run_preflight "$fixtures/small"

write_psi "$fixtures/pressure" 2.50 0.00
pressure_output="$(
  RESOURCE_PREFLIGHT_PSI_PATH="$fixtures/pressure" \
    RESOURCE_PREFLIGHT_VMSTAT_PATH="$fixtures/vmstat-before" \
    RESOURCE_PREFLIGHT_VMSTAT_AFTER_PATH="$fixtures/vmstat-idle" \
    RESOURCE_PREFLIGHT_SAMPLE_SECONDS=0 \
    RESOURCE_PREFLIGHT_MEMINFO_PATH="$fixtures/healthy" \
    "$script" 2>&1
)"
[[ "$pressure_output" == *'memory PSI some/full 2.50/0.00'* ]]

write_vmstat "$fixtures/vmstat-active" 164 264
swap_output="$(
  RESOURCE_PREFLIGHT_PSI_PATH="$fixtures/no-pressure" \
    RESOURCE_PREFLIGHT_VMSTAT_PATH="$fixtures/vmstat-before" \
    RESOURCE_PREFLIGHT_VMSTAT_AFTER_PATH="$fixtures/vmstat-active" \
    RESOURCE_PREFLIGHT_SAMPLE_SECONDS=0 \
    RESOURCE_PREFLIGHT_MEMINFO_PATH="$fixtures/healthy" \
    "$script" 2>&1
)"
[[ "$swap_output" == *'active swap I/O 128 pages/sample'* ]]

printf '%s\n' 'resource_preflight_test: passed'
