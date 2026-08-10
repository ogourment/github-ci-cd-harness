#!/usr/bin/env elixir

defmodule ExUnitTestValueReport do
  @moduledoc false

  def run([signature_dir, output_dir, threshold_text | options]) do
    threshold = parse_threshold!(threshold_text)
    {collection, minimum_overlap_points} = parse_options!(options)
    modules = load_signatures!(signature_dir)

    if modules == [] do
      abort!("No .signature files found in #{signature_dir}")
    end

    modules = add_unique_points(modules)
    overlaps = calculate_overlaps(modules)

    likely_redundant =
      Enum.filter(
        overlaps,
        &(&1.jaccard >= threshold && &1.intersection >= minimum_overlap_points)
      )

    File.mkdir_p!(output_dir)
    write_modules_tsv!(output_dir, modules)
    write_overlaps_tsv!(output_dir, overlaps)

    write_json!(
      output_dir,
      threshold,
      minimum_overlap_points,
      collection,
      modules,
      likely_redundant
    )

    write_markdown!(
      output_dir,
      threshold,
      minimum_overlap_points,
      collection,
      modules,
      likely_redundant
    )
  end

  def run(_) do
    abort!(
      "Usage: exunit_test_value_report.exs SIGNATURE_DIR OUTPUT_DIR OVERLAP_THRESHOLD [COLLECTION_TSV] [MINIMUM_OVERLAP_POINTS]"
    )
  end

  defp parse_options!([]), do: {nil, 1}
  defp parse_options!([minimum]), do: {nil, parse_positive_integer!(minimum, "arguments")}

  defp parse_options!([path, minimum]) do
    {load_collection!(path), parse_positive_integer!(minimum, "arguments")}
  end

  defp parse_options!(_), do: abort!("Too many collection report arguments")

  defp load_collection!(path) do
    values =
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Map.new(fn line ->
        case String.split(line, "\t", parts: 2) do
          [key, value] -> {key, value}
          _ -> abort!("Invalid collection metric in #{path}: #{line}")
        end
      end)

    %{
      strategy: Map.fetch!(values, "collector_strategy"),
      setup_and_instrumentation_ms:
        parse_runtime!(Map.fetch!(values, "setup_and_instrumentation_ms"), path),
      collection_total_ms: parse_runtime!(Map.fetch!(values, "collection_total_ms"), path),
      test_file_count: parse_integer!(Map.fetch!(values, "test_file_count"), path)
    }
  end

  defp parse_integer!(text, path) do
    case Integer.parse(text) do
      {value, ""} when value >= 0 -> value
      _ -> abort!("Invalid integer in #{path}: #{text}")
    end
  end

  defp parse_positive_integer!(text, path) do
    case Integer.parse(text) do
      {value, ""} when value > 0 -> value
      _ -> abort!("Invalid positive integer in #{path}: #{text}")
    end
  end

  defp parse_threshold!(text) do
    case Float.parse(text) do
      {value, ""} when value >= 0.0 and value <= 1.0 -> value
      _ -> abort!("Overlap threshold must be a number between 0 and 1")
    end
  end

  defp load_signatures!(signature_dir) do
    signature_dir
    |> Path.join("*.signature")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&load_signature!/1)
    |> Enum.sort_by(& &1.test_file)
  end

  defp load_signature!(path) do
    case File.read!(path) |> String.split("\n", trim: true) do
      [metadata | point_lines] ->
        {test_file, total_runtime_ms, test_execution_ms} = parse_metadata!(metadata, path)

        points =
          point_lines
          |> Enum.reject(&String.starts_with?(&1, "#"))
          |> MapSet.new()

        %{
          test_file: test_file,
          total_runtime_ms: total_runtime_ms,
          test_execution_ms: test_execution_ms,
          setup_and_coverage_ms: max(total_runtime_ms - test_execution_ms, 0.0),
          points: points,
          unique_points: 0
        }

      [] ->
        abort!("Empty signature file: #{path}")
    end
  end

  defp parse_metadata!(metadata, path) do
    case String.split(metadata, "\t") do
      [test_file, total_runtime_text, test_execution_text] ->
        total_runtime_ms = parse_runtime!(total_runtime_text, path)
        test_execution_ms = parse_runtime!(test_execution_text, path)
        {test_file, total_runtime_ms, test_execution_ms}

      _ ->
        abort!(
          "Expected TEST_FILE<TAB>TOTAL_RUNTIME_MS<TAB>TEST_EXECUTION_MS metadata in #{path}"
        )
    end
  end

  defp parse_runtime!(text, path) do
    case Float.parse(text) do
      {runtime_ms, ""} when runtime_ms >= 0.0 -> runtime_ms
      _ -> abort!("Invalid runtime in #{path}: #{text}")
    end
  end

  defp add_unique_points(modules) do
    Enum.map(modules, fn module ->
      other_points =
        modules
        |> Enum.reject(&(&1.test_file == module.test_file))
        |> Enum.reduce(MapSet.new(), fn other, points ->
          MapSet.union(points, other.points)
        end)

      %{module | unique_points: MapSet.difference(module.points, other_points) |> MapSet.size()}
    end)
  end

  defp calculate_overlaps(modules) do
    modules
    |> Enum.with_index()
    |> Enum.flat_map(fn {left, index} ->
      modules
      |> Enum.drop(index + 1)
      |> Enum.map(&overlap(left, &1))
    end)
    |> Enum.sort_by(fn pair -> {-pair.jaccard, pair.left, pair.right} end)
  end

  defp overlap(left, right) do
    intersection = MapSet.intersection(left.points, right.points) |> MapSet.size()
    union = MapSet.union(left.points, right.points) |> MapSet.size()
    jaccard = if union == 0, do: 0.0, else: intersection / union

    %{
      left: left.test_file,
      right: right.test_file,
      jaccard: jaccard,
      intersection: intersection,
      left_points: MapSet.size(left.points),
      right_points: MapSet.size(right.points)
    }
  end

  defp write_modules_tsv!(output_dir, modules) do
    rows =
      Enum.map(modules, fn module ->
        [
          module.test_file,
          format_runtime(module.total_runtime_ms),
          format_runtime(module.test_execution_ms),
          format_runtime(module.setup_and_coverage_ms),
          MapSet.size(module.points),
          module.unique_points
        ]
        |> Enum.join("\t")
      end)

    write_lines!(Path.join(output_dir, "modules.tsv"), [
      "test_file\ttotal_runtime_ms\ttest_execution_ms\tsetup_and_coverage_ms\tcovered_points\tunique_points"
      | rows
    ])
  end

  defp write_overlaps_tsv!(output_dir, overlaps) do
    rows =
      Enum.map(overlaps, fn pair ->
        [
          pair.left,
          pair.right,
          :erlang.float_to_binary(pair.jaccard, decimals: 6),
          pair.intersection,
          pair.left_points,
          pair.right_points
        ]
        |> Enum.join("\t")
      end)

    write_lines!(Path.join(output_dir, "overlaps.tsv"), [
      "left\tright\tjaccard\tintersection\tleft_points\tright_points" | rows
    ])
  end

  defp write_json!(
         output_dir,
         threshold,
         minimum_overlap_points,
         collection,
         modules,
         likely_redundant
       ) do
    module_json =
      modules
      |> Enum.map(fn module ->
        """
        {"test_file":#{json_string(module.test_file)},"total_runtime_ms":#{json_number(module.total_runtime_ms)},"test_execution_ms":#{json_number(module.test_execution_ms)},"setup_and_coverage_ms":#{json_number(module.setup_and_coverage_ms)},"covered_points":#{MapSet.size(module.points)},"unique_points":#{module.unique_points}}
        """
        |> String.trim()
      end)
      |> Enum.join(",")

    overlap_json =
      likely_redundant
      |> Enum.map(fn pair ->
        """
        {"left":#{json_string(pair.left)},"right":#{json_string(pair.right)},"jaccard":#{json_number(pair.jaccard)},"intersection":#{pair.intersection}}
        """
        |> String.trim()
      end)
      |> Enum.join(",")

    collection_json =
      case collection do
        nil ->
          "null"

        metrics ->
          """
          {"strategy":#{json_string(metrics.strategy)},"setup_and_instrumentation_ms":#{json_number(metrics.setup_and_instrumentation_ms)},"collection_total_ms":#{json_number(metrics.collection_total_ms)},"test_file_count":#{metrics.test_file_count}}
          """
          |> String.trim()
      end

    json =
      """
      {"schema_version":2,"collection":#{collection_json},"overlap_threshold":#{json_number(threshold)},"minimum_overlap_points":#{minimum_overlap_points},"modules":[#{module_json}],"likely_redundant_pairs":[#{overlap_json}]}
      """
      |> String.trim()

    File.write!(Path.join(output_dir, "report.json"), json <> "\n")
  end

  defp write_markdown!(
         output_dir,
         threshold,
         minimum_overlap_points,
         collection,
         modules,
         likely_redundant
       ) do
    total_runtime = Enum.reduce(modules, 0.0, &(&1.total_runtime_ms + &2))
    total_test_execution = Enum.reduce(modules, 0.0, &(&1.test_execution_ms + &2))
    total_setup_and_coverage = Enum.reduce(modules, 0.0, &(&1.setup_and_coverage_ms + &2))
    no_unique = Enum.count(modules, &(&1.unique_points == 0))

    module_rows =
      Enum.map(modules, fn module ->
        "| `#{module.test_file}` | #{format_runtime(module.total_runtime_ms)} | #{format_runtime(module.test_execution_ms)} | #{format_runtime(module.setup_and_coverage_ms)} | #{MapSet.size(module.points)} | #{module.unique_points} |"
      end)

    overlap_rows =
      case likely_redundant do
        [] ->
          ["No pairs met the configured overlap threshold."]

        pairs ->
          [
            "| Left | Right | Jaccard overlap |",
            "|---|---|---:|"
            | Enum.map(pairs, fn pair ->
                "| `#{pair.left}` | `#{pair.right}` | #{format_percent(pair.jaccard)} |"
              end)
          ]
      end

    collection_lines =
      case collection do
        nil ->
          []

        metrics ->
          [
            "- Collector strategy: #{metrics.strategy}",
            "- One-time setup and instrumentation: #{format_runtime(metrics.setup_and_instrumentation_ms)} ms",
            "- End-to-end collection: #{format_runtime(metrics.collection_total_ms)} ms"
          ]
      end

    lines =
      [
        "# ExUnit test-value audit",
        "",
        "This report identifies execution overlap. It does not prove that an overlapping test is redundant.",
        "",
        "- Test modules: #{length(modules)}"
      ] ++
        collection_lines ++
        [
          "- Summed per-file audit runtime: #{format_runtime(total_runtime)} ms",
          "- ExUnit-reported execution: #{format_runtime(total_test_execution)} ms",
          "- Setup and coverage overhead: #{format_runtime(total_setup_and_coverage)} ms",
          "- Modules with no unique covered points: #{no_unique}",
          "- Overlap threshold: #{format_percent(threshold)}",
          "- Minimum shared covered points: #{minimum_overlap_points}",
          "- Likely redundant pairs: #{length(likely_redundant)}",
          "",
          "## Module evidence",
          "",
          "| Test module | Total (ms) | Test execution (ms) | Setup + coverage (ms) | Covered points | Unique points |",
          "|---|---:|---:|---:|---:|---:|"
          | module_rows
        ] ++ ["", "## High-overlap pairs", ""] ++ overlap_rows

    write_lines!(Path.join(output_dir, "report.md"), lines)
  end

  defp write_lines!(path, lines), do: File.write!(path, Enum.join(lines, "\n") <> "\n")

  defp format_runtime(value), do: :erlang.float_to_binary(value / 1, decimals: 3)
  defp format_percent(value), do: :erlang.float_to_binary(value * 100, decimals: 1) <> "%"

  defp json_number(value) when is_float(value) do
    value
    |> Float.round(6)
    |> Float.to_string()
  end

  defp json_string(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")
      |> String.replace("\r", "\\r")
      |> String.replace("\t", "\\t")

    ~s("#{escaped}")
  end

  defp abort!(message) do
    IO.puts(:stderr, message)
    System.halt(2)
  end
end

ExUnitTestValueReport.run(System.argv())
