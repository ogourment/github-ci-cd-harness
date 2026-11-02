defmodule CiCdHarness.ThumbnailCacheTest do
  use ExUnit.Case, async: true

  @script Path.expand("../priv/core/atdd_generate_thumbnails.sh", __DIR__)

  test "content reuse survives renamed evidence and rejects changed or damaged entries" do
    root = Path.join(System.tmp_dir!(), "thumbnail-cache-#{System.unique_integer([:positive])}")
    shots = Path.join(root, "evidence/screenshots")
    cache = Path.join(root, "cache")
    File.mkdir_p!(shots)
    on_exit(fn -> File.rm_rf!(root) end)

    converter = Path.join(root, "converter")
    version = Path.join(root, "version")
    File.write!(version, "renderer-one")

    File.write!(converter, """
    #!/usr/bin/env bash
    set -eu
    if [[ "$1" == -version ]]; then cat "$TEST_RENDERER_VERSION"; exit; fi
    cat "$1" > "${@: -1}"
    """)

    File.chmod!(converter, 0o755)
    File.write!(Path.join(shots, "first.png"), "first pixels")
    File.write!(Path.join(shots, "alias.png"), "first pixels")

    run = fn ->
      {out, 0} =
        System.cmd("bash", [@script, Path.join(root, "evidence")],
          env: [
            {"ATDD_THUMBNAIL_CONVERTER", converter},
            {"ATDD_THUMBNAIL_CACHE_DIR", cache},
            {"TEST_RENDERER_VERSION", version}
          ],
          stderr_to_stdout: true
        )

      out
    end

    assert run.() =~ "count=2 rendered=1 cache_hits=1"
    File.rename!(Path.join(shots, "first.png"), Path.join(shots, "renamed.png"))
    assert run.() =~ "count=2 rendered=0 cache_hits=2"
    assert File.read!(Path.join(root, "evidence/thumbnails/renamed.webp")) == "first pixels"

    File.write!(Path.join(shots, "renamed.png"), "changed pixels")
    assert run.() =~ "count=2 rendered=1 cache_hits=1"
    assert File.read!(Path.join(root, "evidence/thumbnails/renamed.webp")) == "changed pixels"

    for entry <- Path.wildcard(Path.join(cache, "*/*.webp")), do: File.write!(entry, "damaged")
    assert run.() =~ "count=2 rendered=2 cache_hits=0"
    assert File.read!(Path.join(root, "evidence/thumbnails/renamed.webp")) == "changed pixels"

    File.write!(version, "renderer-two")
    assert run.() =~ "count=2 rendered=2 cache_hits=0"
    assert run.() =~ "count=2 rendered=0 cache_hits=2"
  end
end
