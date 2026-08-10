#!/usr/bin/env elixir

defmodule ExUnitTestValueCollect do
  @moduledoc false

  def run([output_dir, max_files_text, include_slow_text]) do
    max_files = parse_max_files!(max_files_text)
    include_slow = parse_boolean!(include_slow_text)
    test_files = test_files!(max_files)
    collection_started = now()

    ExUnit.start(autorun: false)
    Code.require_file("test/test_helper.exs")
    ExUnit.configure(autorun: false)
    configure_slow_tests(include_slow)

    modules = start_coverage!()
    setup_finished = now()

    signatures_dir = Path.join(output_dir, "signatures")
    File.mkdir_p!(signatures_dir)

    test_files
    |> Enum.with_index(1)
    |> Enum.each(fn {test_file, index} ->
      collect_file!(test_file, index, length(test_files), signatures_dir, modules)
    end)

    collection_finished = now()

    write_collection_metrics!(output_dir, %{
      strategy: "batched",
      setup_and_instrumentation_ms: elapsed_ms(collection_started, setup_finished),
      collection_total_ms: elapsed_ms(collection_started, collection_finished),
      test_file_count: length(test_files)
    })
  after
    if Code.ensure_loaded?(:cover), do: :cover.stop()
  end

  def run(_) do
    abort!("Usage: exunit_test_value_collect.exs OUTPUT_DIR MAX_TEST_FILES INCLUDE_SLOW")
  end

  defp test_files!(max_files) do
    files =
      "test/**/*_test.exs"
      |> Path.wildcard()
      |> Enum.sort()

    if files == [], do: abort!("No ExUnit test files were found under test/.")
    if max_files == 0, do: files, else: Enum.take(files, max_files)
  end

  defp start_coverage! do
    Mix.ensure_application!(:tools)
    _ = :cover.stop()
    {:ok, _pid} = :cover.start()
    :cover.local_only()

    beams =
      Mix.Project.compile_path()
      |> Path.join("*.beam")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.map(&String.to_charlist/1)

    if beams == [], do: abort!("No project BEAM modules were available for coverage.")

    modules =
      beams
      |> :cover.compile_beam()
      |> Enum.map(fn
        {:ok, module} -> module
        {:error, reason} -> abort!("Could not instrument project BEAM: #{inspect(reason)}")
      end)

    :ok = :cover.reset()
    modules
  end

  defp collect_file!(test_file, index, total, signatures_dir, modules) do
    IO.puts("[#{index}/#{total}] Auditing #{test_file}")
    :ok = :cover.reset()
    file_started = now()
    Code.require_file(test_file)
    execution_started = now()
    result = ExUnit.run()
    execution_finished = now()

    if result.failures > 0 do
      abort!("Test file failed during value audit: #{test_file}", 1)
    end

    points =
      modules
      |> Enum.flat_map(&covered_points/1)
      |> Enum.sort()

    file_finished = now()
    signature = Path.join(signatures_dir, "#{sequence(index)}.signature")

    lines = [
      Enum.join(
        [
          test_file,
          format_ms(elapsed_ms(file_started, file_finished)),
          format_ms(elapsed_ms(execution_started, execution_finished))
        ],
        "\t"
      )
      | points
    ]

    File.write!(signature, Enum.join(lines, "\n") <> "\n")
  end

  defp covered_points(module) do
    case :cover.analyse(module, :coverage, :line) do
      {:ok, lines} ->
        for {{^module, line}, {covered, _not_covered}} <- lines,
            line > 0,
            covered > 0 do
          "#{inspect(module)}:#{line}"
        end

      {:error, _reason} ->
        []
    end
  end

  defp write_collection_metrics!(output_dir, metrics) do
    rows = [
      "collector_strategy\t#{metrics.strategy}",
      "setup_and_instrumentation_ms\t#{format_ms(metrics.setup_and_instrumentation_ms)}",
      "collection_total_ms\t#{format_ms(metrics.collection_total_ms)}",
      "test_file_count\t#{metrics.test_file_count}"
    ]

    File.write!(Path.join(output_dir, "collection.tsv"), Enum.join(rows, "\n") <> "\n")
  end

  defp configure_slow_tests(true), do: ExUnit.configure(include: [:slow])
  defp configure_slow_tests(false), do: ExUnit.configure(exclude: [:slow])

  defp parse_max_files!(text) do
    case Integer.parse(text) do
      {value, ""} when value >= 0 -> value
      _ -> abort!("MAX_TEST_FILES must be a non-negative integer")
    end
  end

  defp parse_boolean!("true"), do: true
  defp parse_boolean!("false"), do: false
  defp parse_boolean!(_), do: abort!("INCLUDE_SLOW must be true or false")

  defp now, do: System.monotonic_time()

  defp elapsed_ms(started, finished) do
    System.convert_time_unit(finished - started, :native, :microsecond) / 1_000
  end

  defp format_ms(value), do: :erlang.float_to_binary(value / 1, decimals: 3)
  defp sequence(index), do: index |> Integer.to_string() |> String.pad_leading(4, "0")

  defp abort!(message, status \\ 2) do
    IO.puts(:stderr, message)
    System.halt(status)
  end
end

ExUnitTestValueCollect.run(System.argv())
