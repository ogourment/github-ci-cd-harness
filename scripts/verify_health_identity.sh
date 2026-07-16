#!/bin/sh
set -eu

health_file="${1:?health JSON path required}"
expected_version="${2:?expected version required}"
expected_release_id="${3:?expected release ID required}"
expected_pipeline_id="${4:?expected pipeline ID required}"

json_value() {
  key="$1"
  sed -nE "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/p" "$health_file" | tail -n 1
}

actual_version="$(json_value version)"
actual_release_id="$(json_value release_id)"
actual_pipeline_id="$(json_value pipeline_id)"

if [ "$actual_version" = "$expected_version" ] && \
  [ "$actual_release_id" = "$expected_release_id" ] && \
  [ "$actual_pipeline_id" = "$expected_pipeline_id" ]; then
  exit 0
fi

printf '%s\n' \
  "ERROR: deployed health identity mismatch" \
  "  expected: version=${expected_version} release_id=${expected_release_id} pipeline_id=${expected_pipeline_id}" \
  "  actual:   version=${actual_version:-<missing>} release_id=${actual_release_id:-<missing>} pipeline_id=${actual_pipeline_id:-<missing>}" >&2
exit 1
