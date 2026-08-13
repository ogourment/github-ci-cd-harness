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
end
