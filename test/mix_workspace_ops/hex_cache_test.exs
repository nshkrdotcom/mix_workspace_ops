defmodule MixWorkspaceOps.HexCacheTest do
  use MixWorkspaceOps.WorkspaceCase, async: true

  alias MixWorkspaceOps.HexCache

  test "accepts only the checksum-addressed Hex tarballs named by a complete lock", context do
    root = temporary_directory!(context)
    cache = Path.join(root, "hex")
    package = Path.join([cache, "packages", "hexpm", "sample-1.2.3.tar"])
    lockfile = Path.join(root, "mix.lock")
    bytes = "exact package bytes"
    checksum = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
    memo = :ets.new(__MODULE__, [:set, :public])

    File.mkdir_p!(Path.dirname(package))
    File.write!(package, bytes)

    File.write!(
      lockfile,
      inspect(%{sample: {:hex, :sample, "1.2.3", "inner", [:mix], [], "hexpm", checksum}})
    )

    assert HexCache.complete?(cache, lockfile, memo)

    File.write!(package, "wrong")
    refute HexCache.complete?(cache, lockfile, memo)

    File.write!(lockfile, "%{}\n")
    refute HexCache.complete?(cache, lockfile, memo)
  end
end
