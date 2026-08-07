defmodule Mix.Tasks.Cd.BuildRelease do
  @shortdoc "Builds a production release archive with a traceable release identity"

  @moduledoc """
  Builds the production release and writes the identity files the deploy and
  verify steps consume.

      mix cd.build_release

  Outputs, all under `_build`:

    * `RELEASE_ID`      — `v<version>-<short sha>-<run id>`
    * `VERSION`         — the version from `mix.exs`
    * `RELEASE_ARCHIVE` — path to the tarball
    * `RELEASE_SHA256`  — checksum, verified again before deployment

  The application name comes from the consuming project, so nothing here is
  app-specific.
  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [skip_assets: :boolean])
    app = to_string(Mix.Project.config()[:app])
    version = Mix.Project.config()[:version]
    release_id = CiCdHarness.release_id(version)

    Mix.shell().info("Building #{app} #{release_id}")

    run!("mix", ["deps.get", "--only", "prod"])
    unless opts[:skip_assets], do: build_assets()
    run!("mix", ["compile"], prod_env())
    unless opts[:skip_assets], do: run!("mix", ["assets.deploy"], prod_env())
    run!("mix", ["release", "--overwrite"], prod_env())

    archive_dir = Path.join("tmp", "release")
    File.mkdir_p!(archive_dir)
    archive = Path.join(archive_dir, "#{app}-#{release_id}.tar.gz")

    run!("tar", ["-C", Path.join(["_build", "prod", "rel", app]), "-czf", archive, "."])

    File.mkdir_p!("_build")
    File.write!(Path.join("_build", "RELEASE_ID"), release_id <> "\n")
    File.write!(Path.join("_build", "VERSION"), version <> "\n")
    File.write!(Path.join("_build", "RELEASE_ARCHIVE"), archive <> "\n")
    File.write!(Path.join("_build", "RELEASE_SHA256"), checksum_line(archive))

    Mix.shell().info("Release archive: #{archive}")
  end

  defp build_assets do
    if File.dir?("assets"), do: run!("npm", ["ci", "--prefix", "assets"])
  end

  # sha256sum is not present on macOS; shasum is not always present on Debian.
  defp checksum_line(archive) do
    digest =
      archive
      |> File.stream!([], 2 ** 16)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    "#{digest}  #{Path.basename(archive)}\n"
  end

  defp prod_env, do: [{"MIX_ENV", "prod"}]

  defp run!(cmd, args, env \\ []) do
    case System.cmd(cmd, args, into: IO.stream(:stdio, :line), env: env, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {_out, code} -> Mix.raise("#{cmd} #{Enum.join(args, " ")} failed with exit #{code}")
    end
  end
end
