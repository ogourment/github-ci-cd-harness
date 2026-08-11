#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(pwd -P)"

output_dir="${EXUNIT_TEST_VALUE_AUDIT_OUTPUT_DIR:-tmp/ci/exunit_test_value_audit}"
overlap_threshold="${EXUNIT_TEST_VALUE_AUDIT_OVERLAP_THRESHOLD:-0.95}"
minimum_overlap_points="${EXUNIT_TEST_VALUE_AUDIT_MIN_OVERLAP_POINTS:-10}"
max_modules="${EXUNIT_TEST_VALUE_AUDIT_MAX_MODULES:-0}"
include_slow="${EXUNIT_TEST_VALUE_AUDIT_INCLUDE_SLOW:-false}"
# Comma-separated ExUnit tags to exclude. A module the audit cannot run aborts
# the whole collection, so a project whose suite needs an external service for
# some tests names their tag here rather than shrinking the audit.
exclude_tags="${EXUNIT_TEST_VALUE_AUDIT_EXCLUDE_TAGS:-}"
mix_env="${EXUNIT_TEST_VALUE_AUDIT_MIX_ENV:-test}"

case "$output_dir" in
  ""|"."|".."|/*|../*|*/../*|*/..)
    echo "EXUNIT_TEST_VALUE_AUDIT_OUTPUT_DIR must be a non-empty relative path inside the project." >&2
    exit 2
    ;;
esac

case "$max_modules" in
  ""|*[!0-9]*)
    echo "EXUNIT_TEST_VALUE_AUDIT_MAX_MODULES must be a non-negative integer." >&2
    exit 2
    ;;
esac

case "$minimum_overlap_points" in
  ""|*[!0-9]*|0)
    echo "EXUNIT_TEST_VALUE_AUDIT_MIN_OVERLAP_POINTS must be a positive integer." >&2
    exit 2
    ;;
esac

resolved_output="$(realpath -m "$project_root/$output_dir")"
case "$resolved_output" in
  "$project_root"/*) ;;
  *)
    echo "Audit output must resolve inside the current project." >&2
    exit 2
    ;;
esac

if [[ ! -f mix.exs || ! -f test/test_helper.exs ]]; then
  echo "Run the audit from an Elixir project root containing mix.exs and test/test_helper.exs." >&2
  exit 2
fi

rm -rf -- "$resolved_output"
mkdir -p "$resolved_output/signatures" "$resolved_output/logs"

if [[ "$include_slow" != "true" && "$include_slow" != "false" ]]; then
  echo "EXUNIT_TEST_VALUE_AUDIT_INCLUDE_SLOW must be true or false." >&2
  exit 2
fi

if [[ -n "$exclude_tags" && ! "$exclude_tags" =~ ^[a-z_][a-z0-9_]*(,[a-z_][a-z0-9_]*)*$ ]]; then
  echo "EXUNIT_TEST_VALUE_AUDIT_EXCLUDE_TAGS must be comma-separated tag names." >&2
  exit 2
fi

batch_log="$resolved_output/logs/batch.log"

if ! MIX_ENV="$mix_env" mix run "$script_dir/exunit_test_value_collect.exs" \
  "$resolved_output" \
  "$max_modules" \
  "$include_slow" \
  "$exclude_tags" >"$batch_log" 2>&1; then
  echo "Batched ExUnit test-value collection failed." >&2
  tail -n 100 "$batch_log" >&2
  exit 1
fi

elixir "$script_dir/exunit_test_value_report.exs" \
  "$resolved_output/signatures" \
  "$resolved_output" \
  "$overlap_threshold" \
  "$resolved_output/collection.tsv" \
  "$minimum_overlap_points"

echo
echo "ExUnit test-value audit completed."
echo "Report: $output_dir/report.md"
echo "Machine-readable report: $output_dir/report.json"
