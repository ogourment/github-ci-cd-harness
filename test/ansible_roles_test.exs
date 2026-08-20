defmodule CiCdHarness.AnsibleRolesTest do
  use ExUnit.Case, async: true

  @roles_root Path.join(:code.priv_dir(:ci_cd_harness), "ansible/roles")
  @roles ~w(common phoenix_backup phoenix_blue_green phoenix_postgres
            system_toolbox_identity web)

  test "ships every reusable infrastructure role" do
    assert Enum.sort(File.ls!(@roles_root)) == Enum.sort(@roles)

    for role <- @roles do
      assert File.dir?(Path.join(@roles_root, role)), "missing Ansible role: #{role}"

      assert File.exists?(Path.join([@roles_root, role, "tasks", "main.yml"])),
             "missing task entrypoint for Ansible role: #{role}"
    end
  end

  test "backup role retains its executable restore contract" do
    backup = Path.join(@roles_root, "phoenix_backup/templates/backup.sh.j2")
    restore = Path.join(@roles_root, "phoenix_backup/templates/restore.sh.j2")

    assert File.read!(backup) =~ "BACKUP_FORMAT_VERSION=2"
    assert File.read!(restore) =~ "RESTORE_DATABASE_URL"
  end

  test "backup role can omit regenerable table data and says so in the snapshot" do
    backup = Path.join(@roles_root, "phoenix_backup/templates/backup.sh.j2")
    restore = Path.join(@roles_root, "phoenix_backup/templates/restore.sh.j2")

    backup_source = File.read!(backup)

    assert backup_source =~ "backup_exclude_table_data | default([])"
    assert backup_source =~ "--exclude-table-data="
    assert backup_source =~ "BACKUP_EXCLUDED_TABLE_DATA="

    # Restoring a snapshot with an empty table must be distinguishable from
    # restoring one that lost the data.
    assert File.read!(restore) =~ "BACKUP_EXCLUDED_TABLE_DATA"
  end

  test "web role keeps production indexable and marks non-production responses" do
    defaults = File.read!(Path.join(@roles_root, "web/defaults/main.yml"))
    template = File.read!(Path.join(@roles_root, "web/templates/app.nginx.j2"))

    assert defaults =~ "app_is_production: true"

    assert length(Regex.scan(~r/{% if not app_is_production \| default\(true\) %}/, template)) ==
             2

    assert length(Regex.scan(~r/add_header X-Robots-Tag "noindex, nofollow" always;/, template)) ==
             2
  end
end
