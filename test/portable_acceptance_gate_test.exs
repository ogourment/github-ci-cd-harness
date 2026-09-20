defmodule CiCdHarness.PortableAcceptanceGateTest do
  use ExUnit.Case, async: true

  test "the gate executes retained results without Mix and preserves a failed result" do
    template = File.read!(Path.expand("../templates/gitlab/acceptance.yml", __DIR__))
    [_, gate] = String.split(template, "\nacceptance_gate:\n", parts: 2)
    [_, script] = String.split(gate, "  script:\n    - |\n", parts: 2)
    script = script |> String.split("  # The notifier", parts: 2) |> hd()
    script = Regex.replace(~r/^      /m, script, "")
    root = Path.join(System.tmp_dir!(), "portable-gate-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    File.write!(Path.join(root, "status.env"), "ATDD_TEST_EXIT_CODE=0\n")
    File.write!(Path.join(root, "e2e.md"), "retained report\n")
    # A retained reader's exact exit code is authoritative; a nonzero result
    # must not fall back to Mix, which could hide a failure or compile again.
    for exit_code <- [0, 17] do
      File.write!(
        Path.join(root, "acceptance_gate.py"),
        "import pathlib,sys\nassert pathlib.Path(sys.argv[1]).read_text() == 'ATDD_TEST_EXIT_CODE=0\\n'\nassert pathlib.Path(sys.argv[2]).read_text() == 'retained report\\n'\nraise SystemExit(#{exit_code})\n"
      )

      {_, actual} =
        System.cmd("bash", ["-c", script],
          env: [{"ACCEPTANCE_EVIDENCE_DIR", root}],
          stderr_to_stdout: true
        )

      assert actual == exit_code
    end
  end
end
