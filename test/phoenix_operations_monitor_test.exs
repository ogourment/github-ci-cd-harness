defmodule CiCdHarness.PhoenixOperationsMonitorTest do
  use ExUnit.Case, async: true

  test "independent probes, alert transitions and safe release pruning" do
    {output, status} = System.cmd("python3", ["-m", "unittest", "discover", "-s", "test", "-p", "phoenix_operations_monitor_test.py"], stderr_to_stdout: true)
    assert status == 0, output
  end
end
