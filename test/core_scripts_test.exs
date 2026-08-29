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
    acceptance_fast_timing.sh
    atdd_generate_thumbnails.sh
    atdd_remote_copy.sh
    ci_cd_alert_event.sh
    atdd_remote_eval.sh
    deploy_release_fast.sh
    exunit_test_budget.sh
    exunit_test_value_audit.sh
    exunit_test_value_collect.exs
    exunit_test_value_report.exs
    notify_deployment.sh
    notify_message.sh
    pipeline_acceptance_report.sh
    release_tag.sh
    staging_release_smoke.sh
    verify_health_identity.sh
  )

  @shell_scripts Enum.filter(@scripts, &String.ends_with?(&1, ".sh"))

  test "every delivery script ships and is executable" do
    for script <- @scripts do
      path = Path.join(@core, script)
      assert File.exists?(path), "#{script} is missing from priv/core"
      %{mode: mode} = File.stat!(path)
      assert Bitwise.band(mode, 0o111) != 0, "#{script} is not executable"
    end
  end

  test "no script depends on being cloned into a particular directory name" do
    predecessor_directory = "." <> Enum.join(["gitlab", "ci", "cd", "harness"], "-") <> "/"

    for script <- @scripts do
      body = File.read!(Path.join(@core, script))

      refute body =~ predecessor_directory,
             "#{script} still resolves a sibling through a fixed clone directory"
    end
  end

  test "scripts find their siblings relative to themselves" do
    body = File.read!(Path.join(@core, "deploy_release_fast.sh"))

    assert body =~ ~s|"$(dirname "${BASH_SOURCE[0]}")/verify_health_identity.sh"|
  end

  test "deployment timing metadata is optional outside GitLab" do
    body = File.read!(Path.join(@core, "deploy_release_fast.sh"))

    refute body =~ ~s|gitlab_api_json "${CI_API_V4_URL}/|
    assert body =~ ~s|gitlab_api_json "${CI_API_V4_URL:-}/|
  end

  test "deployment notification lists every commit since the previous deployed release" do
    tmp = Path.join(System.tmp_dir!(), "ci-cd-notify-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "_build"))

    git = fn args ->
      {output, 0} = System.cmd("git", args, cd: tmp, stderr_to_stdout: true)
      String.trim(output)
    end

    git.(["init", "-q"])
    git.(["config", "user.email", "delivery@example.test"])
    git.(["config", "user.name", "Delivery Test"])

    commits =
      for subject <- [
            "Version déployée",
            "Premier changement",
            "Deuxième changement",
            "Troisième changement"
          ] do
        File.write!(Path.join(tmp, "change.txt"), subject)
        git.(["add", "change.txt"])
        git.(["commit", "-q", "-m", subject])
        git.(["rev-parse", "HEAD"])
      end

    [deployed_sha, _first_sha, second_sha, current_sha] = commits
    app = "notify_contract_#{System.unique_integer([:positive])}"
    previous_health = "/tmp/#{app}_prod_previous_health.json"

    File.write!(
      previous_health,
      ~s({"release_id":"v0.1.0-#{String.slice(deployed_sha, 0, 8)}-100"})
    )

    File.write!(
      Path.join(tmp, "_build/RELEASE_ID"),
      "v0.1.1-#{String.slice(current_sha, 0, 8)}-200"
    )

    File.write!(Path.join(tmp, "_build/VERSION"), "0.1.1")

    on_exit(fn ->
      File.rm_rf!(tmp)
      File.rm(previous_health)
    end)

    {message, 0} =
      System.cmd("bash", [Path.join(@core, "notify_deployment.sh")],
        cd: tmp,
        env: [
          {"CI_CD_OTP_APP", app},
          {"CI_CD_DEPLOY_TARGET", "prod"},
          {"CI_COMMIT_SHA", current_sha},
          {"CI_COMMIT_BEFORE_SHA", second_sha},
          {"CI_JOB_STATUS", "success"}
        ],
        stderr_to_stdout: true
      )

    assert message =~ "Commits: 3"
    assert message =~ "Premier changement"
    assert message =~ "Deuxième changement"
    assert message =~ "Troisième changement"
    refute message =~ "Version déployée"
  end

  test "every shell script parses" do
    for script <- @shell_scripts do
      {output, status} =
        System.cmd("bash", ["-n", Path.join(@core, script)], stderr_to_stdout: true)

      assert status == 0, "#{script} does not parse: #{output}"
    end
  end

  test "fast acceptance timing records setup and test phases with workspace peak" do
    tmp = Path.join(System.tmp_dir!(), "ci-cd-fast-timing-#{System.unique_integer([:positive])}")
    timing = Path.join(tmp, "tmp/atdd-fast/timing.env")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    {output, 0} =
      System.cmd(
        "bash",
        [
          Path.join(@core, "acceptance_fast_timing.sh"),
          "setup",
          "mkdir -p _build/test && dd if=/dev/zero of=_build/test/build.bin bs=1024 count=2 status=none"
        ],
        cd: tmp,
        env: [{"ACCEPTANCE_FAST_TIMING_PATH", timing}],
        stderr_to_stdout: true
      )

    assert output == ""

    {_, 0} =
      System.cmd(
        "bash",
        [Path.join(@core, "acceptance_fast_timing.sh"), "test", "test -f _build/test/build.bin"],
        cd: tmp,
        env: [{"ACCEPTANCE_FAST_TIMING_PATH", timing}],
        stderr_to_stdout: true
      )

    timing = File.read!(timing)
    assert timing =~ "acceptance_fast_setup_elapsed_seconds="
    assert timing =~ ~r/acceptance_fast_setup_workspace_before_kb=\d+/
    assert timing =~ ~r/acceptance_fast_setup_workspace_peak_kb=[1-9]\d*/
    assert timing =~ "acceptance_fast_test_elapsed_seconds="
    assert timing =~ ~r/acceptance_fast_test_workspace_before_kb=[1-9]\d*/
    assert timing =~ ~r/acceptance_fast_test_workspace_peak_kb=[1-9]\d*/
    assert timing =~ "acceptance_fast_test_exit_code=0"
  end

  # The audit shipped without the two .exs files it runs, and failed in CI at
  # the step that needed them. A hand-maintained list cannot catch that, so the
  # references are read out of the scripts themselves.
  test "every sibling a script runs is shipped alongside it" do
    for script <- @shell_scripts, sibling <- siblings_referenced(script) do
      assert File.exists?(Path.join(@core, sibling)),
             "#{script} runs #{sibling}, which is not in priv/core"
    end
  end

  test "the audit's collection and reporting steps are among those references" do
    referenced = siblings_referenced("exunit_test_value_audit.sh")

    assert "exunit_test_value_collect.exs" in referenced
    assert "exunit_test_value_report.exs" in referenced
  end

  # A tag the audit cannot run aborts the whole collection. Punnles' browser
  # tests need a Playwright bridge the audit job does not start, which silently
  # broke the full audit; excluding by tag is what keeps it auditing every other
  # module instead of being shrunk to a handful.
  test "the audit passes excluded tags through to the collector" do
    audit = File.read!(Path.join(@core, "exunit_test_value_audit.sh"))
    collect = File.read!(Path.join(@core, "exunit_test_value_collect.exs"))

    assert audit =~ "EXUNIT_TEST_VALUE_AUDIT_EXCLUDE_TAGS"
    assert audit =~ ~s("$exclude_tags")
    assert collect =~ "exclude_tags_text"
    assert collect =~ "configure_excluded_tags"
  end

  test "the collector still accepts the three-argument call it shipped with" do
    collect = File.read!(Path.join(@core, "exunit_test_value_collect.exs"))

    assert collect =~ ~r/def run\(\[output_dir, max_files_text, include_slow_text\]\)/
  end

  defp siblings_referenced(script) do
    body = File.read!(Path.join(@core, script))

    ~r/(?:\$script_dir|\$\(dirname "\$\{BASH_SOURCE\[0\]\}"\))\/([A-Za-z0-9_.-]+)/
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(&hd/1)
    |> Enum.uniq()
  end
end
