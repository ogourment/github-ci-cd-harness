defmodule CiCdHarness.PackagedAcceptanceTest do
  use ExUnit.Case, async: true

  test "workflow packages the exact run and screenshot into the archived OTP app" do
    workflow = File.read!(".github/workflows/phoenix.yml")

    [_, block] =
      String.split(
        workflow,
        "      - name: Package verified acceptance evidence with the exact release",
        parts: 2
      )

    [script | _] =
      block
      |> String.split("        run: |\n", parts: 2)
      |> List.last()
      |> String.split("      - name:", parts: 2)

    script =
      script
      |> String.split("\n")
      |> Enum.map_join("\n", &String.replace_prefix(&1, "          ", ""))

    root = Path.join(System.tmp_dir!(), "harness-package-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "tmp/atdd/screenshots"))
    File.mkdir_p!(Path.join(root, "_build/prod/rel/demo/lib/demo-1.2.3/priv"))
    File.mkdir_p!(Path.join(root, "bin"))
    File.write!(Path.join(root, "_build/VERSION"), "1.2.3\n")
    File.write!(Path.join(root, "tmp/atdd/evidence.json"), "{\"run\":{\"id\":\"current-run\"}}")
    File.write!(Path.join(root, "tmp/atdd/screenshots/step.png"), "actual pixels")
    File.write!(Path.join(root, "bin/mix"), "#!/bin/sh\nprintf demo")
    File.chmod!(Path.join(root, "bin/mix"), 0o755)
    on_exit(fn -> File.rm_rf!(root) end)

    {output, 0} =
      System.cmd("bash", ["-c", script],
        cd: root,
        env: [{"PATH", Path.join(root, "bin") <> ":" <> System.get_env("PATH")}],
        stderr_to_stdout: true
      )

    assert output == ""
    destination = Path.join(root, "_build/prod/rel/demo/lib/demo-1.2.3/priv/acceptance_evidence")
    assert File.read!(Path.join(destination, "screenshots/step.png")) == "actual pixels"
    assert File.read!(Path.join(destination, "evidence.json")) =~ "current-run"
    File.rm!(Path.join(root, "tmp/atdd/evidence.json"))
    {_, status} = System.cmd("bash", ["-c", script], cd: root, stderr_to_stdout: true)
    assert status != 0
  end
end
