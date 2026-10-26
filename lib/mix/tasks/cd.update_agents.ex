defmodule Mix.Tasks.Cd.UpdateAgents do
  use Mix.Task

  @shortdoc "Refresh the compact delivery guidance at adoption or upgrade"
  @start "<!-- ci-cd-harness:guidance:start -->"
  @finish "<!-- ci-cd-harness:guidance:end -->"

  @impl true
  def run(args) do
    {opts, paths, invalid} = OptionParser.parse(args, strict: [check: :boolean])

    if invalid != [] or length(paths) > 1 do
      Mix.raise("Usage: mix cd.update_agents [--check] [directory]")
    end

    path = Path.join(List.first(paths) || File.cwd!(), "AGENTS.md")
    original = if File.exists?(path), do: File.read!(path), else: ""
    updated = update(original)

    cond do
      original == updated ->
        Mix.shell().info("Delivery guidance is current")

      opts[:check] ->
        Mix.raise("Delivery guidance is stale; run mix cd.update_agents")

      true ->
        File.write!(path, updated)
        Mix.shell().info("Updated #{path}")
    end
  end

  @doc false
  def update(original) do
    block = """
    #{@start}
    Provide an application-styled 404 page with useful navigation and HTTP status 404.
    #{@finish}
    """

    starts = length(:binary.matches(original, @start))
    finishes = length(:binary.matches(original, @finish))

    case {starts, finishes} do
      {0, 0} ->
        if original == "",
          do: block,
          else: original <> if(String.ends_with?(original, "\n"), do: "\n", else: "\n\n") <> block

      {1, 1} ->
        [before, rest] = String.split(original, @start, parts: 2)
        [_, after_block] = String.split(rest, @finish, parts: 2)
        before <> String.trim_trailing(block) <> after_block

      _ ->
        Mix.raise("Ambiguous delivery-guidance markers; existing content was left unchanged")
    end
  end
end
