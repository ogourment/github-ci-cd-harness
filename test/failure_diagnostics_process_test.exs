defmodule CiCdHarness.FailureDiagnosticsProcessTest do
  use ExUnit.Case, async: true

  @tag :tmp_dir
  test "a killed diagnostics process runs once and the failed suite stays failed", %{tmp_dir: dir} do
    script = Path.expand("../priv/core/acceptance_evidence.sh", __DIR__)
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    mix = Path.join(bin, "mix")

    File.write!(mix, """
    #!/bin/sh
    case "$1" in
      acceptance.append_failures) echo attempted >> attempts; exit 137 ;;
      acceptance.site) exit 0 ;;
      acceptance.gate) exit 2 ;;
      *) exit 1 ;;
    esac
    """)

    File.chmod!(mix, 0o755)

    env = [
      {"PATH", bin <> ":" <> System.fetch_env!("PATH")},
      {"ACCEPTANCE_TEST_COMMAND", "echo '1 failure'; exit 2"},
      {"ACCEPTANCE_REPORT_URL", "https://example.org/index.html"},
      {"ACCEPTANCE_PORTABLE_GATE_SOURCE", Path.join(dir, "absent.py")},
      {"CI_PIPELINE_ID", "1"},
      {"CI_JOB_ID", "2"}
    ]

    {output, 0} = System.cmd("bash", [script], cd: dir, env: env, stderr_to_stdout: true)
    assert File.read!(Path.join(dir, "attempts")) == "attempted\n"
    assert File.read!(Path.join(dir, "tmp/atdd/test.log")) == "1 failure\n"
    assert output =~ "ATDD_FAILURE_DIAGNOSTICS_EXIT_CODE=137"
    assert output =~ "ATDD_TEST_EXIT_CODE=2"
    assert output =~ "ATDD_GATE_EXIT_CODE=2"
  end
end
