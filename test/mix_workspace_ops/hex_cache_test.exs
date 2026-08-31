defmodule MixWorkspaceOps.HexCacheTest do
  use MixWorkspaceOps.WorkspaceCase, async: true

  alias MixWorkspaceOps.HexCache

  test "retains two checksums for one package version and selects the exact object", context do
    state_root = temporary_directory!(context)
    first = object("same", "1.0.0", "first archive")
    second = object("same", "1.0.0", "second archive")
    verify = fn _path, _object -> :ok end

    assert {:ok, %{status: :miss} = first_report} =
             HexCache.ensure(state_root, first, fn _ -> {:ok, "first archive"} end,
               verify: verify
             )

    assert {:ok, %{status: :hit, bytes_downloaded: 0, duration_ms: duration}} =
             HexCache.ensure(state_root, first, fn _ -> flunk("a hit must not fetch") end,
               verify: verify
             )

    assert is_integer(duration)

    assert {:ok, %{status: :miss} = second_report} =
             HexCache.ensure(state_root, second, fn _ -> {:ok, "second archive"} end,
               verify: verify
             )

    first_path = first_report.archive
    second_path = second_report.archive
    refute first_path == second_path
    assert File.read!(first_path) == "first archive"
    assert File.read!(second_path) == "second archive"
  end

  test "parallel consumers fetch one absent exact object once", context do
    state_root = temporary_directory!(context)
    object = object("parallel", "1.0.0", "one archive")
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    fetch = fn _object ->
      Agent.update(counter, &(&1 + 1))
      Process.sleep(50)
      {:ok, "one archive"}
    end

    tasks =
      for _index <- 1..8 do
        Task.async(fn ->
          HexCache.ensure(state_root, object, fetch, verify: fn _, _ -> :ok end)
        end)
      end

    reports = Enum.map(tasks, &Task.await(&1, 5_000))
    assert Enum.count(reports, &match?({:ok, %{status: :miss}}, &1)) == 1
    assert Enum.count(reports, &match?({:ok, %{status: :hit}}, &1)) == 7
    assert Agent.get(counter, & &1) == 1
  end

  test "different exact objects are not held behind one global lock", context do
    state_root = temporary_directory!(context)
    parent = self()
    one = object("one", "1.0.0", "one")
    two = object("two", "1.0.0", "two")

    fetch = fn object ->
      send(parent, {:fetching, object.package, self()})

      receive do
        :continue -> {:ok, object.package}
      after
        2_000 -> {:error, :probe_timeout}
      end
    end

    tasks =
      for object <- [one, two] do
        Task.async(fn ->
          HexCache.ensure(state_root, object, fetch, verify: fn _, _ -> :ok end)
        end)
      end

    workers =
      for _index <- 1..2 do
        assert_receive {:fetching, _package, worker}, 1_000
        worker
      end

    Enum.each(workers, &send(&1, :continue))
    assert Enum.all?(tasks, &match?({:ok, _}, Task.await(&1, 5_000)))
  end

  test "corruption is quarantined before an exact object is repaired", context do
    state_root = temporary_directory!(context)
    object = object("repair", "1.0.0", "valid")
    verify = fn _path, _object -> :ok end

    assert {:ok, first} =
             HexCache.ensure(state_root, object, fn _ -> {:ok, "valid"} end, verify: verify)

    File.write!(first.archive, "corrupt")

    assert {:ok, repaired} =
             HexCache.ensure(state_root, object, fn _ -> {:ok, "valid"} end, verify: verify)

    assert repaired.status == :repaired
    assert File.dir?(repaired.quarantine.path)
    assert File.read!(repaired.archive) == "valid"
  end

  test "an outer-checksum mismatch is refused before installation", context do
    state_root = temporary_directory!(context)
    object = object("wrong", "1.0.0", "expected")

    assert {:error, {:hex_outer_checksum, expected, actual}} =
             HexCache.ensure(state_root, object, fn _ -> {:ok, "different"} end,
               verify: fn _, _ -> :ok end
             )

    refute expected == actual
    assert Path.wildcard(Path.join(state_root, "cache/hex/objects/**/package.tar")) == []
  end

  test "a verified retained archive materializes once into an exact dependency context",
       context do
    root = temporary_directory!(context)
    package_root = Path.join(root, "package")
    state_root = Path.join(root, "state")
    deps_path = Path.join([state_root, "contexts", "deps", String.duplicate("d", 64)])
    File.mkdir_p!(package_root)
    File.write!(Path.join(package_root, "mix.exs"), "defmodule Retained.MixProject do\nend\n")
    Mix.Local.append_archives()

    tar =
      File.cd!(package_root, fn ->
        Hex.Tar.create!(
          %{name: "retained", version: "1.0.0", build_tools: ["mix"]},
          ["mix.exs"],
          :memory
        )
      end)

    canonical = %{
      repository: "hexpm",
      package: "retained",
      version: "1.0.0",
      inner_checksum: Base.encode16(tar.inner_checksum, case: :lower),
      outer_checksum: Base.encode16(tar.outer_checksum, case: :lower)
    }

    object =
      Map.merge(canonical, %{
        app: "retained",
        managers: [:mix],
        identity: canonical |> MixWorkspaceOps.Report.encode() |> digest()
      })

    assert {:ok, %{status: :miss}} =
             HexCache.ensure(state_root, object, fn _ -> {:ok, tar.tarball} end)

    stale = Path.join(deps_path, ".tmp-retained-interrupted")
    File.mkdir_p!(stale)
    File.write!(Path.join(stale, "partial"), "incomplete")

    assert {:ok, %{status: :miss, extracted: true, destination: destination}} =
             HexCache.materialize(state_root, object, deps_path)

    refute File.exists?(stale)
    assert File.read!(Path.join(destination, "mix.exs")) =~ "Retained.MixProject"
    assert File.regular?(Path.join(destination, ".hex"))

    assert {:ok, %{status: :hit, extracted: false, destination: ^destination}} =
             HexCache.materialize(state_root, object, deps_path)
  end

  test "materialization refuses an application path escape", context do
    state_root = temporary_directory!(context)
    bytes = "archive"
    object = object("retained", "1.0.0", bytes) |> Map.put(:app, "../escape")
    deps_path = Path.join([state_root, "contexts", "deps", "context"])

    assert {:error, {:hex_materialize_application, "../escape"}} =
             HexCache.materialize(state_root, object, deps_path)

    refute File.exists?(Path.join([state_root, "contexts", "deps", "escape"]))
  end

  defp object(package, version, bytes) do
    outer = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    inner = :crypto.hash(:sha256, "inner:" <> bytes) |> Base.encode16(case: :lower)

    canonical = %{
      repository: "hexpm",
      package: package,
      version: version,
      inner_checksum: inner,
      outer_checksum: outer
    }

    Map.merge(canonical, %{
      app: package,
      managers: [:mix],
      identity: canonical |> MixWorkspaceOps.Report.encode() |> digest()
    })
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
