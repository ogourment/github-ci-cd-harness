#!/usr/bin/env bash
set -euo pipefail

if [[ "${PHOENIX_TEST_DATABASE_PREFLIGHT:-on}" == "off" || "${CI:-}" == "true" ]]; then
  exit 0
fi

repo_root="${PHOENIX_TEST_DATABASE_REPO_ROOT:-$PWD}"
worktree_override="${PHOENIX_TEST_DATABASE_PREFLIGHT_WORKTREE:-}"

linked_worktree() {
  if [[ "$worktree_override" == "1" ]]; then
    return 0
  elif [[ "$worktree_override" == "0" ]]; then
    return 1
  fi

  local git_dir common_dir
  git_dir="$(git -C "$repo_root" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
  common_dir="$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  [[ -n "$git_dir" && -n "$common_dir" && "$git_dir" != "$common_dir" ]]
}

if linked_worktree && [[ -z "${MIX_TEST_PARTITION:-}" ]]; then
  printf '%s\n' 'TEST DATABASE ERROR: linked worktrees must set a stable, unique MIX_TEST_PARTITION.' >&2
  printf '%s\n' 'Retry with: MIX_TEST_PARTITION=<worktree-name> mix precommit' >&2
  exit 2
fi

if [[ -z "${MIX_TEST_PARTITION:-}" ]]; then
  exit 0
fi

mix_bin="${PHOENIX_TEST_DATABASE_MIX_BIN:-mix}"
if MIX_ENV=test "$mix_bin" ecto.create --quiet; then
  exit 0
fi

database_name="${PHOENIX_TEST_DATABASE_NAME:-<test-database-for-${MIX_TEST_PARTITION}>}"
database_owner="${PHOENIX_TEST_DATABASE_OWNER:-<application-role>}"

printf 'TEST DATABASE ERROR: partition %s is unavailable and the application role could not create it.\n' \
  "$MIX_TEST_PARTITION" >&2
printf '%s\n' 'Create it once using a PostgreSQL administrator, then retry:' >&2
printf '  createdb --username=<postgres-admin> --owner=%q %q\n' \
  "$database_owner" "$database_name" >&2
printf 'The creation command must run with MIX_ENV=test; plain `mix ecto.create` targets the default environment.\n' >&2
exit 2
