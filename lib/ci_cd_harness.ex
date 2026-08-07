defmodule CiCdHarness do
  @moduledoc """
  Provider-neutral delivery helpers shared by Elixir applications.

  The forge-specific surface is deliberately thin. A forge adapter answers three
  questions — what commit is this, what run is this, and where do its artifacts
  live — and everything downstream (release construction, transfer, blue/green
  deployment, health verification, tagging) is written once against the
  normalized answers.
  """

  @type forge :: :forgejo | :gitlab | :unknown

  @doc """
  Detects the forge from the environment.

  Forgejo Actions exports the GitHub-compatible variables; GitLab CI exports its
  own. Neither is present when running locally.
  """
  @spec forge() :: forge()
  def forge do
    cond do
      env("GITHUB_RUN_ID") -> :forgejo
      env("CI_PIPELINE_ID") -> :gitlab
      true -> :unknown
    end
  end

  @doc """
  The commit being delivered.
  """
  @spec commit_sha() :: String.t() | nil
  def commit_sha do
    case forge() do
      :forgejo -> env("GITHUB_SHA")
      :gitlab -> env("CI_COMMIT_SHA")
      :unknown -> git_head()
    end
  end

  @doc """
  The provider run identity, used to make release IDs unique and traceable back
  to the run that produced them.
  """
  @spec run_id() :: String.t() | nil
  def run_id do
    case forge() do
      :forgejo -> env("GITHUB_RUN_ID")
      :gitlab -> env("CI_PIPELINE_ID")
      :unknown -> "local"
    end
  end

  @doc """
  The URL of the current run, recorded in deployment identity.
  """
  @spec run_url() :: String.t() | nil
  def run_url do
    case forge() do
      :forgejo ->
        with server when is_binary(server) <- env("GITHUB_SERVER_URL"),
             repo when is_binary(repo) <- env("GITHUB_REPOSITORY"),
             id when is_binary(id) <- env("GITHUB_RUN_ID") do
          "#{server}/#{repo}/actions/runs/#{id}"
        else
          _ -> nil
        end

      :gitlab ->
        env("CI_PIPELINE_URL")

      :unknown ->
        nil
    end
  end

  @doc """
  Release identity: `v<version>-<short sha>-<run id>`.

  Stable across the build, deploy and verify steps so an artifact can always be
  traced to the run and commit that produced it.
  """
  @spec release_id(String.t(), String.t() | nil, String.t() | nil) :: String.t()
  def release_id(version, sha \\ nil, run \\ nil) do
    sha = sha || commit_sha() || "unknown"
    run = run || run_id() || "local"
    "v#{version}-#{short_sha(sha)}-#{run}"
  end

  @doc """
  First eight characters of a commit SHA.
  """
  @spec short_sha(String.t()) :: String.t()
  def short_sha(sha) when is_binary(sha), do: String.slice(sha, 0, 8)

  @doc """
  Normalized environment for scripts that still speak GitLab's `CI_*` names.

  This is the adapter seam: it lets the provider-neutral shell in the existing
  harness run unchanged under Forgejo instead of being reimplemented.
  """
  @spec normalized_env() :: [{String.t(), String.t()}]
  def normalized_env, do: normalized_env(forge())

  # Outside CI there is nothing to adapt. Emitting a fabricated pipeline
  # identity here would put "local" into deployment identity and release
  # metadata, so return nothing instead.
  defp normalized_env(:unknown), do: []

  defp normalized_env(_forge) do
    sha = commit_sha()

    [
      {"CI_COMMIT_SHA", sha},
      {"CI_COMMIT_SHORT_SHA", sha && short_sha(sha)},
      {"CI_COMMIT_REF_NAME", ref_name()},
      {"CI_PIPELINE_ID", run_id()},
      {"CI_PIPELINE_URL", run_url()},
      {"CI_JOB_URL", run_url()}
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp ref_name do
    case forge() do
      :forgejo -> env("GITHUB_REF_NAME")
      :gitlab -> env("CI_COMMIT_REF_NAME")
      :unknown -> nil
    end
  end

  defp git_head do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  end

  defp env(name) do
    case System.get_env(name) do
      nil -> nil
      "" -> nil
      value -> value
    end
  end
end
