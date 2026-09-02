defmodule MixWorkspaceOps.HexCacheTest do
  use MixWorkspaceOps.WorkspaceCase, async: true

  alias MixWorkspaceOps.HexCache

  test "one exact object is fetched once and reused by warm context views", context do
    root = temporary_directory!(context)
    state = Path.join(root, "state")
    lockfile = lockfile!(root, "sample", "1.2.3", "exact bytes")
    calls = :atomics.new(1, [])

    fetch = fn _object, path ->
      :atomics.add(calls, 1, 1)
      File.write(path, "exact bytes")
    end

    assert {:ok, [%{network: true, object_status: :fetched}]} =
             HexCache.prepare(state, Path.join(root, "context-a"), lockfile, fetch: fetch)

    assert {:ok, [%{network: false, object_status: :hit}]} =
             HexCache.prepare(state, Path.join(root, "context-b"), lockfile, fetch: fetch)

    assert :atomics.get(calls, 1) == 1
  end

  test "a corrupt retained object is quarantined and fetched again", context do
    root = temporary_directory!(context)
    state = Path.join(root, "state")
    lockfile = lockfile!(root, "sample", "1.2.3", "exact bytes")
    calls = :atomics.new(1, [])

    fetch = fn _object, path ->
      :atomics.add(calls, 1, 1)
      File.write(path, "exact bytes")
    end

    assert {:ok, [%{object: object}]} =
             HexCache.prepare(state, Path.join(root, "context-a"), lockfile, fetch: fetch)

    File.chmod!(object, 0o600)
    File.write!(object, "corrupt")

    assert {:ok, [%{object_status: :fetched}]} =
             HexCache.prepare(state, Path.join(root, "context-b"), lockfile, fetch: fetch)

    assert :atomics.get(calls, 1) == 2
    assert [_quarantined] = Path.wildcard(object <> ".corrupt.*")
  end

  test "same package version with different checksums coexists without ambiguity", context do
    root = temporary_directory!(context)
    state = Path.join(root, "state")
    lock_a = lockfile!(Path.join(root, "a"), "sample", "1.2.3", "first publication")
    lock_b = lockfile!(Path.join(root, "b"), "sample", "1.2.3", "replacement publication")
    calls = :atomics.new(1, [])

    fetch = fn object, path ->
      :atomics.add(calls, 1, 1)

      bytes =
        if object.checksum == checksum("first publication"),
          do: "first publication",
          else: "replacement publication"

      File.write(path, bytes)
    end

    cache_a = Path.join(root, "context-a")
    cache_b = Path.join(root, "context-b")
    assert {:ok, [report_a]} = HexCache.prepare(state, cache_a, lock_a, fetch: fetch)
    assert {:ok, [report_b]} = HexCache.prepare(state, cache_b, lock_b, fetch: fetch)

    refute report_a.object == report_b.object

    assert File.read!(Path.join([cache_a, "packages", "hexpm", "sample-1.2.3.tar"])) ==
             "first publication"

    assert File.read!(Path.join([cache_b, "packages", "hexpm", "sample-1.2.3.tar"])) ==
             "replacement publication"

    assert {:ok, [%{network: false}]} = HexCache.prepare(state, cache_a, lock_a, fetch: fetch)
    assert {:ok, [%{network: false}]} = HexCache.prepare(state, cache_b, lock_b, fetch: fetch)
    assert :atomics.get(calls, 1) == 2
  end

  test "unrelated exact objects prepare concurrently", context do
    root = temporary_directory!(context)
    state = Path.join(root, "state")
    lock_a = lockfile!(Path.join(root, "a"), "package_a", "1.0.0", "package a")
    lock_b = lockfile!(Path.join(root, "b"), "package_b", "1.0.0", "package b")
    parent = self()

    fetch = fn object, path ->
      send(parent, {:fetch_entered, object.package, self()})

      receive do
        :continue -> File.write(path, "package " <> String.last(object.package))
      after
        1_000 -> {:error, :test_timeout}
      end
    end

    first =
      Task.async(fn ->
        HexCache.prepare(state, Path.join(root, "context-a"), lock_a, fetch: fetch)
      end)

    second =
      Task.async(fn ->
        HexCache.prepare(state, Path.join(root, "context-b"), lock_b, fetch: fetch)
      end)

    assert_receive {:fetch_entered, "package_a", first_fetch}, 1_000
    assert_receive {:fetch_entered, "package_b", second_fetch}, 1_000
    send(first_fetch, :continue)
    send(second_fetch, :continue)

    assert {:ok, [_]} = Task.await(first, 1_000)
    assert {:ok, [_]} = Task.await(second, 1_000)
  end

  defp lockfile!(root, package, version, bytes) do
    File.mkdir_p!(root)
    path = Path.join(root, "mix.lock")
    app = String.to_atom(package)
    entry = {:hex, app, version, "inner", [:mix], [], "hexpm", checksum(bytes)}
    File.write!(path, inspect(%{app => entry}))
    path
  end

  defp checksum(bytes),
    do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
