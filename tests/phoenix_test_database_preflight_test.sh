#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/scripts/phoenix_test_database_preflight.sh"
fixtures="$(mktemp -d)"
trap 'rm -rf "$fixtures"' EXIT

cat >"$fixtures/mix-ok" <<'EOF'
#!/usr/bin/env bash
printf '%s\t%s\n' "${MIX_ENV:-}" "$*" >>"$MIX_CALLS"
exit 0
EOF

cat >"$fixtures/mix-fail" <<'EOF'
#!/usr/bin/env bash
printf '%s\t%s\n' "${MIX_ENV:-}" "$*" >>"$MIX_CALLS"
exit 1
EOF

chmod +x "$fixtures/mix-ok" "$fixtures/mix-fail"
export MIX_CALLS="$fixtures/mix-calls"

set +e
missing_output="$(PHOENIX_TEST_DATABASE_PREFLIGHT_WORKTREE=1 "$script" 2>&1)"
missing_status=$?
set -e
[[ "$missing_status" -eq 2 ]]
[[ "$missing_output" == *'must set a stable, unique MIX_TEST_PARTITION'* ]]

MIX_TEST_PARTITION=feature \
  PHOENIX_TEST_DATABASE_PREFLIGHT_WORKTREE=1 \
  PHOENIX_TEST_DATABASE_MIX_BIN="$fixtures/mix-ok" \
  "$script"
[[ "$(cat "$MIX_CALLS")" == $'test\tecto.create --quiet' ]]

: >"$MIX_CALLS"
set +e
failure_output="$({
  MIX_TEST_PARTITION=feature \
    PHOENIX_TEST_DATABASE_PREFLIGHT_WORKTREE=1 \
    PHOENIX_TEST_DATABASE_MIX_BIN="$fixtures/mix-fail" \
    PHOENIX_TEST_DATABASE_NAME=ecojeux_testfeature \
    PHOENIX_TEST_DATABASE_OWNER=ecojeux_test \
    "$script"
} 2>&1)"
failure_status=$?
set -e
[[ "$failure_status" -eq 2 ]]
[[ "$failure_output" == *'createdb --username=<postgres-admin> --owner=ecojeux_test ecojeux_testfeature'* ]]
[[ "$failure_output" == *'plain `mix ecto.create` targets the default environment'* ]]
[[ "$(cat "$MIX_CALLS")" == $'test\tecto.create --quiet' ]]

PHOENIX_TEST_DATABASE_PREFLIGHT=off \
  PHOENIX_TEST_DATABASE_PREFLIGHT_WORKTREE=1 \
  "$script"

printf '%s\n' 'phoenix_test_database_preflight_test: passed'
