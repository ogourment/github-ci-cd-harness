#!/usr/bin/env bash
set -euo pipefail

if [[ "${RESOURCE_PREFLIGHT:-on}" == "off" ]]; then
  printf '%s\n' 'Resource preflight disabled by RESOURCE_PREFLIGHT=off.' >&2
  exit 0
fi

meminfo_path="${RESOURCE_PREFLIGHT_MEMINFO_PATH:-/proc/meminfo}"

# MemAvailable includes reclaimable caches and is safer than MemFree.
if [[ ! -r "$meminfo_path" ]]; then
  exit 0
fi

read_kib() {
  local field="$1"
  awk -v field="${field}:" '$1 == field {print $2; exit}' "$meminfo_path"
}

mem_total_kib="$(read_kib MemTotal)"
mem_available_kib="$(read_kib MemAvailable)"
swap_total_kib="$(read_kib SwapTotal)"
swap_free_kib="$(read_kib SwapFree)"

if [[ ! "$mem_total_kib" =~ ^[0-9]+$ || ! "$mem_available_kib" =~ ^[0-9]+$ ||
      ! "$swap_total_kib" =~ ^[0-9]+$ || ! "$swap_free_kib" =~ ^[0-9]+$ ||
      "$mem_total_kib" -eq 0 ]]; then
  printf '%s\n' "RESOURCE WARNING: could not parse memory data from $meminfo_path; continuing." >&2
  exit 0
fi

min_value() {
  if (( $1 < $2 )); then printf '%s' "$1"; else printf '%s' "$2"; fi
}

swap_used_kib=$((swap_total_kib > swap_free_kib ? swap_total_kib - swap_free_kib : 0))
if (( swap_total_kib > 0 )); then
  swap_percent=$((swap_used_kib * 100 / swap_total_kib))
else
  swap_percent=0
fi

warning_available_kib="$(min_value 4194304 $((mem_total_kib * 20 / 100)))"
critical_available_kib="$(min_value 2097152 $((mem_total_kib * 8 / 100)))"
swap_pressure_available_kib="$(min_value 4194304 $((mem_total_kib * 15 / 100)))"

status=ok
if (( mem_available_kib <= critical_available_kib )) ||
   (( swap_percent >= 90 && mem_available_kib <= swap_pressure_available_kib )); then
  status=critical
elif (( mem_available_kib <= warning_available_kib || swap_percent >= 80 )); then
  status=warning
fi

if [[ "$status" == "ok" ]]; then
  exit 0
fi

available_tenths=$((mem_available_kib * 10 / 1048576))
message="RESOURCE WARNING: $((available_tenths / 10)).$((available_tenths % 10)) GiB RAM available; swap ${swap_percent}% used."

if [[ "$status" == "warning" ]]; then
  printf '%s\n' "$message Close heavy applications before continuing." >&2
  exit 0
fi

printf '%s\n' "$message Refusing this intensive command to avoid system thrashing." >&2
printf '%s\n' 'Free memory and retry, or deliberately bypass once with RESOURCE_PREFLIGHT=off.' >&2
exit 2
