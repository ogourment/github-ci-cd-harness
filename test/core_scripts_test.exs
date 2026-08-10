defmodule CiCdHarness.CoreScriptsTest do
  @moduledoc """
  The delivery scripts used to live in a repository cloned at a fixed directory
  name, and referred to each other through that name. A consumer that cloned it
  elsewhere got a deploy that ran, reported success, and then failed on a
  missing sibling — after deploying. These guard the extraction.
  """
  use ExUnit.Case, async: true

  @core Path.join(:code.priv_dir(:ci_cd_harness), "core")

  @scripts ~w(
    acceptance_evidence.sh
    atdd_remote_copy.sh
    ci_cd_alert_event.sh
    atdd_remote_eval.sh
    deploy_release_fast.sh
    exunit_test_budget.sh
    exunit_test_value_audit.sh
    notify_deployment.sh
    notify_message.sh
    release_tag.sh
    verify_health_identity.sh
  )

  test "every delivery script ships and is executable" do
    for script <- @scripts do
      path = Path.join(@core, script)
      assert File.exists?(path), "#{script} is missing from priv/core"
      %{mode: mode} = File.stat!(path)
      assert Bitwise.band(mode, 0o111) != 0, "#{script} is not executable"
    end
  end

  test "no script depends on being cloned into a particular directory name" do
    for script <- @scripts do
      body = File.read!(Path.join(@core, script))

      refute body =~ ".gitlab-ci-cd-harness/",
             "#{script} still resolves a sibling through a fixed clone directory"
    end
  end

  test "scripts find their siblings relative to themselves" do
    body = File.read!(Path.join(@core, "deploy_release_fast.sh"))

    assert body =~ ~s|"$(dirname "${BASH_SOURCE[0]}")/verify_health_identity.sh"|
  end

  test "every script parses" do
    for script <- @scripts do
      {output, status} = System.cmd("bash", ["-n", Path.join(@core, script)], stderr_to_stdout: true)
      assert status == 0, "#{script} does not parse: #{output}"
    end
  end
end
