defmodule CiCdHarness.DeploymentLifecycleTest do
  use ExUnit.Case, async: true

  @dispatcher Path.expand(
                "../priv/ansible/roles/phoenix_blue_green/files/deployment_lifecycle.sh",
                __DIR__
              )

  test "delivers the lifecycle event and bounded deployment context" do
    fixture =
      Path.join(System.tmp_dir!(), "ci-cd-lifecycle-#{System.unique_integer([:positive])}")

    hook = Path.join(fixture, "hook")
    output = Path.join(fixture, "event")
    File.mkdir_p!(fixture)

    File.write!(hook, """
    #!/usr/bin/env bash
    set -euo pipefail
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
      "$1" "$CI_CD_DEPLOYMENT_EVENT" "$CI_CD_DEPLOYMENT_ID" \
      "$CI_CD_DEPLOYMENT_RELEASE_ID" "$CI_CD_DEPLOYMENT_PIPELINE_ID" \
      "$CI_CD_DEPLOYMENT_ENVIRONMENT" "$CI_CD_DEPLOYMENT_CURRENT_COLOR" \
      "$CI_CD_DEPLOYMENT_TARGET_COLOR" "$CI_CD_DEPLOYMENT_EXPIRES_AT_EPOCH" \
      > "$LIFECYCLE_TEST_OUTPUT"
    """)

    File.chmod!(hook, 0o755)
    on_exit(fn -> File.rm_rf!(fixture) end)

    {_, 0} =
      System.cmd(
        "bash",
        [
          @dispatcher,
          hook,
          "5",
          "begin-deployment",
          "staging:release-1",
          "release-1",
          "42",
          "staging",
          "blue",
          "green",
          "1787520000"
        ],
        env: [{"LIFECYCLE_TEST_OUTPUT", output}],
        stderr_to_stdout: true
      )

    assert File.read!(output) ==
             "begin-deployment|begin-deployment|staging:release-1|release-1|42|staging|blue|green|1787520000\n"
  end

  test "rejects unknown lifecycle events without calling the consumer" do
    fixture =
      Path.join(System.tmp_dir!(), "ci-cd-lifecycle-#{System.unique_integer([:positive])}")

    hook = Path.join(fixture, "hook")
    File.mkdir_p!(fixture)
    File.write!(hook, "#!/usr/bin/env bash\nexit 0\n")
    File.chmod!(hook, 0o755)
    on_exit(fn -> File.rm_rf!(fixture) end)

    {message, 64} =
      System.cmd(
        "bash",
        [
          @dispatcher,
          hook,
          "5",
          "begin-shutdown",
          "id",
          "release",
          "42",
          "staging",
          "blue",
          "green",
          "1787520000"
        ],
        stderr_to_stdout: true
      )

    assert message =~ "Unsupported deployment lifecycle event: begin-shutdown"
  end

  test "records bounded lifecycle state without release distribution or a consumer hook" do
    fixture =
      Path.join(System.tmp_dir!(), "ci-cd-lifecycle-state-#{System.unique_integer([:positive])}")

    state_file = Path.join(fixture, "deployment_lifecycle")
    File.mkdir_p!(fixture)
    on_exit(fn -> File.rm_rf!(fixture) end)

    assert {_, 0} =
             System.cmd(
               "bash",
               [
                 @dispatcher,
                 "",
                 "5",
                 "begin-deployment",
                 "production:release-1",
                 "release-1",
                 "42",
                 "production",
                 "green",
                 "blue",
                 "1787520000",
                 state_file
               ],
               stderr_to_stdout: true
             )

    assert File.read!(state_file) == "production:release-1\n1787520000\n"

    assert {_, 0} =
             System.cmd(
               "bash",
               [
                 @dispatcher,
                 "",
                 "5",
                 "deployment-complete",
                 "production:release-1",
                 "release-1",
                 "42",
                 "production",
                 "green",
                 "blue",
                 "1787520000",
                 state_file
               ],
               stderr_to_stdout: true
             )

    refute File.exists?(state_file)
  end

  test "does not clear lifecycle state belonging to another deployment" do
    fixture =
      Path.join(System.tmp_dir!(), "ci-cd-lifecycle-state-#{System.unique_integer([:positive])}")

    state_file = Path.join(fixture, "deployment_lifecycle")
    File.mkdir_p!(fixture)
    File.write!(state_file, "production:newer-release\n1787529999\n")
    on_exit(fn -> File.rm_rf!(fixture) end)

    assert {_, 0} =
             System.cmd(
               "bash",
               [
                 @dispatcher,
                 "",
                 "5",
                 "deployment-aborted",
                 "production:older-release",
                 "older-release",
                 "41",
                 "production",
                 "green",
                 "blue",
                 "1787520000",
                 state_file
               ],
               stderr_to_stdout: true
             )

    assert File.read!(state_file) == "production:newer-release\n1787529999\n"
  end
end
