defmodule MixWorkspaceOps.Runtime do
  @moduledoc """
  Unique writable execution state and lease-safe lifecycle management.

  A semantic source context is a cache identity. An execution identity adds
  the target revision, target source digest, Mix environment and Mix target.
  Neither is a writable directory: every activation adds a random invocation
  id and receives its own private run root.
  """

  alias MixWorkspaceOps.Report

  @state_marker "mix_workspace_ops.state/v1\n"
  @runtime_schema "mix_workspace_ops.runtime/v2"
  @list_schema "mix_workspace_ops.state_list/v1"
  @gc_schema "mix_workspace_ops.state_gc/v1"
  @attempts 10
  @report_path_keys %{
    "root" => :root,
    "home" => :home,
    "mix_home" => :mix_home,
    "archives" => :archives,
    "hex_home" => :hex_home,
    "rebar_cache" => :rebar_cache,
    "tmp" => :tmp,
    "config_home" => :config_home,
    "source_lock" => :source_lock,
    "deps_path" => :deps_path,
    "build_root" => :build_root,
    "lockfile" => :lockfile
  }
  @publication_credentials ~w(
    GH_TOKEN
    GH_ENTERPRISE_TOKEN
    GITHUB_TOKEN
    GITHUB_ENTERPRISE_TOKEN
    GIT_ASKPASS
    GIT_CONFIG_GLOBAL
    GIT_CONFIG_SYSTEM
    GIT_CREDENTIAL_HELPER
    GIT_SSH
    GIT_SSH_COMMAND
    HEX_API_KEY
    HEX_API_KEY_READ
    HEX_API_KEY_WRITE
    NETRC
    SSH_ASKPASS
    SSH_ASKPASS_REQUIRE
    SSH_AGENT_PID
    SSH_AUTH_SOCK
  )

  @enforce_keys [
    :root,
    :run_id,
    :cache_identity,
    :execution_identity,
    :ownership,
    :lease_path,
    :metadata_path,
    :source_lock_digest,
    :allow_lock_mutation,
    :created_at
  ]
  defstruct [
    :root,
    :run_id,
    :cache_identity,
    :execution_identity,
    :ownership,
    :lease_path,
    :metadata_path,
    :source_lock_digest,
    :lockfile,
    :allow_lock_mutation,
    :created_at
  ]

  @type t :: %__MODULE__{
          root: String.t(),
          run_id: String.t(),
          cache_identity: String.t(),
          execution_identity: String.t(),
          ownership: :managed | :delegated,
          lease_path: String.t(),
          metadata_path: String.t(),
          source_lock_digest: String.t(),
          lockfile: String.t() | nil,
          allow_lock_mutation: boolean(),
          created_at: non_neg_integer()
        }

  @doc "Creates one leased, private run with no writable path shared with another invocation."
  @spec prepare(String.t(), String.t(), binary(), keyword()) ::
          {:ok, %{env: list(), report: map(), handle: t()}} | {:error, term()}
  def prepare(state_root, cache_identity, lock_bytes, opts \\ []) do
    state_root = Path.expand(state_root)
    ownership = Keyword.get(opts, :ownership, :managed)
    created_at = Keyword.get(opts, :now, System.system_time(:second))

    with :ok <- valid_ownership(ownership),
         :ok <- valid_identity(:cache_identity, cache_identity),
         {:ok, execution_inputs} <- execution_inputs(opts),
         execution_identity <- execution_identity(cache_identity, execution_inputs),
         :ok <- ensure_state_root(state_root),
         {:ok, root, run_id} <- create_run_root(state_root, execution_identity),
         handle <-
           handle(
             root,
             run_id,
             cache_identity,
             execution_identity,
             ownership,
             lock_bytes,
             Keyword.get(opts, :allow_lock_mutation, false),
             created_at
           ) do
      prepare_run(handle, lock_bytes, execution_inputs, opts)
    end
  end

  @doc "Finalizes the lock audit and durable run record. Safe to call before releasing the lease."
  @spec finish(t()) :: {:ok, map()} | {:error, term()}
  def finish(%__MODULE__{} = handle) do
    with {:ok, final_lock_digest} <- final_lock_digest(handle),
         lock_mutated = final_lock_digest != handle.source_lock_digest,
         finished_at = System.system_time(:second),
         status = finish_status(lock_mutated, handle.allow_lock_mutation),
         {:ok, metadata} <- read_metadata(handle.metadata_path),
         final =
           metadata
           |> Map.put("status", status)
           |> Map.put("finished_at", finished_at)
           |> Map.put("final_lock_digest", final_lock_digest)
           |> Map.put("lock_mutated", lock_mutated),
         :ok <- write_report_private(handle.metadata_path, final) do
      report = runtime_report(handle, final)

      if status == "rejected" do
        {:error,
         {:lock_mutation_not_allowed, handle.run_id, handle.source_lock_digest, final_lock_digest}}
      else
        {:ok, report}
      end
    end
  end

  @doc "Releases a run lease. The run remains as durable state until garbage collection."
  @spec release(t()) :: :ok | {:error, term()}
  def release(%__MODULE__{} = handle) do
    case File.rm(handle.lease_path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:runtime_lease_release, reason}}
    end
  end

  @doc "Lists every durable P4 run and whether its lease is currently live."
  @spec list(String.t()) :: {:ok, map()} | {:error, term()}
  def list(state_root) do
    state_root = Path.expand(state_root)

    case readable_state_root(state_root) do
      :ok ->
        with {:ok, runs} <- read_runs(state_root) do
          {:ok, state_report(state_root, runs, legacy_runtimes(state_root))}
        end

      :absent ->
        {:ok, state_report(state_root, [], [])}

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Lists or removes old, unleased P4 runs, including abandoned active records."
  @spec gc(String.t(), non_neg_integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def gc(state_root, older_than_seconds, opts \\ [])

  def gc(state_root, older_than_seconds, opts)
      when is_integer(older_than_seconds) and older_than_seconds >= 0 do
    now = Keyword.get(opts, :now, System.system_time(:second))
    dry_run? = Keyword.get(opts, :dry_run, false)

    with {:ok, state} <- list(state_root),
         candidates <-
           Enum.filter(state.runs, fn run ->
             not run.leased and is_integer(run.created_at) and
               run.created_at <= now - older_than_seconds
           end),
         {:ok, removed} <- maybe_remove_runs(candidates, state.state_root, dry_run?) do
      {:ok,
       %{
         schema: @gc_schema,
         state_root: state.state_root,
         older_than_seconds: older_than_seconds,
         dry_run: dry_run?,
         runs: Enum.map(removed, &Map.take(&1, [:run_id, :execution_identity, :root]))
       }}
    end
  end

  def gc(_state_root, older_than_seconds, _opts),
    do: {:error, {:invalid_gc_age, older_than_seconds}}

  @doc "Parses a GC age expressed in seconds or with an s/m/h/d suffix."
  @spec parse_age(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def parse_age(value) when is_binary(value) do
    case Regex.run(~r/^(\d+)([smhd]?)$/, value) do
      [_, amount, suffix] ->
        {number, ""} = Integer.parse(amount)
        {:ok, number * age_multiplier(suffix)}

      _other ->
        {:error, {:invalid_gc_age, value}}
    end
  end

  def parse_age(value), do: {:error, {:invalid_gc_age, value}}

  defp prepare_run(handle, lock_bytes, execution_inputs, opts) do
    result =
      with :ok <- write_lease(handle),
           {:ok, paths} <- create_state_directories(handle),
           :ok <-
             copy_archives(paths.archives, Keyword.get(opts, :archives_source, archives_source())),
           :ok <- write_private(Path.join(handle.root, "source.mix.lock"), lock_bytes),
           {:ok, lockfile} <- prepare_lockfile(handle, paths, lock_bytes),
           handle = %{handle | lockfile: lockfile},
           metadata <- initial_metadata(handle, execution_inputs, paths),
           :ok <- write_report_private(handle.metadata_path, metadata) do
        {:ok,
         %{
           env: runtime_environment(handle, paths),
           report: runtime_report(handle, metadata),
           handle: handle
         }}
      end

    case result do
      {:ok, _runtime} = ok ->
        ok

      error ->
        File.rm_rf(handle.root)
        error
    end
  end

  defp handle(
         root,
         run_id,
         cache_identity,
         execution_identity,
         ownership,
         lock_bytes,
         allow_lock_mutation,
         created_at
       ) do
    %__MODULE__{
      root: root,
      run_id: run_id,
      cache_identity: cache_identity,
      execution_identity: execution_identity,
      ownership: ownership,
      lease_path: Path.join(root, "lease.json"),
      metadata_path: Path.join(root, "runtime.json"),
      source_lock_digest: sha256(lock_bytes),
      allow_lock_mutation: allow_lock_mutation,
      created_at: created_at
    }
  end

  defp execution_inputs(opts) do
    keys = [:target_head, :target_source_digest, :mix_env, :mix_target]

    Enum.reduce_while(keys, {:ok, %{}}, fn key, {:ok, acc} ->
      case Keyword.fetch(opts, key) do
        {:ok, value} when is_binary(value) and value != "" ->
          {:cont, {:ok, Map.put(acc, key, value)}}

        {:ok, value} ->
          {:halt, {:error, {:invalid_runtime_input, key, value}}}

        :error ->
          {:halt, {:error, {:missing_runtime_input, key}}}
      end
    end)
  end

  defp execution_identity(cache_identity, inputs) do
    Report.encode(%{
      cache_identity: cache_identity,
      target_head: inputs.target_head,
      target_source_digest: inputs.target_source_digest,
      mix_env: inputs.mix_env,
      mix_target: inputs.mix_target
    })
    |> sha256()
  end

  defp valid_ownership(ownership) when ownership in [:managed, :delegated], do: :ok
  defp valid_ownership(ownership), do: {:error, {:unsupported_mix_state, ownership}}

  defp valid_identity(field, value) when is_binary(value) do
    if Regex.match?(~r/^[0-9a-f]{64}$/, value),
      do: :ok,
      else: {:error, {:invalid_runtime_identity, field, value}}
  end

  defp valid_identity(field, value), do: {:error, {:invalid_runtime_identity, field, value}}

  defp ensure_state_root(state_root) do
    marker = Path.join(state_root, ".mix_workspace_ops_state")

    if state_root == "/" do
      {:error, :state_root_must_not_be_root}
    else
      with :ok <- File.mkdir_p(state_root),
           :ok <- File.chmod(state_root, 0o700),
           :ok <- write_marker(marker) do
        mkdir_private(Path.join(state_root, "runs"))
      end
    end
  end

  defp write_marker(path) do
    case File.read(path) do
      {:ok, @state_marker} ->
        :ok

      {:ok, _other} ->
        {:error, {:state_root_marker_mismatch, path}}

      {:error, :enoent} ->
        install_marker(path)

      {:error, reason} ->
        {:error, {:state_root_marker, reason}}
    end
  end

  # An exclusive write exposes the empty file between open and write, which a
  # concurrent activation can misread as a corrupt marker. Link a fully written
  # private temporary into place instead: the directory entry appears atomically
  # and `File.ln/2` refuses to replace an existing marker.
  defp install_marker(path) do
    temporary = path <> ".tmp.#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"

    result =
      with :ok <- write_private(temporary, @state_marker) do
        case File.ln(temporary, path) do
          :ok -> :ok
          {:error, :eexist} -> write_marker(path)
          {:error, reason} -> {:error, {:state_root_marker, reason}}
        end
      end

    File.rm(temporary)
    result
  end

  defp create_run_root(state_root, execution_identity) do
    parent = Path.join([state_root, "runs", execution_identity])

    with :ok <- mkdir_private(parent) do
      create_invocation(parent, @attempts)
    end
  end

  defp create_invocation(_parent, 0), do: {:error, :runtime_invocation_collision}

  defp create_invocation(parent, attempts) do
    run_id = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    root = Path.join(parent, run_id)

    case File.mkdir(root) do
      :ok ->
        with :ok <- File.chmod(root, 0o700), do: {:ok, root, run_id}

      {:error, :eexist} ->
        create_invocation(parent, attempts - 1)

      {:error, reason} ->
        {:error, {:runtime_directory, reason}}
    end
  end

  defp write_lease(handle) do
    write_report_private(handle.lease_path, %{
      schema: "mix_workspace_ops.lease/v1",
      pid: System.pid(),
      run_id: handle.run_id,
      created_at: handle.created_at
    })
  end

  defp create_state_directories(handle) do
    names = ~w(home mix archives hex rebar tmp config)
    paths = Map.new(names, &{String.to_atom(&1), Path.join(handle.root, &1)})

    with :ok <- Enum.reduce_while(Map.values(paths), :ok, &mkdir_until_error/2),
         {:ok, managed} <- managed_directories(handle) do
      {:ok, Map.merge(paths, managed)}
    end
  end

  defp managed_directories(%{ownership: :delegated}), do: {:ok, %{}}

  defp managed_directories(%{ownership: :managed, root: root}) do
    paths = %{deps: Path.join(root, "deps"), build: Path.join(root, "_build")}

    with :ok <- Enum.reduce_while(Map.values(paths), :ok, &mkdir_until_error/2),
         do: {:ok, paths}
  end

  defp mkdir_until_error(path, :ok) do
    case mkdir_private(path) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  defp prepare_lockfile(%{ownership: :delegated}, _paths, _lock_bytes), do: {:ok, nil}

  defp prepare_lockfile(%{ownership: :managed, root: root}, _paths, lock_bytes) do
    path = Path.join(root, "mix.lock")
    with :ok <- write_private(path, lock_bytes), do: {:ok, path}
  end

  defp archives_source do
    mix_home = System.get_env("MIX_HOME") || Path.join(System.user_home!(), ".mix")
    mix_home |> Path.expand() |> Path.join("archives")
  end

  defp copy_archives(_destination, nil), do: :ok

  defp copy_archives(destination, source) do
    with :ok <- validate_archive_tree(source),
         {:ok, names} <- list_archives(source),
         :ok <- copy_archive_entries(names, source, destination) do
      validate_archive_tree(destination)
    end
  end

  defp list_archives(source) do
    case File.ls(source) do
      {:ok, names} -> {:ok, Enum.sort(names)}
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, {:runtime_archives, reason}}
    end
  end

  defp copy_archive_entries(names, source, destination) do
    Enum.reduce_while(names, :ok, fn name, :ok ->
      from = Path.join(source, name)
      to = Path.join(destination, name)

      case File.cp_r(from, to) do
        {:ok, _paths} -> {:cont, :ok}
        {:error, reason, _path} -> {:halt, {:error, {:runtime_archive_copy, reason}}}
      end
    end)
  end

  defp validate_archive_tree(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} ->
        :ok

      {:ok, %{type: :directory}} ->
        validate_archive_directory(path)

      {:ok, %{type: type}} ->
        {:error, {:unsafe_runtime_archive_entry, path, type}}

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, {:runtime_archives, reason}}
    end
  end

  defp validate_archive_directory(path) do
    case File.ls(path) do
      {:ok, names} -> validate_archive_entries(names, path)
      {:error, reason} -> {:error, {:runtime_archives, reason}}
    end
  end

  defp validate_archive_entries(names, path) do
    Enum.reduce_while(names, :ok, fn name, :ok ->
      case validate_archive_tree(Path.join(path, name)) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp runtime_environment(handle, paths) do
    base = [
      {"HOME", paths.home},
      {"XDG_CONFIG_HOME", paths.config},
      {"MIX_HOME", paths.mix},
      {"MIX_ARCHIVES", paths.archives},
      {"HEX_HOME", paths.hex},
      {"REBAR_CACHE_DIR", paths.rebar},
      {"TMPDIR", paths.tmp}
    ]

    managed =
      case handle.ownership do
        :managed ->
          [
            {"MIX_DEPS_PATH", paths.deps},
            {"MIX_BUILD_ROOT", paths.build},
            {"MIX_WORKSPACE_OPS_LOCKFILE", handle.lockfile}
          ]

        :delegated ->
          []
      end

    removed = Enum.map(publication_credential_keys(), &{&1, nil})
    non_interactive = [{"GCM_INTERACTIVE", "never"}, {"GIT_TERMINAL_PROMPT", "0"}]

    (base ++ managed ++ removed ++ non_interactive)
    |> Map.new()
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp publication_credential_keys do
    discovered =
      System.get_env()
      |> Map.keys()
      |> Enum.filter(&publication_credential?/1)

    Enum.sort(Enum.uniq(@publication_credentials ++ discovered))
  end

  defp publication_credential?(name) do
    (String.starts_with?(name, "HEX_") and
       String.contains?(name, ["KEY", "TOKEN", "SECRET", "PASSWORD", "CREDENTIAL", "AUTH"])) or
      Regex.match?(~r/^GIT_CONFIG_(COUNT|KEY_\d+|VALUE_\d+)$/, name)
  end

  defp initial_metadata(handle, inputs, paths) do
    %{
      schema: @runtime_schema,
      run_id: handle.run_id,
      cache_identity: handle.cache_identity,
      execution_identity: handle.execution_identity,
      ownership: handle.ownership,
      status: "active",
      created_at: handle.created_at,
      finished_at: nil,
      target_head: inputs.target_head,
      target_source_digest: inputs.target_source_digest,
      mix_env: inputs.mix_env,
      mix_target: inputs.mix_target,
      source_lock_digest: handle.source_lock_digest,
      final_lock_digest: nil,
      lock_mutated: false,
      allow_lock_mutation: handle.allow_lock_mutation,
      paths: report_paths(handle, paths)
    }
  end

  defp report_paths(handle, paths) do
    base = %{
      root: handle.root,
      home: paths.home,
      mix_home: paths.mix,
      archives: paths.archives,
      hex_home: paths.hex,
      rebar_cache: paths.rebar,
      tmp: paths.tmp,
      config_home: paths.config,
      source_lock: Path.join(handle.root, "source.mix.lock")
    }

    case handle.ownership do
      :managed ->
        Map.merge(base, %{
          deps_path: paths.deps,
          build_root: paths.build,
          lockfile: handle.lockfile
        })

      :delegated ->
        base
    end
  end

  defp runtime_report(handle, metadata) do
    paths = Map.get(metadata, "paths", Map.get(metadata, :paths, %{}))

    %{
      schema: @runtime_schema,
      ownership: handle.ownership,
      digest: handle.cache_identity,
      cache_identity: handle.cache_identity,
      execution_identity: handle.execution_identity,
      invocation_id: handle.run_id,
      root: handle.root,
      lease: handle.lease_path,
      metadata: handle.metadata_path,
      created_at: value(metadata, "created_at"),
      finished_at: value(metadata, "finished_at"),
      status: value(metadata, "status"),
      source_lock_digest: handle.source_lock_digest,
      final_lock_digest: value(metadata, "final_lock_digest"),
      lock_mutated: value(metadata, "lock_mutated"),
      allow_lock_mutation: handle.allow_lock_mutation
    }
    |> Map.merge(normalize_report_paths(paths))
  end

  defp normalize_report_paths(paths) do
    Map.new(paths, fn {key, value} -> {path_key(key), value} end)
  end

  defp path_key(key) when is_atom(key), do: key
  defp path_key(key) when is_binary(key), do: Map.fetch!(@report_path_keys, key)

  defp final_lock_digest(%{lockfile: nil, source_lock_digest: digest}), do: {:ok, digest}

  defp final_lock_digest(%{lockfile: path}) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, sha256(bytes)}
      {:error, reason} -> {:error, {:runtime_final_lock, reason}}
    end
  end

  defp finish_status(true, false), do: "rejected"
  defp finish_status(_mutated, _allowed), do: "complete"

  defp readable_state_root(state_root) do
    marker = Path.join(state_root, ".mix_workspace_ops_state")

    case File.read(marker) do
      {:ok, @state_marker} ->
        :ok

      {:error, :enoent} ->
        if File.exists?(state_root),
          do: {:error, {:state_root_marker_missing, marker}},
          else: :absent

      {:ok, _other} ->
        {:error, {:state_root_marker_mismatch, marker}}

      {:error, reason} ->
        {:error, {:state_root_marker, reason}}
    end
  end

  defp state_report(state_root, runs, legacy_runtimes) do
    %{
      schema: @list_schema,
      state_root: state_root,
      runs: runs,
      legacy_runtimes: legacy_runtimes
    }
  end

  defp read_runs(state_root) do
    paths = Path.wildcard(Path.join([state_root, "runs", "*", "*", "runtime.json"]))

    Enum.reduce_while(Enum.sort(paths), {:ok, []}, fn path, {:ok, acc} ->
      case read_run(path) do
        {:ok, run} -> {:cont, {:ok, [run | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, runs} -> {:ok, Enum.reverse(runs)}
      error -> error
    end)
  end

  defp read_run(metadata_path) do
    root = Path.dirname(metadata_path)

    with {:ok, metadata} <- read_metadata(metadata_path),
         true <-
           metadata["schema"] == @runtime_schema || {:error, {:runtime_schema, metadata_path}},
         {:ok, lease} <- lease_status(Path.join(root, "lease.json")) do
      {:ok,
       %{
         run_id: metadata["run_id"],
         cache_identity: metadata["cache_identity"],
         execution_identity: metadata["execution_identity"],
         ownership: metadata["ownership"],
         status: metadata["status"],
         created_at: metadata["created_at"],
         finished_at: null_to_nil(metadata["finished_at"]),
         source_lock_digest: metadata["source_lock_digest"],
         final_lock_digest: null_to_nil(metadata["final_lock_digest"]),
         lock_mutated: metadata["lock_mutated"],
         allow_lock_mutation: metadata["allow_lock_mutation"],
         leased: lease.active,
         lease_pid: lease.pid,
         root: root
       }}
    end
  end

  defp read_metadata(path) do
    with {:ok, bytes} <- File.read(path), {:ok, metadata} <- decode_json(bytes, path) do
      {:ok, metadata}
    else
      {:error, reason} -> {:error, {:runtime_metadata, path, reason}}
    end
  end

  defp decode_json(bytes, path) do
    case :json.decode(bytes) do
      value when is_map(value) -> {:ok, value}
      _other -> {:error, :not_an_object}
    end
  rescue
    error -> {:error, {:invalid_json, path, Exception.message(error)}}
  end

  defp lease_status(path) do
    case File.read(path) do
      {:ok, bytes} ->
        with {:ok, lease} <- decode_json(bytes, path) do
          pid = lease["pid"]
          {:ok, %{active: process_alive?(pid), pid: pid}}
        end

      {:error, :enoent} ->
        {:ok, %{active: false, pid: nil}}

      {:error, reason} ->
        {:error, {:runtime_lease, path, reason}}
    end
  end

  defp process_alive?(pid) when is_binary(pid) do
    Regex.match?(~r/^\d+$/, pid) and
      (pid == System.pid() or File.dir?(Path.join("/proc", pid)))
  end

  defp process_alive?(_pid), do: false

  defp maybe_remove_runs(runs, _state_root, true), do: {:ok, runs}

  defp maybe_remove_runs(runs, state_root, false) do
    Enum.reduce_while(runs, {:ok, []}, fn run, {:ok, removed} ->
      case remove_run(run.root, state_root) do
        :ok -> {:cont, {:ok, [run | removed]}}
        :leased -> {:cont, {:ok, removed}}
        error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, removed} -> {:ok, Enum.reverse(removed)}
      error -> error
    end)
  end

  defp remove_run(root, state_root) do
    runs_root = Path.join(state_root, "runs")
    root = Path.expand(root)

    safe? =
      inside?(root, runs_root) and ordinary_directory?(runs_root) and
        ordinary_directory?(Path.dirname(root)) and ordinary_directory?(root) and
        ordinary_regular?(Path.join(root, "runtime.json"))

    if safe?,
      do: remove_unleased_run(root),
      else: {:error, {:unsafe_runtime_gc_target, root}}
  end

  defp remove_unleased_run(root) do
    case lease_status(Path.join(root, "lease.json")) do
      {:ok, %{active: true}} -> :leased
      {:ok, %{active: false}} -> remove_run_directory(root)
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove_run_directory(root) do
    case File.rm_rf(root) do
      {:ok, _removed} ->
        File.rmdir(Path.dirname(root))
        :ok

      {:error, reason, path} ->
        {:error, {:runtime_gc, path, reason}}
    end
  end

  defp legacy_runtimes(state_root) do
    state_root
    |> Path.join("runtimes/*")
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
    |> Enum.sort()
  end

  defp age_multiplier(""), do: 1
  defp age_multiplier("s"), do: 1
  defp age_multiplier("m"), do: 60
  defp age_multiplier("h"), do: 60 * 60
  defp age_multiplier("d"), do: 24 * 60 * 60

  defp mkdir_private(path) do
    with :ok <- File.mkdir_p(path), do: File.chmod(path, 0o700)
  end

  defp write_private(path, bytes) do
    with :ok <- File.write(path, bytes, [:exclusive, :sync]), do: File.chmod(path, 0o600)
  end

  defp write_report_private(path, value) do
    with :ok <- Report.write(path, value), do: File.chmod(path, 0o600)
  end

  defp ordinary_directory?(path) do
    match?({:ok, %{type: :directory}}, File.lstat(path))
  end

  defp ordinary_regular?(path) do
    match?({:ok, %{type: :regular}}, File.lstat(path))
  end

  defp value(metadata, key) do
    atom_key =
      case key do
        "created_at" -> :created_at
        "finished_at" -> :finished_at
        "status" -> :status
        "final_lock_digest" -> :final_lock_digest
        "lock_mutated" -> :lock_mutated
      end

    metadata
    |> Map.get(key, Map.get(metadata, atom_key))
    |> null_to_nil()
  end

  defp null_to_nil(:null), do: nil
  defp null_to_nil(value), do: value

  defp inside?(path, root) do
    path = Path.expand(path)
    root = Path.expand(root)
    path == root or String.starts_with?(path, root <> "/")
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
