defmodule MixWorkspaceOps.Runtime do
  @moduledoc "Operator-owned lock, dependency, build, and Hex isolation for one source digest."

  @spec prepare(String.t(), String.t(), binary()) :: {:ok, map()} | {:error, term()}
  def prepare(state_root, digest, lock_bytes) do
    root = state_root |> Path.expand() |> Path.join("runtimes") |> Path.join(digest)
    deps = Path.join(root, "deps")
    build = Path.join(root, "_build")
    hex = Path.join(root, "hex")
    lock = Path.join(root, "mix.lock")
    baseline = Path.join(root, "source.mix.lock")

    with :ok <- mkdir_private(root),
         :ok <- mkdir_private(deps),
         :ok <- mkdir_private(build),
         :ok <- mkdir_private(hex),
         :ok <- write_once(baseline, lock_bytes),
         :ok <- write_once(lock, lock_bytes) do
      {:ok,
       %{
         env: [
           {"MIX_DEPS_PATH", deps},
           {"MIX_BUILD_ROOT", build},
           {"HEX_HOME", hex},
           {"MIX_WORKSPACE_OPS_LOCKFILE", lock}
         ],
         report: %{
           schema: "mix_workspace_ops.runtime/v1",
           digest: digest,
           root: root,
           deps_path: deps,
           build_root: build,
           hex_home: hex,
           lockfile: lock,
           source_lock_digest: sha256(lock_bytes)
         }
       }}
    end
  end

  defp mkdir_private(path) do
    with :ok <- File.mkdir_p(path), do: File.chmod(path, 0o700)
  end

  defp write_once(path, bytes) do
    case File.read(path) do
      {:ok, ^bytes} ->
        :ok

      {:ok, _other} ->
        if Path.basename(path) == "mix.lock", do: :ok, else: {:error, {:runtime_drift, path}}

      {:error, :enoent} ->
        atomic_write(path, bytes)

      {:error, reason} ->
        {:error, {:runtime_file, path, reason}}
    end
  end

  defp atomic_write(path, bytes) do
    temporary = path <> ".tmp.#{System.unique_integer([:positive])}"

    with :ok <- File.write(temporary, bytes, [:sync]),
         :ok <- File.chmod(temporary, 0o600) do
      File.rename(temporary, path)
    end
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
