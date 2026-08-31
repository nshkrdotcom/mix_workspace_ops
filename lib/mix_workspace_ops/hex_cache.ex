defmodule MixWorkspaceOps.HexCache do
  @moduledoc """
  Immutable retention for exact Hex archives that the native cache may replace.

  Hex remains responsible for ordinary current-package resolution and cache
  behavior. This module preserves locked, already verified archive bytes by
  outer checksum, installs them atomically, and quarantines malformed objects.
  The runtime bootstrap exposes those exact materializations through a narrow
  SCM so a retained pre-replacement object does not need the current registry
  to agree with its historical checksum.
  """

  alias Mix.Sync.Lock, as: SyncLock
  alias MixWorkspaceOps.Report

  @schema "mix_workspace_ops.hex_object/v1"
  @digest ~r/^[0-9a-f]{64}$/

  @spec ensure(String.t(), map(), (map() -> {:ok, binary()} | {:error, term()}), keyword()) ::
          {:ok, map()} | {:error, term()}
  def ensure(state_root, object, fetch, opts \\ [])
      when is_binary(state_root) and is_map(object) and is_function(fetch, 1) do
    started_at = System.monotonic_time()

    with {:ok, object} <- normalize_object(object) do
      state_root = Path.expand(state_root)
      lock = "mix_workspace_ops:hex:" <> object.outer_checksum

      lock
      |> SyncLock.with_lock(fn ->
        ensure_locked(state_root, object, fetch, opts)
      end)
      |> with_duration(started_at)
    end
  end

  defp lookup(state_root, object) when is_binary(state_root) and is_map(object) do
    with {:ok, object} <- normalize_object(object) do
      read_object(Path.expand(state_root), object)
    end
  end

  defp archive_path(state_root, object) do
    case lookup(state_root, object) do
      {:ok, report} -> {:ok, report.archive}
      other -> other
    end
  end

  @doc "Fetches a public Hex archive without reading operator credentials."
  @spec fetch(map()) :: {:ok, binary()} | {:error, term()}
  def fetch(%{repository: "hexpm", package: package, version: version}) do
    url =
      "https://repo.hex.pm/tarballs/#{URI.encode(package)}-#{URI.encode(version)}.tar"
      |> String.to_charlist()

    with {:ok, _apps} <- Application.ensure_all_started(:inets),
         {:ok, _apps} <- Application.ensure_all_started(:ssl) do
      case :httpc.request(
             :get,
             {url, [{~c"user-agent", ~c"mix_workspace_ops/0.1.0"}]},
             [ssl: ssl_options()],
             body_format: :binary
           ) do
        {:ok, {{_http, 200, _reason}, _headers, body}} -> {:ok, body}
        {:ok, {{_http, status, _reason}, _headers, _body}} -> {:error, {:hex_status, status}}
        {:error, reason} -> {:error, {:hex_request, reason}}
      end
    end
  end

  def fetch(%{repository: repository}), do: {:error, {:hex_repository_unsupported, repository}}

  @doc "Materializes one retained exact archive into an exact Mix dependency path."
  @spec materialize(String.t(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def materialize(state_root, object, deps_path)
      when is_binary(state_root) and is_map(object) and is_binary(deps_path) do
    with {:ok, object} <- normalize_object(object),
         :ok <- materialization_application(object[:app]),
         state_root = Path.expand(state_root),
         deps_path = Path.expand(deps_path),
         true <-
           inside?(deps_path, Path.join([state_root, "contexts", "deps"])) ||
             {:error, {:hex_materialize_path, deps_path}},
         {:ok, archive} <- archive_path(state_root, object) do
      SyncLock.with_lock(deps_path, fn ->
        materialize_locked(object, archive, deps_path)
      end)
    end
  end

  defp ensure_locked(state_root, object, fetch, opts) do
    case read_object(state_root, object) do
      {:ok, report} ->
        {:ok, report |> Map.put(:status, :hit) |> Map.put(:bytes_downloaded, 0)}

      :absent ->
        fetch_and_install(state_root, object, fetch, opts, nil)

      {:error, {:hex_cache_corrupt, _path, _reason} = corruption} ->
        with {:ok, quarantine} <- quarantine(state_root, object) do
          fetch_and_install(state_root, object, fetch, opts, %{
            path: quarantine,
            reason: corruption
          })
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp fetch_and_install(state_root, object, fetch, opts, quarantine) do
    with {:ok, bytes} when is_binary(bytes) <- fetch.(object),
         :ok <- verify_outer(bytes, object),
         {:ok, report} <- install(state_root, object, bytes, opts) do
      status = if quarantine, do: :repaired, else: :miss

      {:ok,
       report
       |> Map.put(:status, status)
       |> Map.put(:bytes_downloaded, report.size)
       |> Map.put(:quarantine, quarantine)}
    else
      {:ok, other} -> {:error, {:hex_fetch_bytes, object.identity, other}}
      {:error, _reason} = error -> error
    end
  end

  defp install(state_root, object, bytes, opts) do
    objects = objects_root(state_root)
    destination = object_root(state_root, object)
    temporary = Path.join(objects, ".tmp-#{object.outer_checksum}-#{random_suffix()}")
    archive = Path.join(temporary, "package.tar")
    manifest = Path.join(temporary, "manifest.json")
    verify = Keyword.get(opts, :verify, &verify_archive/2)

    result =
      with :ok <- mkdir_private(objects),
           :ok <- File.mkdir(temporary),
           :ok <- File.chmod(temporary, 0o700),
           :ok <- write_private(archive, bytes),
           :ok <- verify.(archive, object),
           :ok <- write_manifest(manifest, object, byte_size(bytes)),
           :ok <- install_directory(temporary, destination) do
        read_object(state_root, object)
      end

    File.rm_rf(temporary)
    result
  end

  defp install_directory(temporary, destination) do
    case File.rename(temporary, destination) do
      :ok -> :ok
      {:error, :eexist} -> :ok
      {:error, reason} -> {:error, {:hex_cache_install, destination, reason}}
    end
  end

  defp read_object(state_root, object) do
    root = object_root(state_root, object)
    archive = Path.join(root, "package.tar")
    manifest = Path.join(root, "manifest.json")

    case File.lstat(root) do
      {:error, :enoent} ->
        :absent

      {:ok, %{type: :directory}} ->
        with {:ok, metadata} <- read_manifest(manifest),
             :ok <- verify_manifest(metadata, object),
             {:ok, %{type: :regular, size: size}} <- File.stat(archive),
             true <- size == metadata["size"] || {:error, {:size, metadata["size"], size}},
             {:ok, bytes} <- File.read(archive),
             :ok <- verify_outer(bytes, object) do
          {:ok,
           %{
             schema: @schema,
             identity: object.identity,
             repository: object.repository,
             package: object.package,
             version: object.version,
             inner_checksum: object.inner_checksum,
             outer_checksum: object.outer_checksum,
             size: size,
             root: root,
             archive: archive,
             manifest: manifest
           }}
        else
          {:error, reason} -> {:error, {:hex_cache_corrupt, root, reason}}
          false -> {:error, {:hex_cache_corrupt, root, :invalid_manifest}}
        end

      {:ok, %{type: type}} ->
        {:error, {:hex_cache_corrupt, root, {:object_type, type}}}

      {:error, reason} ->
        {:error, {:hex_cache_read, root, reason}}
    end
  end

  defp verify_archive(archive, object) do
    destination = archive <> ".unpack-" <> random_suffix()

    result =
      with :ok <- load_hex_tar(),
           # Hex is supplied by the installed Mix archive, not a compile-time dependency.
           # credo:disable-for-next-line Credo.Check.Refactor.Apply
           metadata <- apply(Hex.Tar, :unpack!, [archive, destination]) do
        verify_unpacked(metadata, object)
      end

    File.rm_rf(destination)
    result
  rescue
    error -> {:error, {:hex_archive, error.__struct__, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:hex_archive, kind, reason}}
  end

  defp materialize_locked(object, archive, deps_path) do
    destination = Path.join(deps_path, object.app)

    case exact_materialization?(destination, object) do
      true ->
        {:ok,
         %{
           status: :hit,
           extracted: false,
           destination: destination,
           outer_checksum: object.outer_checksum
         }}

      false ->
        install_materialization(object, archive, deps_path, destination)
    end
  end

  defp install_materialization(object, archive, deps_path, destination) do
    temporary = Path.join(deps_path, ".tmp-#{object.app}-#{random_suffix()}")

    result =
      with :ok <- mkdir_private(deps_path),
           :ok <- remove_stale_materializations(deps_path, object.app),
           :ok <- load_hex_tar(),
           # Hex is supplied by the installed Mix archive, not a compile-time dependency.
           # credo:disable-for-next-line Credo.Check.Refactor.Apply
           metadata <- apply(Hex.Tar, :unpack!, [archive, temporary]),
           :ok <- verify_unpacked(metadata, object),
           :ok <- write_hex_manifest(temporary, object),
           {:ok, quarantine} <- replace_materialization(destination, temporary) do
        {:ok,
         %{
           status: :miss,
           extracted: true,
           destination: destination,
           outer_checksum: object.outer_checksum,
           quarantine: quarantine
         }}
      end

    File.rm_rf(temporary)
    result
  rescue
    error -> {:error, {:hex_materialize, error.__struct__, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:hex_materialize, kind, reason}}
  end

  defp replace_materialization(destination, temporary) do
    quarantine = destination <> ".mwo-quarantine-" <> random_suffix()

    moved =
      case File.rename(destination, quarantine) do
        :ok -> {:ok, quarantine}
        {:error, :enoent} -> {:ok, nil}
        {:error, reason} -> {:error, {:hex_materialize_replace, destination, reason}}
      end

    with {:ok, quarantine} <- moved do
      case File.rename(temporary, destination) do
        :ok -> {:ok, quarantine}
        {:error, reason} -> restore_materialization(destination, quarantine, reason)
      end
    end
  end

  defp restore_materialization(destination, nil, reason),
    do: {:error, {:hex_materialize_install, destination, reason}}

  defp restore_materialization(destination, quarantine, reason) do
    case File.rename(quarantine, destination) do
      :ok ->
        {:error, {:hex_materialize_install, destination, reason}}

      {:error, restore_reason} ->
        {:error,
         {:hex_materialize_install_and_restore, destination, reason, quarantine, restore_reason}}
    end
  end

  defp remove_stale_materializations(deps_path, app) do
    prefix = ".tmp-#{app}-"

    case File.ls(deps_path) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.starts_with?(&1, prefix))
        |> Enum.reduce_while(:ok, &remove_stale_materialization(Path.join(deps_path, &1), &2))

      {:error, reason} ->
        {:error, {:hex_materialize_list, deps_path, reason}}
    end
  end

  defp remove_stale_materialization(path, :ok) do
    case File.rm_rf(path) do
      {:ok, _removed} ->
        {:cont, :ok}

      {:error, reason, failed_path} ->
        {:halt, {:error, {:hex_materialize_stale, failed_path, reason}}}
    end
  end

  defp exact_materialization?(destination, object) do
    path = Path.join(destination, ".hex")

    with {:ok, bytes} <- File.read(path),
         {{:hex, 2, 0}, metadata} when is_map(metadata) <- :erlang.binary_to_term(bytes, [:safe]) do
      metadata[:name] == object.package and metadata[:version] == object.version and
        metadata[:inner_checksum] == object.inner_checksum and
        metadata[:outer_checksum] == object.outer_checksum and
        metadata[:repo] == object.repository
    else
      _missing_or_invalid -> false
    end
  rescue
    _error -> false
  end

  defp write_hex_manifest(destination, object) do
    bytes =
      :erlang.term_to_binary(
        {{:hex, 2, 0},
         %{
           name: object.package,
           version: object.version,
           inner_checksum: object.inner_checksum,
           outer_checksum: object.outer_checksum,
           repo: object.repository,
           managers: object[:managers] || []
         }}
      )

    File.write(Path.join(destination, ".hex"), bytes, [:exclusive, :sync])
  end

  defp load_hex_tar do
    Mix.Local.append_archives()

    if Code.ensure_loaded?(Hex.Tar) and function_exported?(Hex.Tar, :unpack!, 2),
      do: :ok,
      else: {:error, :hex_tar_unavailable}
  end

  defp verify_unpacked(metadata, object) when is_map(metadata) do
    inner = metadata |> Map.fetch!(:inner_checksum) |> encode_checksum()
    outer = metadata |> Map.fetch!(:outer_checksum) |> encode_checksum()

    cond do
      inner != object.inner_checksum ->
        {:error, {:hex_inner_checksum, object.inner_checksum, inner}}

      outer != object.outer_checksum ->
        {:error, {:hex_outer_checksum, object.outer_checksum, outer}}

      true ->
        :ok
    end
  end

  defp verify_unpacked(metadata, _object), do: {:error, {:hex_unpack_result, metadata}}

  defp encode_checksum(value) when is_binary(value) and byte_size(value) == 32,
    do: Base.encode16(value, case: :lower)

  defp encode_checksum(value) when is_binary(value), do: String.downcase(value)

  defp write_manifest(path, object, size) do
    Report.write(path, %{
      schema: @schema,
      identity: object.identity,
      repository: object.repository,
      package: object.package,
      version: object.version,
      inner_checksum: object.inner_checksum,
      outer_checksum: object.outer_checksum,
      size: size
    })
  end

  defp read_manifest(path) do
    with {:ok, bytes} <- File.read(path), metadata when is_map(metadata) <- :json.decode(bytes) do
      {:ok, metadata}
    else
      {:error, reason} -> {:error, {:manifest_read, reason}}
      _other -> {:error, :manifest_not_object}
    end
  rescue
    error -> {:error, {:manifest_json, Exception.message(error)}}
  end

  defp verify_manifest(metadata, object) do
    expected = %{
      "schema" => @schema,
      "identity" => object.identity,
      "repository" => object.repository,
      "package" => object.package,
      "version" => object.version,
      "inner_checksum" => object.inner_checksum,
      "outer_checksum" => object.outer_checksum
    }

    case Enum.find(expected, fn {key, value} -> metadata[key] != value end) do
      nil ->
        if is_integer(metadata["size"]) and metadata["size"] >= 0,
          do: :ok,
          else: {:error, {:manifest_size, metadata["size"]}}

      {key, value} ->
        {:error, {:manifest_field, key, value, metadata[key]}}
    end
  end

  defp quarantine(state_root, object) do
    source = object_root(state_root, object)
    root = Path.join([state_root, "cache", "hex", "quarantine"])

    destination =
      Path.join(
        root,
        "#{object.outer_checksum}-#{System.system_time(:second)}-#{random_suffix()}"
      )

    with :ok <- mkdir_private(root) do
      case File.rename(source, destination) do
        :ok -> {:ok, destination}
        {:error, :enoent} -> {:ok, nil}
        {:error, reason} -> {:error, {:hex_cache_quarantine, source, reason}}
      end
    end
  end

  defp normalize_object(object) do
    keys = ~w(identity repository package version inner_checksum outer_checksum)a

    with true <-
           Enum.all?(keys, &is_binary(Map.get(object, &1))) ||
             {:error, {:hex_object_fields, Map.take(object, keys)}},
         true <-
           Regex.match?(@digest, String.downcase(object.identity)) ||
             {:error, {:hex_object_identity, object.identity}},
         true <-
           Regex.match?(@digest, String.downcase(object.inner_checksum)) ||
             {:error, {:hex_inner_checksum, object.inner_checksum}},
         true <-
           Regex.match?(@digest, String.downcase(object.outer_checksum)) ||
             {:error, {:hex_outer_checksum, object.outer_checksum}} do
      normalized =
        object
        |> Map.take(keys ++ [:app, :managers])
        |> Map.update!(:identity, &String.downcase/1)
        |> Map.update!(:inner_checksum, &String.downcase/1)
        |> Map.update!(:outer_checksum, &String.downcase/1)

      expected =
        %{
          repository: normalized.repository,
          package: normalized.package,
          version: normalized.version,
          inner_checksum: normalized.inner_checksum,
          outer_checksum: normalized.outer_checksum
        }
        |> Report.encode()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      if normalized.identity == expected,
        do: {:ok, normalized},
        else: {:error, {:hex_object_identity, expected, normalized.identity}}
    end
  end

  defp materialization_application(app) do
    if is_binary(app) and Regex.match?(~r/^[a-z][a-z0-9_]*$/, app),
      do: :ok,
      else: {:error, {:hex_materialize_application, app}}
  end

  defp verify_outer(bytes, object) do
    actual = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

    if actual == object.outer_checksum,
      do: :ok,
      else: {:error, {:hex_outer_checksum, object.outer_checksum, actual}}
  end

  defp ssl_options do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  defp inside?(path, root) do
    path = Path.expand(path)
    root = Path.expand(root)
    path == root or String.starts_with?(path, root <> "/")
  end

  defp objects_root(state_root), do: Path.join([state_root, "cache", "hex", "objects"])

  defp object_root(state_root, object),
    do: Path.join(objects_root(state_root), object.outer_checksum)

  defp mkdir_private(path) do
    with :ok <- File.mkdir_p(path), do: File.chmod(path, 0o700)
  end

  defp write_private(path, bytes) do
    with :ok <- File.write(path, bytes, [:exclusive, :sync]), do: File.chmod(path, 0o600)
  end

  defp random_suffix,
    do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

  defp with_duration({:ok, report}, started_at) do
    duration = System.monotonic_time() - started_at

    {:ok,
     Map.put(report, :duration_ms, System.convert_time_unit(duration, :native, :millisecond))}
  end

  defp with_duration(other, _started_at), do: other
end
