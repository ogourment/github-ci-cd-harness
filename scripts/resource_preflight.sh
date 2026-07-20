#!/usr/bin/env bash
set -euo pipefail

if [[ "${RESOURCE_PREFLIGHT:-on}" == "off" ]]; then
  printf '%s\n' 'Resource preflight disabled by RESOURCE_PREFLIGHT=off.' >&2
  exit 0
fi

meminfo_path="${RESOURCE_PREFLIGHT_MEMINFO_PATH:-/proc/meminfo}"
psi_path="${RESOURCE_PREFLIGHT_PSI_PATH:-/proc/pressure/memory}"
vmstat_path="${RESOURCE_PREFLIGHT_VMSTAT_PATH:-/proc/vmstat}"
vmstat_after_path="${RESOURCE_PREFLIGHT_VMSTAT_AFTER_PATH:-$vmstat_path}"
sample_seconds="${RESOURCE_PREFLIGHT_SAMPLE_SECONDS:-0.25}"

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

read_vmstat() {
  local field="$1" path="$2"
  if [[ -r "$path" ]]; then
    awk -v field="$field" '$1 == field {print $2; exit}' "$path"
  fi
}

psi_some_avg10=0
psi_full_avg10=0
if [[ -r "$psi_path" ]]; then
  psi_some_avg10="$(awk '$1 == "some" {sub("avg10=", "", $2); print $2; exit}' "$psi_path")"
  psi_full_avg10="$(awk '$1 == "full" {sub("avg10=", "", $2); print $2; exit}' "$psi_path")"
  [[ "$psi_some_avg10" =~ ^[0-9]+([.][0-9]+)?$ ]] || psi_some_avg10=0
  [[ "$psi_full_avg10" =~ ^[0-9]+([.][0-9]+)?$ ]] || psi_full_avg10=0
fi

swap_in_before="$(read_vmstat pswpin "$vmstat_path")"
swap_out_before="$(read_vmstat pswpout "$vmstat_path")"
swap_in_delta=0
swap_out_delta=0
if [[ "$swap_in_before" =~ ^[0-9]+$ && "$swap_out_before" =~ ^[0-9]+$ ]]; then
  if [[ "$vmstat_after_path" == "$vmstat_path" && "$sample_seconds" != "0" ]]; then
    sleep "$sample_seconds"
  fi
  swap_in_after="$(read_vmstat pswpin "$vmstat_after_path")"
  swap_out_after="$(read_vmstat pswpout "$vmstat_after_path")"
  if [[ "$swap_in_after" =~ ^[0-9]+$ && "$swap_out_after" =~ ^[0-9]+$ ]]; then
    (( swap_in_after >= swap_in_before )) && swap_in_delta=$((swap_in_after - swap_in_before))
    (( swap_out_after >= swap_out_before )) && swap_out_delta=$((swap_out_after - swap_out_before))
  fi
fi
swap_activity_pages=$((swap_in_delta + swap_out_delta))

float_ge() {
  awk -v actual="$1" -v threshold="$2" 'BEGIN {exit !(actual >= threshold)}'
}

pressure_active=false
pressure_severe=false
if float_ge "$psi_some_avg10" "${RESOURCE_PREFLIGHT_PSI_WARNING:-1.0}" ||
   (( swap_activity_pages >= ${RESOURCE_PREFLIGHT_SWAP_ACTIVITY_WARNING_PAGES:-64} )); then
  pressure_active=true
fi
if float_ge "$psi_full_avg10" "${RESOURCE_PREFLIGHT_PSI_CRITICAL:-0.5}" ||
   (( swap_activity_pages >= ${RESOURCE_PREFLIGHT_SWAP_ACTIVITY_CRITICAL_PAGES:-1024} )); then
  pressure_severe=true
fi

status=ok
if (( mem_available_kib <= critical_available_kib )) ||
   (( swap_percent >= 90 && mem_available_kib <= swap_pressure_available_kib )) ||
   [[ "$pressure_severe" == true && "$mem_available_kib" -le "$swap_pressure_available_kib" ]]; then
  status=critical
elif (( mem_available_kib <= warning_available_kib )) || [[ "$pressure_active" == true ]]; then
  status=warning
fi

if [[ "$status" == "ok" ]]; then
  if (( swap_percent >= 80 )) && [[ "${RESOURCE_PREFLIGHT_VERBOSE:-0}" == "1" ]]; then
    printf 'RESOURCE INFO: swap %s%% occupied historically; no active memory pressure detected.\n' "$swap_percent" >&2
  fi
  exit 0
fi

available_tenths=$((mem_available_kib * 10 / 1048576))
message="RESOURCE WARNING: $((available_tenths / 10)).$((available_tenths % 10)) GiB RAM available; swap ${swap_percent}% occupied; active swap I/O ${swap_activity_pages} pages/sample; memory PSI some/full ${psi_some_avg10}/${psi_full_avg10}."

if [[ "$status" == "warning" ]]; then
  printf '%s\n' "$message Close heavy applications before continuing." >&2
  exit 0
fi

printf '%s\n' "$message Refusing this intensive command to avoid system thrashing." >&2
printf '%s\n' 'Free memory and retry, or deliberately bypass once with RESOURCE_PREFLIGHT=off.' >&2
exit 2
