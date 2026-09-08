defmodule MixWorkspaceOps.HexCacheTest do
  use MixWorkspaceOps.WorkspaceCase, async: true

  alias MixWorkspaceOps.HexCache

  test "one exact object is fetched once and reused by warm context views", context do
    root = temporary_directory!(context)
    state = Path.join(root, "state")
    lockfile = lockfile!(root, "sample", "1.2.3", "exact bytes")
    calls = :atomics.new(1, [])
    memo = :ets.new(__MODULE__, [:set, :public])

    fetch = fn _object, path ->
      :atomics.add(calls, 1, 1)
      File.write(path, "exact bytes")
    end

    assert {:ok, [%{network: true, object_status: :fetched}]} =
             HexCache.prepare(state, Path.join(root, "context-a"), lockfile,
               fetch: fetch,
               memo: memo
             )

    assert {:ok, [%{network: false, object_status: :hit}]} =
             HexCache.prepare(state, Path.join(root, "context-b"), lockfile,
               fetch: fetch,
               memo: memo
             )

    assert :atomics.get(calls, 1) == 1

    for context <- ~w(context-a context-b) do
      assert File.read!(Path.join([root, context, "packages", "hexpm", "sample-1.2.3.tar"])) ==
               "exact bytes"
    end
  end

  test "one failed exact object is not retried within an invocation", context do
    root = temporary_directory!(context)
    state = Path.join(root, "state")
    lockfile = lockfile!(root, "sample", "1.2.3", "exact bytes")
    calls = :atomics.new(1, [])
    memo = :ets.new(__MODULE__, [:set, :public])

    fetch = fn _object, _path ->
      :atomics.add(calls, 1, 1)
      {:error, :offline}
    end

    for cache <- ~w(context-a context-b) do
      assert {:error, {:hex_object_fetch, _object, :offline}} =
               HexCache.prepare(state, Path.join(root, cache), lockfile,
                 fetch: fetch,
                 memo: memo
               )
    end

    assert :atomics.get(calls, 1) == 1
  end

  test "a verified native archive seeds a fresh retained store without a download", context do
    root = temporary_directory!(context)
    state = Path.join(root, "state")
    native = Path.join(root, "native")
    lockfile = lockfile!(root, "sample", "1.2.3", "exact bytes")
    archive = Path.join([native, "packages", "hexpm", "sample-1.2.3.tar"])
    File.mkdir_p!(Path.dirname(archive))
    File.write!(archive, "exact bytes")

    assert {:ok, [%{network: false, object_status: :imported}]} =
             HexCache.prepare(state, Path.join(root, "context"), lockfile,
               source_cache: native,
               fetch: fn _object, _path ->
                 flunk("verified native bytes must not be downloaded")
               end
             )
  end

  test "an absent capture is retried when the archive appears later in the invocation", context do
    root = temporary_directory!(context)
    state = Path.join(root, "state")
    native = Path.join(root, "native")
    lockfile = lockfile!(root, "sample", "1.2.3", "exact bytes")
    archive = Path.join([native, "packages", "hexpm", "sample-1.2.3.tar"])
    memo = :ets.new(__MODULE__, [:set, :public])

    assert :ok = HexCache.capture(state, native, lockfile, memo: memo)
    File.mkdir_p!(Path.dirname(archive))
    File.write!(archive, "exact bytes")
    assert :ok = HexCache.capture(state, native, lockfile, memo: memo)

    assert {:ok, [%{network: false}]} =
             HexCache.prepare(state, Path.join(root, "context"), lockfile,
               memo: memo,
               fetch: fn _object, _path -> flunk("captured bytes must be reused") end
             )
  end

  test "capture quarantines a corrupt retained object before importing native bytes", context do
    root = temporary_directory!(context)
    state = Path.join(root, "state")
    native = Path.join(root, "native")
    lockfile = lockfile!(root, "sample", "1.2.3", "exact bytes")
    archive = Path.join([native, "packages", "hexpm", "sample-1.2.3.tar"])
    File.mkdir_p!(Path.dirname(archive))
    File.write!(archive, "exact bytes")

    assert {:ok, [%{object: object}]} =
             HexCache.prepare(state, Path.join(root, "context"), lockfile,
               source_cache: native,
               fetch: fn _object, _path -> flunk("native bytes must be imported") end
             )

    File.chmod!(object, 0o600)
    File.write!(object, "corrupt")
    assert :ok = HexCache.capture(state, native, lockfile)
    assert File.read!(object) == "exact bytes"
    assert [_quarantined] = Path.wildcard(object <> ".corrupt.*")
  end

  test "native Hex fetch receives a private output directory and supplies its named archive",
       context do
    root = temporary_directory!(context)
    state = Path.join(root, "state")
    lockfile = lockfile!(root, "sample", "1.2.3", "exact bytes")
    parent = self()

    command_runner = fn executable, args, command_opts ->
      output = args |> Enum.drop_while(&(&1 != "--output")) |> Enum.at(1)
      send(parent, {:native_fetch, executable, args, command_opts, output})
      File.write!(Path.join(output, "sample-1.2.3.tar"), "exact bytes")
      {:ok, %{exit_code: 0, output: ""}}
    end

    assert {:ok, [%{object_status: :fetched}]} =
             HexCache.prepare(state, Path.join(root, "context"), lockfile,
               command_runner: command_runner,
               env: []
             )

    assert_receive {:native_fetch, _executable, args, command_opts, output}
    assert File.dir?(output) == false
    assert Enum.take(args, 5) == ["hex.package", "fetch", "sample", "1.2.3", "--repo"]
    assert Keyword.fetch!(command_opts, :replace_env)
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

  test "a broken symlink cannot masquerade as an absent retained object", context do
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

    File.rm!(object)
    File.ln_s!(Path.join(root, "missing"), object)

    assert {:ok, [%{object_status: :fetched}]} =
             HexCache.prepare(state, Path.join(root, "context-b"), lockfile, fetch: fetch)

    assert :atomics.get(calls, 1) == 2
    assert [_quarantined] = Path.wildcard(object <> ".corrupt.*")
    assert File.read!(object) == "exact bytes"
  end

  test "a corrupt context view is quarantined and restored from the retained object", context do
    root = temporary_directory!(context)
    state = Path.join(root, "state")
    cache = Path.join(root, "context")
    lockfile = lockfile!(root, "sample", "1.2.3", "exact bytes")

    fetch = fn _object, path -> File.write(path, "exact bytes") end

    assert {:ok, [_report]} = HexCache.prepare(state, cache, lockfile, fetch: fetch)

    view = Path.join([cache, "packages", "hexpm", "sample-1.2.3.tar"])
    File.rm!(view)
    File.write!(view, "corrupt")

    assert {:ok, [%{object_status: :hit, view_status: :copied}]} =
             HexCache.prepare(state, cache, lockfile, fetch: fetch)

    assert File.read!(view) == "exact bytes"
    assert [_quarantined] = Path.wildcard(view <> ".corrupt.*")
  end

  test "a writable context view cannot mutate the retained object", context do
    root = temporary_directory!(context)
    state = Path.join(root, "state")
    cache = Path.join(root, "context")
    lockfile = lockfile!(root, "sample", "1.2.3", "exact bytes")
    fetch = fn _object, path -> File.write(path, "exact bytes") end

    assert {:ok, [%{object: object, view_status: :copied}]} =
             HexCache.prepare(state, cache, lockfile, fetch: fetch)

    view = Path.join([cache, "packages", "hexpm", "sample-1.2.3.tar"])
    refute File.stat!(object).inode == File.stat!(view).inode

    File.chmod!(view, 0o600)
    File.write!(view, "changed through context")
    assert File.read!(object) == "exact bytes"

    assert {:ok, [%{object_status: :hit, view_status: :copied}]} =
             HexCache.prepare(state, cache, lockfile, fetch: fetch)

    assert File.read!(view) == "exact bytes"
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
