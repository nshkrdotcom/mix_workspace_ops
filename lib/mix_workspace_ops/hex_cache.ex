defmodule MixWorkspaceOps.HexCache do
  @moduledoc """
  Verified Hex transport objects and native per-context cache views.

  Resolution and extraction remain Hex responsibilities. MWO retains only the
  immutable archive bytes that native Hex cannot safely share between VMs or
  distinguish after a same-version republication.
  """

  alias Mix.Sync.Lock, as: SyncLock
  alias MixWorkspaceOps.{Command, Lockfile, ResourceBudget, Toolchain}

  @type object :: %{
          package: String.t(),
          version: String.t(),
          repo: String.t(),
          checksum: String.t()
        }

  defp objects(lockfile) do
    with {:ok, bytes} <- File.read(lockfile),
         {:ok, lock} <- Lockfile.parse_map(bytes) do
      objects_from_lock(lock)
    end
  end

  @doc "Installs verified objects into one dependency context's native Hex cache view."
  @spec prepare(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def prepare(state_root, cache_home, lockfile, opts \\ []) do
    with {:ok, objects} <- objects(lockfile) do
      concurrency =
        Keyword.get_lazy(opts, :max_concurrency, fn ->
          ResourceBudget.snapshot()
          |> ResourceBudget.allocate(:transport, length(objects))
          |> Map.fetch!(:workers)
        end)

      objects
      |> Task.async_stream(&prepare_object(state_root, cache_home, &1, opts),
        max_concurrency: max(1, concurrency),
        ordered: true,
        timeout: Keyword.get(opts, :timeout, 120_000),
        on_timeout: :kill_task
      )
      |> collect()
    end
  end

  @doc "Captures archives fetched by Mix for a previously unlocked context."
  @spec capture(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def capture(state_root, cache_home, lockfile) do
    with {:ok, objects} <- objects(lockfile) do
      Enum.reduce_while(objects, :ok, fn object, :ok ->
        source = native_path(cache_home, object)

        case valid?(source, object.checksum) do
          true ->
            result =
              with_object_lock(state_root, object, fn ->
                install_existing(state_root, object, source)
              end)

            case result do
              {:ok, _path, _status} -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, reason}}
            end

          false ->
            {:cont, :ok}
        end
      end)
    end
  end

  defp prepare_object(state_root, cache_home, object, opts) do
    digest = identity_digest(object)

    with_object_lock(state_root, object, fn ->
      with {:ok, object_path, object_status} <- ensure_object(state_root, object, opts),
           {:ok, view_status} <- install_view(cache_home, object, object_path) do
        {:ok,
         Map.merge(object, %{
           identity: digest,
           object: object_path,
           object_status: object_status,
           view_status: view_status,
           network: object_status == :fetched
         })}
      end
    end)
  end

  defp with_object_lock(state_root, object, operation) do
    key =
      "mix_workspace_ops:hex-object:" <>
        Path.expand(state_root) <> ":" <> identity_digest(object)

    SyncLock.with_lock(key, operation)
  end

  defp ensure_object(state_root, object, opts) do
    path = object_path(state_root, object)

    cond do
      valid?(path, object.checksum) ->
        {:ok, path, :hit}

      File.exists?(path) ->
        quarantine(path)
        fetch_object(path, object, opts, 2)

      true ->
        source_cache = Keyword.get(opts, :source_cache)
        source = if source_cache, do: native_path(source_cache, object)

        if is_binary(source) and valid?(source, object.checksum),
          do: install_existing(state_root, object, source),
          else: fetch_object(path, object, opts, 2)
    end
  end

  defp install_existing(state_root, object, source) do
    path = object_path(state_root, object)

    if valid?(path, object.checksum) do
      {:ok, path, :hit}
    else
      with :ok <- atomic_copy(source, path),
           true <- valid?(path, object.checksum) || {:error, {:hex_object_checksum, object}} do
        File.chmod(path, 0o400)
        {:ok, path, :imported}
      end
    end
  end

  defp fetch_object(_path, object, _opts, 0),
    do: {:error, {:hex_object_checksum, object}}

  defp fetch_object(path, object, opts, attempts) do
    temporary = temporary(path)
    File.mkdir_p!(Path.dirname(path))

    result =
      with :ok <- fetch(object, temporary, opts),
           true <- valid?(temporary, object.checksum) || :invalid_checksum,
           :ok <- File.rename(temporary, path),
           :ok <- File.chmod(path, 0o400) do
        {:ok, path, :fetched}
      end

    case result do
      {:ok, _path, _status} = ok ->
        ok

      :invalid_checksum ->
        quarantine(temporary)
        fetch_object(path, object, opts, attempts - 1)

      {:error, reason} ->
        File.rm(temporary)
        {:error, {:hex_object_fetch, object, reason}}
    end
  end

  defp fetch(object, path, opts) do
    case Keyword.get(opts, :fetch) do
      function when is_function(function, 2) ->
        function.(object, path)

      nil ->
        args = [
          "hex.package",
          "fetch",
          object.package,
          object.version,
          "--repo",
          object.repo,
          "--output",
          path
        ]

        case Command.run(Toolchain.executable("mix"), args,
               cd: Keyword.get(opts, :cd, System.tmp_dir!()),
               replace_env: true,
               env: Keyword.fetch!(opts, :env)
             ) do
          {:ok, _result} -> :ok
          {:error, result} -> {:error, {:command_failed, result.exit_code, result.output}}
        end
    end
  end

  defp install_view(cache_home, object, source) do
    destination = native_path(cache_home, object)

    cond do
      valid?(destination, object.checksum) ->
        {:ok, :hit}

      File.exists?(destination) ->
        quarantine(destination)
        link_or_copy(source, destination)

      true ->
        link_or_copy(source, destination)
    end
  end

  defp link_or_copy(source, destination) do
    File.mkdir_p!(Path.dirname(destination))

    case File.ln(source, destination) do
      :ok ->
        {:ok, :linked}

      {:error, :eexist} ->
        {:ok, :hit}

      {:error, _cross_device_or_unsupported} ->
        with :ok <- atomic_copy(source, destination) do
          {:ok, :copied}
        end
    end
  end

  defp atomic_copy(source, destination) do
    temporary = temporary(destination)

    with :ok <- File.mkdir_p(Path.dirname(destination)),
         :ok <- File.cp(source, temporary),
         :ok <- File.chmod(temporary, 0o400),
         :ok <- File.rename(temporary, destination) do
      :ok
    else
      {:error, reason} ->
        File.rm(temporary)
        {:error, reason}
    end
  end

  defp objects_from_lock(lock) do
    lock
    |> Enum.reduce_while({:ok, []}, fn {_app, entry}, {:ok, objects} ->
      case hex_object(entry) do
        :not_hex -> {:cont, {:ok, objects}}
        {:ok, object} -> {:cont, {:ok, [object | objects]}}
        :unverifiable -> {:halt, {:error, :unverifiable_hex_lock}}
      end
    end)
    |> case do
      {:ok, objects} -> {:ok, Enum.sort_by(objects, &identity_digest/1)}
      error -> error
    end
  end

  defp hex_object(entry) when is_tuple(entry) do
    case Tuple.to_list(entry) do
      [:hex, package, version, _inner, _managers, _dependencies, repo, checksum | _rest]
      when (is_atom(package) or is_binary(package)) and is_binary(version) and
             is_binary(repo) and is_binary(checksum) ->
        object = %{
          package: to_string(package),
          version: version,
          repo: repo,
          checksum: String.downcase(checksum)
        }

        if valid_object?(object), do: {:ok, object}, else: :unverifiable

      [:hex | _incomplete] ->
        :unverifiable

      _other ->
        :not_hex
    end
  end

  defp hex_object(_entry), do: :not_hex

  defp valid_object?(object) do
    Enum.all?([object.package, object.repo], &Regex.match?(~r/^[A-Za-z0-9_.-]+$/, &1)) and
      Regex.match?(~r/^[A-Za-z0-9+_.-]+$/, object.version) and
      Regex.match?(~r/^[0-9a-f]{64}$/, object.checksum)
  end

  defp object_path(state_root, object) do
    Path.join([state_root, "cache", "hex", "objects", identity_digest(object) <> ".tar"])
  end

  defp native_path(cache_home, object) do
    Path.join([cache_home, "packages", object.repo, "#{object.package}-#{object.version}.tar"])
  end

  defp identity_digest(object) do
    [object.repo, object.package, object.version, object.checksum]
    |> Enum.join("\0")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp valid?(path, checksum) do
    case File.stat(path) do
      {:ok, %{type: :regular, size: size}} when size > 0 -> file_sha256(path) == checksum
      _missing -> false
    end
  rescue
    _changed -> false
  end

  defp file_sha256(path) do
    path
    |> File.stream!(64 * 1024, [])
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp quarantine(path) do
    if File.exists?(path) do
      suffix = "#{System.system_time(:millisecond)}.#{System.unique_integer([:positive])}"
      _ = File.rename(path, path <> ".corrupt." <> suffix)
    end

    :ok
  end

  defp temporary(path),
    do: path <> ".tmp.#{System.unique_integer([:positive, :monotonic])}"

  defp collect(stream) do
    Enum.reduce_while(stream, {:ok, []}, fn
      {:ok, {:ok, report}}, {:ok, reports} -> {:cont, {:ok, [report | reports]}}
      {:ok, {:error, reason}}, _acc -> {:halt, {:error, reason}}
      {:exit, reason}, _acc -> {:halt, {:error, {:hex_object_task_exit, reason}}}
    end)
    |> case do
      {:ok, reports} -> {:ok, Enum.reverse(reports)}
      error -> error
    end
  end
end
