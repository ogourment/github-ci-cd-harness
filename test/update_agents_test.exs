defmodule CiCdHarness.UpdateAgentsTest do
  use ExUnit.Case, async: true
  alias Mix.Tasks.Cd.UpdateAgents

  test "adoption adds one compact block and subsequent upgrades are idempotent" do
    original = "# App\n\nExisting app guidance.\n"
    result = UpdateAgents.update(original)
    assert result =~ "Existing app guidance."
    assert result =~ "Provide an application-styled 404 page"
    assert result == UpdateAgents.update(result)
  end

  test "upgrade replaces only the managed block" do
    original =
      "before\n<!-- ci-cd-harness:guidance:start -->\nold\n<!-- ci-cd-harness:guidance:end -->\nafter\n"

    result = UpdateAgents.update(original)
    assert String.starts_with?(result, "before\n")
    assert String.ends_with?(result, "\nafter\n")
    refute result =~ "\nold\n"
  end

  test "ambiguous markers fail without replacing user instructions" do
    assert_raise Mix.Error, fn ->
      UpdateAgents.update("<!-- ci-cd-harness:guidance:start -->\nmanual content")
    end
  end
end
