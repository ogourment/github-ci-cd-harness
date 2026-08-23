#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$root/scripts/resource_preflight.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

[[ -x "$script" ]] || { echo "missing executable resource preflight" >&2; exit 1; }

cat >"$tmp/meminfo" <<'EOF'
MemTotal:       16777216 kB
MemAvailable:  12582912 kB
SwapTotal:      4194304 kB
SwapFree:       4194304 kB
EOF
cat >"$tmp/psi" <<'EOF'
some avg10=0.00 avg60=0.00 avg300=0.00 total=0
full avg10=0.00 avg60=0.00 avg300=0.00 total=0
EOF
printf 'pswpin 0\npswpout 0\n' >"$tmp/vmstat"
RESOURCE_PREFLIGHT_MEMINFO_PATH="$tmp/meminfo" RESOURCE_PREFLIGHT_PSI_PATH="$tmp/psi" \
  RESOURCE_PREFLIGHT_VMSTAT_PATH="$tmp/vmstat" RESOURCE_PREFLIGHT_SAMPLE_SECONDS=0 "$script"

sed -i 's/MemAvailable:  12582912/MemAvailable:    524288/' "$tmp/meminfo"
if RESOURCE_PREFLIGHT_MEMINFO_PATH="$tmp/meminfo" RESOURCE_PREFLIGHT_PSI_PATH="$tmp/psi" \
  RESOURCE_PREFLIGHT_VMSTAT_PATH="$tmp/vmstat" RESOURCE_PREFLIGHT_SAMPLE_SECONDS=0 "$script" 2>"$tmp/error"; then
  echo "critical pressure should fail" >&2; exit 1
fi
grep -Fq 'Refusing this intensive command' "$tmp/error"
RESOURCE_PREFLIGHT=off "$script"

echo 'resource_preflight_test: passed'
