defmodule CiCdHarness.MixProject do
  use Mix.Project

  @version "0.4.24"

  def project do
    [
      app: :ci_cd_harness,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Provider-neutral CI/CD delivery for Elixir applications",
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps, do: []
end
