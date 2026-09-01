defmodule MixWorkspaceOps.GitCache do
  @moduledoc """
  Bare remote mirrors used beneath ordinary Mix Git dependency checkouts.

  Mirrors remove repeated network fetches. Mix still initializes each dependency
  checkout, keeps the declared origin, checks out the locked commit, and owns the
  lock semantics. Mirror mutation is coordinated per normalized remote only.
  """

  alias Mix.Sync.Lock, as: SyncLock
  alias MixWorkspaceOps.{Lockfile, Report}

  @schema "mix_workspace_ops.git_mirror/v1"
  @commit ~r/^[0-9a-f]{40,64}$/
  @scp_remote ~r/^(?<user>[^@:\s]+)@(?<host>[^:\s]+):(?<path>.+)$/

  @doc "Extracts only locked Git transport objects from a literal lock map."
  @spec objects_from_lock(binary(), map()) :: {:ok, [map()]} | {:error, term()}
  def objects_from_lock(bytes, managed_sources \\ %{})
      when is_binary(bytes) and is_map(managed_sources) do
    with {:ok, lock} <- Lockfile.parse_map(bytes) do
      lock
      |> Enum.sort_by(fn {app, _entry} -> to_string(app) end)
      |> Enum.reduce_while(
        {:ok, []},
        &collect_git_object(managed_sources, &1, &2)
      )
      |> case do
        {:ok, objects} -> {:ok, Enum.reverse(objects)}
        error -> error
      end
    end
  end

  defp collect_git_object(managed_sources, {app, entry}, {:ok, objects}) do
    app = to_string(app)

    case git_lock_object(app, entry) do
      nil ->
        {:cont, {:ok, objects}}

      {:ok, object} ->
        {:cont, {:ok, include_managed_object(managed_sources, app, object, objects)}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp include_managed_object(managed_sources, app, object, objects) do
    if Map.get(managed_sources, app, "github") == "github",
      do: [object | objects],
      else: objects
  end

  defp git_lock_object(app, entry) when is_tuple(entry) do
    case Tuple.to_list(entry) do
      [:git, remote, commit, options]
      when is_binary(remote) and is_binary(commit) and is_list(options) ->
        {:ok, %{app: app, remote: remote, commit: commit, options: options}}

      [:git | _invalid] ->
        {:error, {:invalid_git_lock_entry, app}}

      _other ->
        nil
    end
  end

  defp git_lock_object(_app, _entry), do: nil

  @spec ensure(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def ensure(state_root, object, opts \\ []) when is_binary(state_root) and is_map(object) do
    started_at = System.monotonic_time()

    with {:ok, object} <- normalize_object(object) do
      state_root = Path.expand(state_root)
      remote_identity = remote_identity(object.remote)
      lock = "mix_workspace_ops:git:" <> remote_identity

      lock
      |> SyncLock.with_lock(fn ->
        ensure_locked(state_root, object, remote_identity, opts)
      end)
      |> with_duration(started_at)
    end
  end

  @doc "Git configuration that rewrites each declared remote to its local mirror."
  @spec environment([map()]) :: [{String.t(), String.t()}]
  def environment(reports) when is_list(reports) do
    rewrites =
      reports
      |> Enum.map(&{&1.remote, &1.mirror})
      |> Enum.uniq()
      |> Enum.sort()

    values =
      rewrites
      |> Enum.with_index()
      |> Enum.flat_map(fn {{remote, mirror}, index} ->
        [
          {"GIT_CONFIG_KEY_#{index}", "url.#{file_url(mirror)}.insteadOf"},
          {"GIT_CONFIG_VALUE_#{index}", remote}
        ]
      end)

    [{"GIT_CONFIG_COUNT", Integer.to_string(length(rewrites))} | values]
  end

  defp ensure_locked(state_root, object, remote_identity, opts) do
    mirror = mirror_path(state_root, remote_identity)
    refresh? = Keyword.get(opts, :refresh, false)

    case inspect_mirror(mirror, object) do
      {:ok, true} when not refresh? ->
        with :ok <- pin_commit(mirror, object.commit) do
          {:ok, report(object, remote_identity, mirror, :hit, nil)}
        end

      {:ok, _present} ->
        with :ok <- fetch_mirror(mirror, opts),
             {:ok, true} <- inspect_mirror(mirror, object),
             :ok <- pin_commit(mirror, object.commit) do
          {:ok, report(object, remote_identity, mirror, :refreshed, nil)}
        else
          {:ok, false} -> {:error, {:git_commit_unavailable, object.remote, object.commit}}
          {:error, _reason} = error -> error
        end

      :absent ->
        clone_mirror(state_root, object, remote_identity, opts, nil)

      {:error, reason} ->
        with {:ok, quarantine} <- quarantine(state_root, mirror, remote_identity) do
          clone_mirror(state_root, object, remote_identity, opts, %{
            path: quarantine,
            reason: reason
          })
        end
    end
  end

  defp clone_mirror(state_root, object, remote_identity, opts, quarantine) do
    root = mirrors_root(state_root)
    mirror = mirror_path(state_root, remote_identity)
    temporary = Path.join(root, ".tmp-#{remote_identity}-#{random_suffix()}.git")

    result =
      with :ok <- mkdir_private(root),
           {:ok, _output} <- git(["clone", "--mirror", "--quiet", object.remote, temporary], opts),
           {:ok, true} <- inspect_mirror(temporary, object, false),
           :ok <- pin_commit(temporary, object.commit),
           :ok <- write_manifest(temporary, object.remote, remote_identity),
           :ok <- install_directory(temporary, mirror) do
        status = if quarantine, do: :repaired, else: :miss
        {:ok, report(object, remote_identity, mirror, status, quarantine)}
      else
        {:ok, false} -> {:error, {:git_commit_unavailable, object.remote, object.commit}}
        {:error, _reason} = error -> error
      end

    File.rm_rf(temporary)
    result
  end

  defp inspect_mirror(path, object, verify_manifest? \\ true) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :absent

      {:ok, %{type: :directory}} ->
        with {:ok, "true\n"} <- git(["--git-dir", path, "rev-parse", "--is-bare-repository"], []),
             :ok <- maybe_verify_manifest(path, object, verify_manifest?),
             {:ok, _output} <-
               git(["--git-dir", path, "cat-file", "-e", object.commit <> "^{commit}"], []) do
          {:ok, true}
        else
          {:error, {:git_exit, _args, _status, _output}} -> {:ok, false}
          {:ok, output} -> {:error, {:git_mirror_bare, path, output}}
          {:error, _reason} = error -> error
        end

      {:ok, %{type: type}} ->
        {:error, {:git_mirror_type, path, type}}

      {:error, reason} ->
        {:error, {:git_mirror_read, path, reason}}
    end
  end

  defp maybe_verify_manifest(path, object, true), do: verify_manifest(path, object)
  defp maybe_verify_manifest(_path, _object, false), do: :ok

  defp fetch_mirror(mirror, opts) do
    case git(
           [
             "--git-dir",
             mirror,
             "fetch",
             "--quiet",
             "--prune",
             "origin",
             "+refs/*:refs/mix-workspace-ops/upstream/*"
           ],
           opts
         ) do
      {:ok, _output} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp pin_commit(mirror, commit) do
    ref = "refs/mix-workspace-ops/commits/" <> commit

    case git(["--git-dir", mirror, "update-ref", ref, commit], []) do
      {:ok, _output} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp write_manifest(mirror, _remote, identity) do
    path = Path.join(mirror, "mwo-mirror.json")
    Report.write(path, %{schema: @schema, remote_identity: identity})
  end

  defp verify_manifest(mirror, object) do
    path = manifest_path(mirror)
    identity = remote_identity(object.remote)

    with {:ok, bytes} <- File.read(path),
         metadata when is_map(metadata) <- :json.decode(bytes),
         true <- metadata["schema"] == @schema || {:error, {:git_mirror_schema, path}},
         true <-
           metadata["remote_identity"] == identity ||
             {:error, {:git_mirror_identity, path, identity, metadata["remote_identity"]}} do
      :ok
    else
      {:error, reason} -> {:error, {:git_mirror_manifest, path, reason}}
      _other -> {:error, {:git_mirror_manifest, path, :invalid}}
    end
  rescue
    error ->
      {:error, {:git_mirror_manifest, manifest_path(mirror), Exception.message(error)}}
  end

  defp manifest_path(mirror), do: Path.join(mirror, "mwo-mirror.json")

  defp install_directory(temporary, destination) do
    case File.rename(temporary, destination) do
      :ok -> :ok
      {:error, :eexist} -> :ok
      {:error, reason} -> {:error, {:git_mirror_install, destination, reason}}
    end
  end

  defp quarantine(state_root, mirror, identity) do
    root = Path.join([state_root, "cache", "git-quarantine"])

    destination =
      Path.join(root, "#{identity}-#{System.system_time(:second)}-#{random_suffix()}.git")

    with :ok <- mkdir_private(root) do
      case File.rename(mirror, destination) do
        :ok -> {:ok, destination}
        {:error, :enoent} -> {:ok, nil}
        {:error, reason} -> {:error, {:git_mirror_quarantine, mirror, reason}}
      end
    end
  end

  defp git(args, opts) do
    command = Keyword.get(opts, :command, System.find_executable("git") || "git")
    env = Keyword.get(opts, :env, [])

    case System.cmd(command, args, env: env, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:git_exit, args, status, output}}
    end
  rescue
    error -> {:error, {:git_command, args, error.__struct__, Exception.message(error)}}
  end

  defp normalize_object(object) do
    with true <- is_binary(object[:remote]) || {:error, {:git_remote, object[:remote]}},
         true <- is_binary(object[:commit]) || {:error, {:git_commit, object[:commit]}},
         commit = String.downcase(object.commit),
         true <- Regex.match?(@commit, commit) || {:error, {:git_commit, object.commit}} do
      {:ok, Map.put(object, :commit, commit)}
    end
  end

  defp remote_identity(remote) do
    remote
    |> normalized_remote()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp normalized_remote(remote) do
    remote = remote |> String.trim() |> String.trim_trailing("/")

    cond do
      String.starts_with?(remote, ["/", "./", "../"]) ->
        "file:" <> Path.expand(remote)

      captures = Regex.named_captures(@scp_remote, remote) ->
        captures["user"] <>
          "@" <>
          String.downcase(captures["host"]) <>
          ":" <> String.replace_suffix(captures["path"], ".git", "")

      true ->
        normalize_uri(remote)
    end
  end

  defp normalize_uri(remote) do
    case URI.parse(remote) do
      %URI{scheme: "file", path: path} when is_binary(path) ->
        "file:" <> (path |> URI.decode() |> Path.expand())

      %URI{scheme: scheme, host: host, path: path} = uri
      when is_binary(scheme) and is_binary(host) and is_binary(path) ->
        %{
          uri
          | scheme: String.downcase(scheme),
            host: String.downcase(host),
            path: String.replace_suffix(path, ".git", "")
        }
        |> URI.to_string()

      _other ->
        remote
    end
  end

  defp report(object, identity, mirror, status, quarantine) do
    %{
      schema: @schema,
      status: status,
      remote: object.remote,
      commit: object.commit,
      remote_identity: identity,
      mirror: mirror,
      network: status in [:miss, :refreshed, :repaired],
      quarantine: quarantine
    }
  end

  defp with_duration({:ok, report}, started_at) do
    duration = System.monotonic_time() - started_at

    {:ok,
     Map.put(report, :duration_ms, System.convert_time_unit(duration, :native, :millisecond))}
  end

  defp with_duration(other, _started_at), do: other

  defp mirrors_root(state_root), do: Path.join([state_root, "cache", "git"])

  defp mirror_path(state_root, identity),
    do: Path.join(mirrors_root(state_root), identity <> ".git")

  defp file_url(path), do: "file://" <> Path.expand(path)

  defp mkdir_private(path) do
    with :ok <- File.mkdir_p(path), do: File.chmod(path, 0o700)
  end

  defp random_suffix,
    do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
