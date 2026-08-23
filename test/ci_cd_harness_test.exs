defmodule CiCdHarnessTest do
  use ExUnit.Case, async: false

  @forge_vars ~w(GITHUB_RUN_ID GITHUB_SHA GITHUB_SERVER_URL GITHUB_REPOSITORY
                 GITHUB_REF_NAME CI_PIPELINE_ID CI_COMMIT_SHA CI_PIPELINE_URL
                 CI_COMMIT_REF_NAME)

  setup do
    saved = Map.new(@forge_vars, &{&1, System.get_env(&1)})
    Enum.each(@forge_vars, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)

    :ok
  end

  test "the source tree uses only the canonical package name" do
    legacy_name = Enum.join(["gitlab", "ci", "cd", "harness"], "-")

    {matches, status} = System.cmd("git", ["grep", "-n", legacy_name])

    assert status == 1, matches
    assert matches == ""
  end

  defp forgejo_env do
    System.put_env(%{
      "GITHUB_RUN_ID" => "4242",
      "GITHUB_SHA" => "abcdef1234567890abcdef1234567890abcdef12",
      "GITHUB_SERVER_URL" => "https://git.agile-u.com",
      "GITHUB_REPOSITORY" => "olivierg/punnles",
      "GITHUB_REF_NAME" => "main"
    })
  end

  describe "forge/0" do
    test "detects Forgejo from its GitHub-compatible variables" do
      forgejo_env()
      assert CiCdHarness.forge() == :forgejo
    end

    test "detects GitLab" do
      System.put_env("CI_PIPELINE_ID", "99")
      assert CiCdHarness.forge() == :gitlab
    end

    test "is unknown outside CI" do
      assert CiCdHarness.forge() == :unknown
    end
  end

  describe "release_id/3" do
    test "combines version, short sha and run id" do
      forgejo_env()
      assert CiCdHarness.release_id("0.3.7") == "v0.3.7-abcdef12-4242"
    end

    test "is stable for the same inputs" do
      forgejo_env()
      assert CiCdHarness.release_id("1.0.0") == CiCdHarness.release_id("1.0.0")
    end

    test "falls back to local outside CI" do
      assert CiCdHarness.release_id("1.0.0", "abcdef1234", nil) == "v1.0.0-abcdef12-local"
    end
  end

  describe "run_url/0" do
    test "builds the Forgejo run URL" do
      forgejo_env()

      assert CiCdHarness.run_url() ==
               "https://git.agile-u.com/olivierg/punnles/actions/runs/4242"
    end

    test "is nil when the forge is unknown" do
      refute CiCdHarness.run_url()
    end
  end

  describe "normalized_env/0" do
    test "maps Forgejo variables onto the CI_* names the deploy shell expects" do
      forgejo_env()
      env = Map.new(CiCdHarness.normalized_env())

      assert env["CI_COMMIT_SHA"] == "abcdef1234567890abcdef1234567890abcdef12"
      assert env["CI_COMMIT_SHORT_SHA"] == "abcdef12"
      assert env["CI_COMMIT_REF_NAME"] == "main"
      assert env["CI_PIPELINE_ID"] == "4242"
      assert env["CI_PIPELINE_URL"] =~ "/actions/runs/4242"
    end

    test "omits keys it cannot resolve rather than emitting empty values" do
      env = Map.new(CiCdHarness.normalized_env())
      refute Map.has_key?(env, "CI_PIPELINE_ID")
      refute Map.has_key?(env, "CI_PIPELINE_URL")
    end
  end
end
