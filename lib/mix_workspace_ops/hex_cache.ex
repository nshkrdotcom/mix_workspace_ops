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
        on_timeout: :kill_task,
        zip_input_on_exit: true
      )
      |> collect()
    end
  end

  @doc "Captures archives fetched by Mix for a previously unlocked context."
  @spec capture(String.t(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def capture(state_root, cache_home, lockfile, opts \\ []) do
    with {:ok, objects} <- objects(lockfile) do
      Enum.reduce_while(objects, :ok, fn object, :ok ->
        source = native_path(cache_home, object)
        capture_object(state_root, object, source, opts)
      end)
    end
  end

  defp capture_object(state_root, object, source, opts) do
    key = {Path.expand(state_root), identity_digest(object)}

    result =
      opts
      |> Keyword.get(:memo)
      |> memoized(key, fn -> capture_source(state_root, object, source) end)

    capture_result(result)
  end

  defp capture_result({:ok, _path, _status}), do: {:cont, :ok}
  defp capture_result(:missing), do: {:cont, :ok}
  defp capture_result({:error, reason}), do: {:halt, {:error, reason}}

  defp capture_source(state_root, object, source) do
    if valid?(source, object.checksum) do
      with_object_lock(state_root, object, fn -> install_existing(state_root, object, source) end)
    else
      :missing
    end
  end

  defp prepare_object(state_root, cache_home, object, opts) do
    key = {Path.expand(state_root), identity_digest(object)}

    object_result =
      memoized(Keyword.get(opts, :memo), key, fn ->
        with_object_lock(state_root, object, fn -> ensure_object(state_root, object, opts) end)
      end)

    with {:ok, object_path, object_status} <- object_result,
         {:ok, view_status} <- install_view(cache_home, object, object_path) do
      {:ok,
       Map.merge(object, %{
         identity: identity_digest(object),
         object: object_path,
         object_status: object_status,
         view_status: view_status,
         network: object_status == :fetched
       })}
    end
  end

  defp memoized(nil, _key, operation), do: operation.()

  defp memoized(memo, key, operation) do
    case :ets.lookup(memo, key) do
      [{^key, result}] -> memoized_result(result)
      [] -> fill_memo(memo, key, operation)
    end
  end

  defp fill_memo(memo, key, operation) do
    lock = "mix_workspace_ops:hex-memo:" <> term_digest(key)
    SyncLock.with_lock(lock, fn -> fill_memo_locked(memo, key, operation) end)
  end

  defp fill_memo_locked(memo, key, operation) do
    case :ets.lookup(memo, key) do
      [{^key, result}] ->
        memoized_result(result)

      [] ->
        result = operation.()
        if result != :missing, do: :ets.insert(memo, {key, result})
        result
    end
  end

  defp memoized_result({:ok, path, _status}), do: {:ok, path, :hit}

  defp memoized_result(:missing), do: :missing

  defp memoized_result({:error, _reason} = error), do: error

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

      present?(path) ->
        with :ok <- quarantine(path), do: fetch_object(path, object, opts, 2)

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

    cond do
      valid?(path, object.checksum) ->
        {:ok, path, :hit}

      present?(path) ->
        with :ok <- quarantine(path), do: install_verified_copy(path, object, source)

      true ->
        install_verified_copy(path, object, source)
    end
  end

  defp install_verified_copy(path, object, source) do
    with :ok <- atomic_copy(source, path),
         true <- valid?(path, object.checksum) || {:error, {:hex_object_checksum, object}},
         :ok <- File.chmod(path, 0o400) do
      {:ok, path, :imported}
    end
  end

  defp fetch_object(_path, object, _opts, 0),
    do: {:error, {:hex_object_checksum, object}}

  defp fetch_object(path, object, opts, attempts) do
    temporary_root = temporary(path)
    temporary = Path.join(temporary_root, "#{object.package}-#{object.version}.tar")
    File.mkdir_p!(Path.dirname(path))

    result =
      with :ok <- File.mkdir(temporary_root),
           :ok <- fetch(object, temporary, opts),
           true <- valid?(temporary, object.checksum) || :invalid_checksum,
           :ok <- File.rename(temporary, path),
           :ok <- File.chmod(path, 0o400) do
        {:ok, path, :fetched}
      end

    case result do
      {:ok, _path, _status} = ok ->
        File.rm_rf(temporary_root)
        ok

      :invalid_checksum ->
        quarantine_result = quarantine_as(temporary, path)
        File.rm_rf(temporary_root)

        case quarantine_result do
          :ok -> fetch_object(path, object, opts, attempts - 1)
          {:error, reason} -> {:error, {:hex_object_quarantine, path, reason}}
        end

      {:error, reason} ->
        File.rm_rf(temporary_root)
        {:error, {:hex_object_fetch, object, reason}}
    end
  end

  defp fetch(object, path, opts) do
    case Keyword.get(opts, :fetch) do
      function when is_function(function, 2) ->
        function.(object, path)

      nil ->
        output = Path.dirname(path)

        args = [
          "hex.package",
          "fetch",
          object.package,
          object.version,
          "--repo",
          object.repo,
          "--output",
          output
        ]

        runner = Keyword.get(opts, :command_runner, &Command.run/3)

        case runner.(Toolchain.executable("mix"), args,
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

    SyncLock.with_lock("mix_workspace_ops:hex-view:" <> Path.expand(destination), fn ->
      install_view_locked(destination, object, source)
    end)
  end

  defp install_view_locked(destination, object, source) do
    cond do
      valid?(destination, object.checksum) ->
        {:ok, :hit}

      present?(destination) ->
        with :ok <- quarantine(destination),
             do: copy_view(source, destination, object.checksum)

      true ->
        copy_view(source, destination, object.checksum)
    end
  end

  # A hard link would let a child running as the same user chmod and mutate the
  # checksum-addressed retained object through its context view. A private copy
  # preserves the network/cache win without sharing a writable inode.
  defp copy_view(source, destination, checksum) do
    with :ok <- atomic_copy(source, destination),
         true <- valid?(destination, checksum) || {:error, {:hex_view_checksum, destination}} do
      {:ok, :copied}
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

  defp term_digest(term) do
    term
    |> :erlang.term_to_binary([:deterministic])
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
    quarantine_as(path, path)
  end

  defp quarantine_as(source, destination) do
    if present?(source) do
      suffix = "#{System.system_time(:millisecond)}.#{System.unique_integer([:positive])}"
      File.rename(source, destination <> ".corrupt." <> suffix)
    else
      :ok
    end
  end

  defp present?(path), do: match?({:ok, _stat}, File.lstat(path))

  defp temporary(path),
    do: path <> ".tmp.#{System.unique_integer([:positive, :monotonic])}"

  defp collect(stream) do
    Enum.reduce_while(stream, {:ok, []}, fn
      {:ok, {:ok, report}}, {:ok, reports} ->
        {:cont, {:ok, [report | reports]}}

      {:ok, {:error, reason}}, _acc ->
        {:halt, {:error, reason}}

      {:exit, {object, reason}}, _acc ->
        identity = Map.take(object, [:package, :version, :repo, :checksum])
        {:halt, {:error, {:hex_object_task_exit, identity, reason}}}
    end)
    |> case do
      {:ok, reports} -> {:ok, Enum.reverse(reports)}
      error -> error
    end
  end
end
