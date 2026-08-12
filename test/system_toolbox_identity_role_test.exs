defmodule CiCdHarness.SystemToolboxIdentityRoleTest do
  use ExUnit.Case, async: true

  @role Path.join(:code.priv_dir(:ci_cd_harness), "ansible/roles/system_toolbox_identity")

  test "ships an opt-in dedicated identity with a narrow privilege boundary" do
    defaults = read("defaults/main.yml")
    tasks = read("tasks/main.yml")
    unit = read("templates/system-toolbox.service.j2")

    assert defaults =~ "system_toolbox_dedicated_user_enabled: false"
    assert defaults =~ "system_toolbox_privileged_units: []"
    assert defaults =~ "system_toolbox_privileged_user_units: {}"
    assert defaults =~ ~s(system_toolbox_local_source: "")
    assert tasks =~ "Synchronize system-toolbox source from controller"
    assert tasks =~ ~s(rsync_path: "sudo -n rsync")
    assert tasks =~ ~s("--exclude=tmp/")
    assert tasks =~ "Synchronize dedicated system-toolbox dependencies"
    assert tasks =~ "execute-only access to source parents"
    assert tasks =~ "permissions: x"
    assert tasks =~ "system_toolbox_identity_available"
    assert tasks =~ "not ansible_check_mode"
    assert tasks =~ "shell: /usr/sbin/nologin"
    assert tasks =~ "dest: /usr/local/libexec/system-toolbox-maintenance"
    assert tasks =~ "path: /usr/local/libexec"
    assert tasks =~ "Remove deploy-user ACLs from privileged files"
    assert tasks =~ "dest: /etc/sudoers.d/system-toolbox-maintenance"
    assert tasks =~ "validate: /usr/sbin/visudo -cf %s"
    refute tasks =~ ~r/NOPASSWD:.*(?:apt|systemctl|python|\/bin\/(?:ba)?sh)/
    assert unit =~ "User={{ system_toolbox_user }}"
    assert unit =~ "SYSTEM_TOOLBOX_HOST_USER={{ deploy_user }}"
    assert unit =~ "SYSTEM_TOOLBOX_SERVICE_MANAGER=systemd"
    assert unit =~ "SuccessExitStatus=143"
    assert unit =~ "StateDirectory=system-toolbox"
  end

  test "migration verifies health and restores the legacy service on failure" do
    tasks = read("tasks/main.yml")

    assert tasks =~ "service_manager | default('') == 'systemd'"
    assert tasks =~ "Enable and restart dedicated system-toolbox service"
    assert tasks =~ "state: restarted"
    assert tasks =~ "Restore legacy deploy-user system-toolbox service"
    assert tasks =~ "the legacy\n          deploy-user service was restored"
  end

  defp read(relative), do: File.read!(Path.join(@role, relative))
end
