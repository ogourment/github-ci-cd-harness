defmodule CiCdHarness.ApplicationLifecycleTest do
  use ExUnit.Case, async: true

  @script Path.expand(
            "../priv/ansible/roles/phoenix_blue_green/files/application_lifecycle.sh",
            __DIR__
          )

  setup do
    root =
      Path.join(System.tmp_dir!(), "application-lifecycle-#{System.unique_integer([:positive])}")

    bin = Path.join(root, "bin")
    config = Path.join(root, "curl.conf")
    response = Path.join(root, "response.json")
    calls = Path.join(root, "calls")
    File.mkdir_p!(bin)
    File.write!(config, ~s(header = "Authorization: Bearer not-logged-secret"\n))
    File.write!(response, ~s({"state":"draining","safe_to_stop":true}\n))

    File.write!(Path.join(bin, "curl"), """
    #!/usr/bin/env bash
    set -euo pipefail
    printf '%s\n' "$*" >> "${LIFECYCLE_CALLS}"
    if [[ "$*" == *"--request POST"* ]]; then
      printf '{"accepted":true}\n'
    else
      cat "${LIFECYCLE_RESPONSE}"
    fi
    """)

    File.chmod!(Path.join(bin, "curl"), 0o755)
    on_exit(fn -> File.rm_rf!(root) end)

    %{root: root, bin: bin, config: config, response: response, calls: calls}
  end

  test "posts with a curl config and never puts its credential in command arguments", context do
    assert {~s({"accepted":true}\n), 0} =
             run(context, ["post", context.config, "http://old/drain"])

    calls = File.read!(context.calls)
    assert calls =~ "--config #{context.config}"
    assert calls =~ "--request POST http://old/drain"
    refute calls =~ "not-logged-secret"
  end

  test "waits for explicit safe and active application states", context do
    assert {_body, 0} =
             run(context, ["wait-safe", context.config, "http://old/lifecycle", "1", "0"])

    File.write!(context.response, ~s({"state":"active","claim_new_work":true}\n))

    assert {_body, 0} =
             run(context, ["wait-active", context.config, "http://new/lifecycle", "1", "0"])
  end

  test "fails the bounded wait instead of treating an unsafe slot as drained", context do
    File.write!(context.response, ~s({"state":"draining","safe_to_stop":false}\n))

    assert {output, 75} =
             run(context, ["wait-safe", context.config, "http://old/lifecycle", "0", "0"])

    assert output =~ "application lifecycle wait-safe timed out"
  end

  defp run(context, args) do
    System.cmd("bash", [@script | args],
      env: [
        {"PATH", context.bin <> ":" <> System.get_env("PATH")},
        {"LIFECYCLE_CALLS", context.calls},
        {"LIFECYCLE_RESPONSE", context.response}
      ],
      stderr_to_stdout: true
    )
  end
end
