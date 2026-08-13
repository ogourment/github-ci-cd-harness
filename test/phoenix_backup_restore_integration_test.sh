#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
admin_url="${BACKUP_RESTORE_ADMIN_URL:-postgresql:///postgres}"
fixture_id="${CI_PIPELINE_ID:-$$}"
fixture_id="${fixture_id//[^0-9A-Za-z_]/_}"
source_db="harness_backup_source_${fixture_id}"
restore_db="harness_backup_restore_${fixture_id}"
work_dir="$(mktemp -d)"

cleanup() {
  dropdb --if-exists --force --maintenance-db="$admin_url" "$restore_db" >/dev/null 2>&1 || true
  dropdb --if-exists --force --maintenance-db="$admin_url" "$source_db" >/dev/null 2>&1 || true
  rm -rf "$work_dir"
}
trap cleanup EXIT

for command_name in ansible-playbook createdb dropdb pg_dump pg_isready pg_restore psql sha256sum tar; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'missing backup/restore contract dependency: %s\n' "$command_name" >&2
    exit 1
  }
done

case "$admin_url" in
  postgresql://*|postgres://*|postgresql:///*|postgres:///*) ;;
  *)
    printf 'BACKUP_RESTORE_ADMIN_URL must be a PostgreSQL connection URI\n' >&2
    exit 1
    ;;
esac

database_ready=false
for _attempt in $(seq 1 30); do
  if pg_isready --dbname "$admin_url" >/dev/null 2>&1; then
    database_ready=true
    break
  fi
  sleep 1
done
if [[ "$database_ready" != true ]]; then
  printf 'PostgreSQL did not become ready for the backup/restore contract\n' >&2
  exit 1
fi

createdb --maintenance-db="$admin_url" "$source_db"
source_url="${admin_url%/*}/${source_db}"
restore_url="${admin_url%/*}/${restore_db}"

psql "$source_url" -v ON_ERROR_STOP=1 <<'SQL'
CREATE TABLE backup_contract_items (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  label text NOT NULL
);
INSERT INTO backup_contract_items (label)
VALUES ('restored café'), ('restored workshop');
SQL

app_root="${work_dir}/app"
backup_root="${work_dir}/backups"
uploads_root="${work_dir}/consumer-images"
restored_uploads_root="${work_dir}/restored-survey-library"
env_file="${work_dir}/runtime"
color_file="${app_root}/current_color"
rendered_script="${work_dir}/phoenix_backup"
rendered_restore_script="${work_dir}/phoenix_backup_restore"

mkdir -p "${app_root}/releases/fixture" "$backup_root" "$uploads_root"
ln -s "${app_root}/releases/fixture" "${app_root}/current"
printf 'green\n' > "$color_file"
printf 'contract upload\n' > "${uploads_root}/evidence.txt"
printf "DATABASE_URL='%s'\nBACKUP_CONTRACT_UPLOADS_DIR='%s'\n" \
  "$source_url" "$uploads_root" > "${env_file}_green"

export BACKUP_CONTRACT_APP_ROOT="$app_root"
export BACKUP_CONTRACT_ENV_FILE="$env_file"
export BACKUP_CONTRACT_COLOR_FILE="$color_file"
export BACKUP_CONTRACT_ROOT="$backup_root"
export BACKUP_CONTRACT_PG_DUMP="$(command -v pg_dump)"
export BACKUP_CONTRACT_UPLOADS_ROOT="$uploads_root"
export BACKUP_CONTRACT_TEMPLATE="${root}/priv/ansible/roles/phoenix_backup/templates/backup.sh.j2"
export BACKUP_CONTRACT_SCRIPT="$rendered_script"
export BACKUP_CONTRACT_RESTORE_TEMPLATE="${root}/priv/ansible/roles/phoenix_backup/templates/restore.sh.j2"
export BACKUP_CONTRACT_RESTORE_SCRIPT="$rendered_restore_script"

ansible-playbook \
  -i localhost, \
  "${root}/test/fixtures/render_phoenix_backup.yml" >/dev/null

"$rendered_script"

snapshot="$(readlink -f "${backup_root}/latest")"
test -n "$snapshot"
test -f "${snapshot}/database.dump"
test -f "${snapshot}/uploads.tar.gz"
test -f "${snapshot}/metadata.env"

(
  cd "$snapshot"
  sha256sum -c SHA256SUMS
  pg_restore --list database.dump >/dev/null
  tar -tzf uploads.tar.gz | grep -Fq './evidence.txt'
)

createdb --maintenance-db="$admin_url" "$restore_db"
export RESTORE_DATABASE_URL="$restore_url"
RESTORE_DATABASE_URL="${RESTORE_DATABASE_URL/#postgresql:\/\//ecto://}"
RESTORE_DATABASE_URL="${RESTORE_DATABASE_URL/#postgres:\/\//ecto://}"
export RESTORE_DATABASE_URL
"$rendered_restore_script" all "$snapshot" "$restored_uploads_root"

restored_rows="$(
  psql "$restore_url" -Atqc \
    "SELECT count(*) || ':' || string_agg(label, ',' ORDER BY id) FROM backup_contract_items"
)"
test "$restored_rows" = '2:restored café,restored workshop'
test "$(cat "${restored_uploads_root}/evidence.txt")" = 'contract upload'
if "$rendered_restore_script" uploads "$snapshot" "$restored_uploads_root" >/dev/null 2>&1; then
  printf 'restore helper overwrote a non-empty persistent-files target\n' >&2
  exit 1
fi

grep -Fq 'BACKUP_FORMAT_VERSION=2' "${snapshot}/metadata.env"
grep -Fq 'BACKUP_APP_NAME=backup_contract' "${snapshot}/metadata.env"
grep -Fq 'BACKUP_RELEASE=' "${snapshot}/metadata.env"
grep -Fq 'BACKUP_UPLOADS_INCLUDED=true' "${snapshot}/metadata.env"

rm -rf "$uploads_root"
if "$rendered_script" >"${work_dir}/missing-uploads.log" 2>&1; then
  printf 'backup accepted a missing required persistent-files root\n' >&2
  exit 1
fi
grep -Fq 'required uploads directory is missing' "${work_dir}/missing-uploads.log"

printf 'phoenix backup/restore integration contract: ok\n'
