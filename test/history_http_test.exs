defmodule CiCdHarness.HistoryHTTPTest do
  use ExUnit.Case, async: true

  test "optional historical transport is bounded and credentials stay private" do
    {output, status} =
      System.cmd("python3", ["test/history_http_test.py"], stderr_to_stdout: true)

    assert status == 0, output
  end
end
