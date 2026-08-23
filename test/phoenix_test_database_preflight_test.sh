#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$root/scripts/phoenix_test_database_preflight.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

[[ -x "$script" ]] || { echo "missing executable database preflight" >&2; exit 1; }
cat >"$tmp/mix" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "${MIX_ENV:-}" "$*" >>"$MIX_CAPTURE"
exit "${MIX_EXIT:-0}"
EOF
chmod +x "$tmp/mix"

MIX_CAPTURE="$tmp/capture" PHOENIX_TEST_DATABASE_MIX_BIN="$tmp/mix" \
  PHOENIX_TEST_DATABASE_PREFLIGHT_WORKTREE=1 MIX_TEST_PARTITION=worker1 "$script"
grep -Fq 'test ecto.create --quiet' "$tmp/capture"

if PHOENIX_TEST_DATABASE_PREFLIGHT_WORKTREE=1 "$script" 2>"$tmp/error"; then
  echo "linked worktree without partition should fail" >&2; exit 1
fi
grep -Fq 'must set a stable, unique MIX_TEST_PARTITION' "$tmp/error"

MIX_CAPTURE="$tmp/capture2" MIX_EXIT=1 PHOENIX_TEST_DATABASE_MIX_BIN="$tmp/mix" \
  PHOENIX_TEST_DATABASE_PREFLIGHT_WORKTREE=1 MIX_TEST_PARTITION=worker2 \
  PHOENIX_TEST_DATABASE_NAME=app_testworker2 PHOENIX_TEST_DATABASE_OWNER=app_test "$script" 2>"$tmp/create-error" && exit 1
grep -Fq 'createdb --username=<postgres-admin> --owner=app_test app_testworker2' "$tmp/create-error"

echo 'phoenix_test_database_preflight_test: passed'
