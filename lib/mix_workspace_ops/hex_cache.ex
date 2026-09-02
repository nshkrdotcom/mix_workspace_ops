defmodule MixWorkspaceOps.HexCache do
  @moduledoc false

  alias MixWorkspaceOps.Lockfile

  @doc false
  @spec complete?(String.t(), String.t(), :ets.tid()) :: boolean()
  def complete?(cache_home, lockfile, memo) do
    with {:ok, bytes} <- File.read(lockfile),
         {:ok, lock} <- Lockfile.parse_map(bytes),
         {:ok, objects} <- objects(lock),
         false <- objects == [] do
      Enum.all?(objects, &cached?(cache_home, &1, memo))
    else
      _incomplete_or_unverifiable -> false
    end
  end

  defp objects(lock) do
    Enum.reduce_while(lock, {:ok, []}, fn {_app, entry}, {:ok, objects} ->
      case hex_object(entry) do
        :not_hex -> {:cont, {:ok, objects}}
        {:ok, object} -> {:cont, {:ok, [object | objects]}}
        :unverifiable -> {:halt, :error}
      end
    end)
  end

  defp hex_object(entry) when is_tuple(entry) do
    case Tuple.to_list(entry) do
      [:hex, package, version, _inner, _managers, _dependencies, repo, checksum | _rest]
      when (is_atom(package) or is_binary(package)) and is_binary(version) and
             is_binary(repo) and is_binary(checksum) ->
        {:ok, %{package: to_string(package), version: version, repo: repo, checksum: checksum}}

      [:hex | _incomplete] ->
        :unverifiable

      _other ->
        :not_hex
    end
  end

  defp hex_object(_entry), do: :not_hex

  defp cached?(cache_home, object, memo) do
    path =
      Path.join([
        cache_home,
        "packages",
        object.repo,
        "#{object.package}-#{object.version}.tar"
      ])

    with {:ok, stat} <- File.stat(path),
         true <- stat.type == :regular and stat.size > 0 do
      key = {path, stat.inode, stat.size, stat.mtime, object.checksum}

      case :ets.lookup(memo, key) do
        [{^key, valid?}] -> valid?
        [] -> verify_and_store(path, object.checksum, memo, key)
      end
    else
      _missing_or_invalid -> false
    end
  rescue
    _changed_while_reading -> false
  end

  defp verify_and_store(path, checksum, memo, key) do
    valid? = file_sha256(path) == String.downcase(checksum)
    :ets.insert(memo, {key, valid?})
    valid?
  end

  defp file_sha256(path) do
    path
    |> File.stream!(64 * 1024, [])
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end
end
