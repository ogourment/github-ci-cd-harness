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

write_meminfo "$fixtures/healthy" 33554432 25165824 8388608 8388608
RESOURCE_PREFLIGHT_MEMINFO_PATH="$fixtures/healthy" "$script"

write_meminfo "$fixtures/warning" 33554432 3145728 8388608 3145728
warning_output="$(RESOURCE_PREFLIGHT_MEMINFO_PATH="$fixtures/warning" "$script" 2>&1)"
[[ "$warning_output" == *'RESOURCE WARNING:'* ]]

write_meminfo "$fixtures/incident" 33554432 2791572 8388608 172
set +e
critical_output="$(RESOURCE_PREFLIGHT_MEMINFO_PATH="$fixtures/incident" "$script" 2>&1)"
critical_status=$?
set -e
[[ "$critical_status" -eq 2 ]]
[[ "$critical_output" == *'Refusing this intensive command'* ]]

write_meminfo "$fixtures/small" 4194304 1048576 0 0
RESOURCE_PREFLIGHT_MEMINFO_PATH="$fixtures/small" "$script"

printf '%s\n' 'resource_preflight_test: passed'
