#!/usr/bin/env bash
set -euo pipefail

BUDGET_FILE="${1:-}"
shift || true

THRESHOLD_PERCENT="${EXUNIT_TEST_BUDGET_THRESHOLD_PERCENT:-10}"
MEASURED_FILE="${EXUNIT_TEST_BUDGET_MEASURED_FILE:-tmp/ci/exunit_test_budget_measured.tsv}"

if [[ -z "${BUDGET_FILE}" || ! -f "${BUDGET_FILE}" ]]; then
  echo "Usage: $0 BUDGET_FILE EXUNIT_TRACE_LOG..." >&2
  exit 2
fi

if (($# == 0)); then
  echo "At least one ExUnit trace log is required." >&2
  exit 2
fi

for log_file in "$@"; do
  if [[ ! -f "${log_file}" ]]; then
    echo "Missing ExUnit trace log: ${log_file}" >&2
    exit 2
  fi
done

mkdir -p "$(dirname "${MEASURED_FILE}")"
measurements="$(mktemp)"
trap 'rm -f "${measurements}"' EXIT

awk '
  BEGIN {
    RS = "\r|\n"
  }

  match($0, / \[[^][]+\.exs\]$/) {
    file = substr($0, RSTART + 2, RLENGTH - 3)
    next
  }

  file != "" && $0 ~ /^  \* test / && $0 ~ /\([0-9]+(\.[0-9]+)?(ms|s|us|µs)\) \[L#[0-9]+\]$/ {
    line = $0
    sub(/^  \* /, "", line)

    test_name = line
    sub(/ \([0-9]+(\.[0-9]+)?(ms|s|us|µs)\) \[L#[0-9]+\]$/, "", test_name)

    duration = line
    sub(/^.* \(/, "", duration)
    sub(/\) \[L#[0-9]+\]$/, "", duration)

    line_number = line
    sub(/^.*\[L#/, "", line_number)
    sub(/\]$/, "", line_number)

    value = duration
    sub(/(ms|s|us|µs)$/, "", value)

    if (duration ~ /ms$/) {
      milliseconds = value + 0
    } else if (duration ~ /(us|µs)$/) {
      milliseconds = (value + 0) / 1000
    } else {
      milliseconds = (value + 0) * 1000
    }

    printf "%s|%s|%s|%.3f\n", test_name, file, line_number, milliseconds
  }
' "$@" >"${measurements}"

: >"${MEASURED_FILE}"
failures=0

echo "ExUnit runtime budget report:"

while IFS='|' read -r test_name file_path line_hint baseline_ms; do
  if [[ -z "${test_name}" || "${test_name}" == \#* ]]; then
    continue
  fi

  test_display="${file_path}"
  if [[ -n "${line_hint}" ]]; then
    test_display="${file_path}:${line_hint}"
  fi

  measurement="$(
    awk -F '|' -v name="${test_name}" -v file="${file_path}" \
      '$1 == name && $2 == file { found = $0 } END { print found }' \
      "${measurements}"
  )"

  if [[ -z "${measurement}" ]]; then
    echo "FAIL missing measurement: ${test_display} :: ${test_name}"
    failures=$((failures + 1))
    continue
  fi

  measured_line="$(printf '%s\n' "${measurement}" | awk -F '|' '{ print $3 }')"
  measured_ms="$(printf '%s\n' "${measurement}" | awk -F '|' '{ printf "%g", $4 }')"
  printf '%s|%s|%s|%s\n' \
    "${test_name}" "${file_path}" "${measured_line:-${line_hint}}" "${measured_ms}" \
    >>"${MEASURED_FILE}"

  allowed_ms="$(
    awk -v base="${baseline_ms}" -v pct="${THRESHOLD_PERCENT}" \
      'BEGIN { printf "%.1f", base * (100 + pct) / 100.0 }'
  )"

  if awk -v actual="${measured_ms}" -v allowed="${allowed_ms}" \
    'BEGIN { exit (actual <= allowed) ? 0 : 1 }'; then
    echo "PASS ${test_display} :: ${test_name} (measured ${measured_ms}ms, budget ${baseline_ms}ms, max ${allowed_ms}ms)"
  else
    echo "FAIL ${test_display} :: ${test_name} (measured ${measured_ms}ms, budget ${baseline_ms}ms, max ${allowed_ms}ms)"
    failures=$((failures + 1))
  fi
done <"${BUDGET_FILE}"

if ((failures > 0)); then
  echo "ExUnit runtime budget check failed with ${failures} regression(s)." >&2
  exit 1
fi

echo "ExUnit runtime budget check passed."
