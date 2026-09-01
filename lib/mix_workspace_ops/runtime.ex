defmodule MixWorkspaceOps.Runtime do
  @moduledoc """
  Reusable Mix execution contexts and lease-safe transient state.

  Large writable state is addressed by exact context rather than invocation:
  dependency sources have one stable external path and a project build has one
  stable external path. Mix supplies the cross-process locks for those exact
  paths. Each activation allocates only private home, configuration, temporary,
  lock-audit and report state.
  """

  alias Mix.Sync.Lock, as: SyncLock
  alias MixWorkspaceOps.{GitCache, Lockfile, Report}

  @state_marker "mix_workspace_ops.state/v1\n"
  @runtime_schema "mix_workspace_ops.runtime/v4"
  @list_schema "mix_workspace_ops.state_list/v3"
  @gc_schema "mix_workspace_ops.state_gc/v3"
  @access_marker ".mwo-access"
  @metadata_atom_keys %{
    "created_at" => :created_at,
    "finished_at" => :finished_at,
    "status" => :status,
    "binding_root" => :binding_root,
    "toolchain" => :toolchain,
    "deps_present" => :deps_present,
    "build_present" => :build_present,
    "cache_objects" => :cache_objects,
    "final_lock_digest" => :final_lock_digest,
    "lock_mutated" => :lock_mutated
  }
  @attempts 10
  @report_path_keys %{
    "root" => :root,
    "home" => :home,
    "mix_home" => :mix_home,
    "archives" => :archives,
    "xdg_cache_home" => :xdg_cache_home,
    "hex_cache" => :hex_cache,
    "rebar_cache" => :rebar_cache,
    "tmp" => :tmp,
    "config_home" => :config_home,
    "source_lock" => :source_lock,
    "deps_path" => :deps_path,
    "build_root" => :build_root,
    "build_path" => :build_path,
    "mix_exs" => :mix_exs,
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
    :state_root,
    :run_id,
    :cache_identity,
    :dependency_identity,
    :execution_identity,
    :binding_root,
    :ownership,
    :lease_path,
    :metadata_path,
    :source_lock_digest,
    :operational_lock_digest,
    :allow_lock_mutation,
    :created_at
  ]
  defstruct [
    :root,
    :state_root,
    :run_id,
    :cache_identity,
    :dependency_identity,
    :execution_identity,
    :binding_root,
    :ownership,
    :lease_path,
    :metadata_path,
    :source_lock_digest,
    :operational_lock_digest,
    :lockfile,
    :allow_lock_mutation,
    :created_at
  ]

  @type t :: %__MODULE__{
          root: String.t(),
          state_root: String.t(),
          run_id: String.t(),
          cache_identity: String.t(),
          dependency_identity: String.t(),
          execution_identity: String.t(),
          binding_root: String.t(),
          ownership: :managed | :delegated,
          lease_path: String.t(),
          metadata_path: String.t(),
          source_lock_digest: String.t(),
          operational_lock_digest: String.t(),
          lockfile: String.t() | nil,
          allow_lock_mutation: boolean(),
          created_at: non_neg_integer()
        }

  @doc "Binds one invocation to reusable dependency/build paths and private transient state."
  @spec prepare(String.t(), String.t(), binary(), keyword()) ::
          {:ok, %{env: list(), report: map(), handle: t()}} | {:error, term()}
  def prepare(state_root, cache_identity, lock_bytes, opts \\ []) do
    state_root = Path.expand(state_root)
    ownership = Keyword.get(opts, :ownership, :managed)
    created_at = Keyword.get(opts, :now, System.system_time(:second))

    with :ok <- valid_ownership(ownership),
         :ok <- valid_identity(:cache_identity, cache_identity),
         {:ok, execution_inputs} <- execution_inputs(Keyword.put_new(opts, :project_identity, cache_identity)),
         {:ok, operational_lock} <- operational_lock(lock_bytes, opts),
         dependency_identity <- dependency_identity(cache_identity, operational_lock, execution_inputs),
         execution_identity <- execution_identity(dependency_identity, execution_inputs),
         :ok <- ensure_state_root(state_root),
         {:ok, root, run_id} <- create_run_root(state_root, execution_identity),
         identities <- %{
           cache: cache_identity,
           dependency: dependency_identity,
           execution: execution_identity
         },
         handle <-
           handle(
             root,
             state_root,
             identities,
             lock_bytes,
             operational_lock,
             %{
               run_id: run_id,
               binding_root: execution_inputs.binding_root,
               ownership: ownership,
               allow_lock_mutation: Keyword.get(opts, :allow_lock_mutation, false),
               created_at: created_at
             }
           ) do
      prepare_run(handle, lock_bytes, operational_lock, execution_inputs, opts)
    end
  end

  @doc "Finalizes the lock audit and durable run record. Safe to call before releasing the lease."
  @spec finish(t()) :: {:ok, map()} | {:error, term()}
  def finish(%__MODULE__{} = handle) do
    with {:ok, final_lock_digest} <- final_lock_digest(handle),
         lock_mutated = final_lock_digest != handle.operational_lock_digest,
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
         {:lock_mutation_not_allowed, handle.run_id, handle.operational_lock_digest,
          final_lock_digest}}
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

  @doc "Lists every durable run and whether its lease is currently live."
  @spec list(String.t()) :: {:ok, map()} | {:error, term()}
  def list(state_root) do
    state_root = Path.expand(state_root)

    case readable_state_root(state_root) do
      :ok ->
        with {:ok, runs} <- read_runs(state_root) do
          {:ok,
           state_report(
             state_root,
             runs,
             read_contexts(state_root, runs),
             legacy_runtimes(state_root)
           )}
        end

      :absent ->
        {:ok, state_report(state_root, [], %{deps: [], builds: []}, [])}

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Lists or removes old, unleased runs, including abandoned active records."
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
         context_candidates <- context_candidates(state.contexts, now, older_than_seconds),
         {:ok, removed} <- maybe_remove_runs(candidates, state.state_root, dry_run?),
         {:ok, removed_contexts} <-
           maybe_remove_contexts(context_candidates, state.state_root, dry_run?) do
      {:ok,
       %{
         schema: @gc_schema,
         state_root: state.state_root,
         older_than_seconds: older_than_seconds,
         dry_run: dry_run?,
         runs: Enum.map(removed, &Map.take(&1, [:run_id, :execution_identity, :root])),
         contexts: removed_contexts
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

  defp prepare_run(handle, lock_bytes, operational_lock, execution_inputs, opts) do
    paths = runtime_paths(handle)

    result =
      with :ok <- write_lease(handle),
           reservation <- initial_metadata(handle, execution_inputs, paths, empty_cache_objects()),
           :ok <- write_report_private(handle.metadata_path, reservation),
           {:ok, paths} <- create_state_directories(paths, handle.created_at),
           :ok <-
             copy_archives(paths.archives, Keyword.get(opts, :archives_source, archives_source())),
           {:ok, cache_objects} <- prepare_git_transport(handle, lock_bytes, paths, opts),
           :ok <- write_mix_wrapper(paths.mix_exs),
           :ok <- write_private(Path.join(handle.root, "source.mix.lock"), lock_bytes),
           {:ok, lockfile} <- prepare_lockfile(handle, paths, operational_lock),
           handle = %{
             handle
             | lockfile: lockfile,
               operational_lock_digest: lock_digest(operational_lock)
           },
           metadata <- initial_metadata(handle, execution_inputs, paths, cache_objects),
           :ok <- write_report_private(handle.metadata_path, metadata) do
        {:ok,
         %{
           env: runtime_environment(handle, paths, cache_objects),
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

  defp handle(root, state_root, identities, lock_bytes, operational_lock, invocation) do
    %__MODULE__{
      root: root,
      state_root: state_root,
      run_id: invocation.run_id,
      cache_identity: identities.cache,
      dependency_identity: identities.dependency,
      execution_identity: identities.execution,
      binding_root: invocation.binding_root,
      ownership: invocation.ownership,
      lease_path: Path.join(root, "lease.json"),
      metadata_path: Path.join(root, "runtime.json"),
      source_lock_digest: lock_digest(lock_bytes),
      operational_lock_digest: lock_digest(operational_lock),
      allow_lock_mutation: invocation.allow_lock_mutation,
      created_at: invocation.created_at
    }
  end

  defp execution_inputs(opts) do
    keys = [:target_head, :target_source_digest, :mix_env, :mix_target, :binding_root]

    with {:ok, inputs} <-
           Enum.reduce_while(keys, {:ok, %{}}, fn key, {:ok, acc} ->
             case runtime_input(opts, key) do
               {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
               {:error, _reason} = error -> {:halt, error}
             end
           end) do
      project_identity = Keyword.get(opts, :project_identity)

      if is_binary(project_identity) and project_identity != "",
        do: {:ok, Map.put(inputs, :project_identity, project_identity)},
        else: {:error, {:invalid_runtime_input, :project_identity, project_identity}}
    end
  end

  defp runtime_input(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) and value != "" ->
        {:ok, if(key == :binding_root, do: Path.expand(value), else: value)}

      {:ok, value} ->
        {:error, {:invalid_runtime_input, key, value}}

      :error ->
        {:error, {:missing_runtime_input, key}}
    end
  end

  defp dependency_identity(cache_identity, operational_lock, inputs) do
    Report.encode(%{
      version: 4,
      source_fingerprint: cache_identity,
      operational_lock_digest: lock_digest(operational_lock),
      mix_env: inputs.mix_env,
      mix_target: inputs.mix_target,
      toolchain: toolchain()
    })
    |> sha256()
  end

  defp execution_identity(dependency_identity, inputs) do
    Report.encode(%{
      version: 4,
      project_identity: inputs.project_identity,
      dependency_identity: dependency_identity,
      mix_env: inputs.mix_env,
      mix_target: inputs.mix_target,
      toolchain: toolchain()
    })
    |> sha256()
  end

  defp toolchain do
    mix_version = :mix |> Application.spec(:vsn) |> to_string()
    "elixir-#{System.version()}-otp-#{:erlang.system_info(:otp_release)}-mix-#{mix_version}"
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
      process_start: process_start(System.pid()),
      run_id: handle.run_id,
      created_at: handle.created_at
    })
  end

  defp runtime_paths(handle) do
    mix_cache = Path.join([handle.state_root, "cache", "mix", sha256(toolchain())])

    %{
      home: Path.join(handle.root, "home"),
      tmp: Path.join(handle.root, "tmp"),
      config: Path.join(handle.root, "config"),
      mix_exs: Path.join(handle.root, "mix.exs"),
      xdg_cache: Path.join([handle.state_root, "cache", "xdg"]),
      hex_cache: Path.join([handle.state_root, "cache", "xdg", "hex"]),
      rebar: Path.join([handle.state_root, "cache", "rebar"]),
      mix: mix_cache,
      archives: Path.join(mix_cache, "archives"),
      deps: Path.join([handle.state_root, "contexts", "deps", handle.dependency_identity]),
      build: Path.join([handle.state_root, "contexts", "build", handle.execution_identity])
    }
    |> Map.merge(%{deps_present: false, build_present: false})
  end

  defp create_state_directories(paths, timestamp) do
    ordinary_paths =
      paths
      |> Map.take([:home, :tmp, :config, :xdg_cache, :hex_cache, :rebar, :mix, :archives])
      |> Map.values()

    with :ok <- Enum.reduce_while(ordinary_paths, :ok, &mkdir_until_error/2),
         {:ok, deps_present} <- prepare_context(paths.deps, timestamp),
         {:ok, build_present} <- prepare_context(paths.build, timestamp) do
      {:ok, Map.merge(paths, %{deps_present: deps_present, build_present: build_present})}
    end
  end

  defp prepare_context(path, timestamp) do
    SyncLock.with_lock(context_lock(path), fn ->
      hit = populated_directory?(path)

      with :ok <- mkdir_private(path),
           :ok <- touch_context(path, timestamp) do
        {:ok, hit}
      end
    end)
  end

  defp populated_directory?(path) do
    case File.ls(path) do
      {:ok, names} -> Enum.any?(names, &(&1 != @access_marker))
      _empty_or_unreadable -> false
    end
  end

  defp touch_context(path, timestamp) do
    marker = Path.join(path, @access_marker)

    with :ok <- File.write(marker, Integer.to_string(timestamp) <> "\n", [:sync]),
         do: File.chmod(marker, 0o600)
  end

  defp mkdir_until_error(path, :ok) do
    case mkdir_private(path) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  defp prepare_lockfile(%{root: root}, _paths, lock_bytes) do
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
         :ok <- copy_archives_locked(destination, source) do
      validate_archive_tree(destination)
    end
  end

  defp copy_archives_locked(destination, source) do
    SyncLock.with_lock("mix_workspace_ops:archives:" <> destination, fn ->
      with {:ok, names} <- list_archives(source),
           do: copy_archive_entries(names, source, destination)
    end)
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

      case install_archive_entry(from, to) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp install_archive_entry(from, to) do
    if File.exists?(to) do
      validate_archive_tree(to)
    else
      suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
      temporary = to <> ".tmp." <> suffix

      result =
        case File.cp_r(from, temporary) do
          {:ok, _paths} -> install_copied_archive(temporary, to)
          {:error, reason, _path} -> {:error, {:runtime_archive_copy, reason}}
        end

      File.rm_rf(temporary)
      result
    end
  end

  defp install_copied_archive(temporary, destination) do
    with :ok <- validate_archive_tree(temporary) do
      case File.rename(temporary, destination) do
        :ok -> :ok
        {:error, :eexist} -> validate_archive_tree(destination)
        {:error, reason} -> {:error, {:runtime_archive_install, reason}}
      end
    end
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

  defp prepare_git_transport(handle, lock_bytes, paths, opts) do
    if Keyword.get(opts, :prepare_objects, false) do
      managed_sources = Keyword.get(opts, :managed_sources, %{})

      with {:ok, objects} <- GitCache.objects_from_lock(lock_bytes, managed_sources),
           {:ok, git} <- prepare_git_objects(handle, paths, objects, opts) do
        {:ok, %{git: git, git_env: GitCache.environment(git)}}
      end
    else
      {:ok, empty_cache_objects()}
    end
  end

  defp empty_cache_objects, do: %{git: [], git_env: []}

  defp write_mix_wrapper(path) do
    contents = """
    root = System.fetch_env!("MIX_WORKSPACE_OPS_PROJECT_ROOT") |> Path.expand()
    current = File.cwd!() |> Path.expand()

    if current == root do
      bootstrap = System.fetch_env!("MIX_WORKSPACE_OPS_BOOTSTRAP")
      Code.require_file(bootstrap)
      Code.compile_file(Path.join(root, "mix.exs"))
    else
      Code.compile_file(Path.join(current, "mix.exs"))
    end
    """

    write_private(path, contents)
  end

  defp operational_lock(lock_bytes, opts) do
    Lockfile.project_path_apps(lock_bytes, Keyword.get(opts, :path_apps, []))
  end

  defp prepare_git_objects(handle, paths, objects, opts) do
    git_opts = [env: cache_command_environment(paths)]

    map_objects(objects, opts, fn object ->
      GitCache.ensure(handle.state_root, object, git_opts)
    end)
  end

  defp map_objects(objects, opts, function) do
    concurrency = Keyword.get(opts, :cache_concurrency, System.schedulers_online())

    objects
    |> Task.async_stream(function,
      max_concurrency: max(1, concurrency),
      ordered: true,
      timeout: Keyword.get(opts, :cache_timeout, 120_000)
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:ok, report}}, {:ok, reports} -> {:cont, {:ok, [report | reports]}}
      {:ok, {:error, reason}}, _acc -> {:halt, {:error, reason}}
      {:exit, reason}, _acc -> {:halt, {:error, {:cache_task_exit, reason}}}
    end)
    |> case do
      {:ok, reports} -> {:ok, Enum.reverse(reports)}
      error -> error
    end
  end

  defp runtime_environment(handle, paths, cache_objects) do
    base = [
      {"HOME", paths.home},
      {"XDG_CONFIG_HOME", paths.config},
      {"XDG_CACHE_HOME", paths.xdg_cache},
      {"MIX_XDG", "1"},
      {"MIX_HOME", paths.mix},
      {"MIX_ARCHIVES", paths.archives},
      {"HEX_HOME", nil},
      {"REBAR_CACHE_DIR", paths.rebar},
      {"TMPDIR", paths.tmp},
      {"MIX_DEPS_PATH", paths.deps},
      {"MIX_BUILD_PATH", paths.build},
      {"MIX_EXS", paths.mix_exs},
      {"MIX_WORKSPACE_OPS_PROJECT_ROOT", handle.binding_root},
      {"MIX_WORKSPACE_OPS_LOCKFILE", handle.lockfile}
    ]

    removed = Enum.map(publication_credential_keys(), &{&1, nil})
    non_interactive = [{"GCM_INTERACTIVE", "never"}, {"GIT_TERMINAL_PROMPT", "0"}]

    (base ++ removed ++ non_interactive ++ cache_objects.git_env)
    |> Map.new()
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp cache_command_environment(paths) do
    base = [
      {"HOME", paths.home},
      {"XDG_CONFIG_HOME", paths.config},
      {"XDG_CACHE_HOME", paths.xdg_cache},
      {"MIX_XDG", "1"},
      {"MIX_HOME", paths.mix},
      {"MIX_ARCHIVES", paths.archives},
      {"HEX_HOME", nil},
      {"HEX_NO_UPDATE_CHECK", "1"},
      {"ERL_AFLAGS", "+S 1:1"},
      {"GCM_INTERACTIVE", "never"},
      {"GIT_TERMINAL_PROMPT", "0"}
    ]

    removed = Enum.map(publication_credential_keys(), &{&1, nil})
    (base ++ removed) |> Map.new() |> Enum.sort_by(&elem(&1, 0))
  end

  defp publication_credential_keys do
    discovered =
      System.get_env()
      |> Map.keys()
      |> Enum.filter(&publication_credential?/1)

    Enum.sort(Enum.uniq(@publication_credentials ++ discovered))
  end

  defp publication_credential?(name) do
    explicit_secret_name?(name) or
      Regex.match?(
        ~r/(^|_)(TOKEN|SECRET|PASSWORD|PRIVATE_KEY|API_KEY|AUTH_CODE|CREDENTIAL)(_|$)/,
        name
      ) or
      Regex.match?(~r/(^|_)OAUTH(_|$)/, name) or
      Regex.match?(~r/^GIT_CONFIG_(COUNT|KEY_\d+|VALUE_\d+)$/, name)
  end

  defp explicit_secret_name?(name), do: name in @publication_credentials

  defp initial_metadata(handle, inputs, paths, cache_objects) do
    %{
      schema: @runtime_schema,
      run_id: handle.run_id,
      cache_identity: handle.cache_identity,
      dependency_identity: handle.dependency_identity,
      execution_identity: handle.execution_identity,
      ownership: handle.ownership,
      status: "active",
      created_at: handle.created_at,
      finished_at: nil,
      target_head: inputs.target_head,
      target_source_digest: inputs.target_source_digest,
      binding_root: inputs.binding_root,
      mix_env: inputs.mix_env,
      mix_target: inputs.mix_target,
      toolchain: toolchain(),
      deps_present: paths.deps_present,
      build_present: paths.build_present,
      cache_objects: Map.drop(cache_objects, [:git_env]),
      source_lock_digest: handle.source_lock_digest,
      operational_lock_digest: handle.operational_lock_digest,
      final_lock_digest: nil,
      lock_mutated: false,
      allow_lock_mutation: handle.allow_lock_mutation,
      paths: report_paths(handle, paths)
    }
  end

  defp report_paths(handle, paths) do
    %{
      root: handle.root,
      home: paths.home,
      mix_home: paths.mix,
      archives: paths.archives,
      xdg_cache_home: paths.xdg_cache,
      hex_cache: paths.hex_cache,
      rebar_cache: paths.rebar,
      tmp: paths.tmp,
      config_home: paths.config,
      source_lock: Path.join(handle.root, "source.mix.lock"),
      deps_path: paths.deps,
      build_root: paths.build,
      build_path: paths.build,
      mix_exs: paths.mix_exs,
      lockfile: handle.lockfile
    }
  end

  defp runtime_report(handle, metadata) do
    paths = Map.get(metadata, "paths", Map.get(metadata, :paths, %{}))

    %{
      schema: @runtime_schema,
      ownership: handle.ownership,
      digest: handle.cache_identity,
      cache_identity: handle.cache_identity,
      dependency_identity: handle.dependency_identity,
      execution_identity: handle.execution_identity,
      invocation_id: handle.run_id,
      root: handle.root,
      lease: handle.lease_path,
      metadata: handle.metadata_path,
      created_at: value(metadata, "created_at"),
      finished_at: value(metadata, "finished_at"),
      status: value(metadata, "status"),
      binding_root: value(metadata, "binding_root"),
      toolchain: value(metadata, "toolchain"),
      deps_present: value(metadata, "deps_present"),
      build_present: value(metadata, "build_present"),
      cache_objects: value(metadata, "cache_objects"),
      source_lock_digest: handle.source_lock_digest,
      operational_lock_digest: handle.operational_lock_digest,
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

  defp final_lock_digest(%{lockfile: nil, operational_lock_digest: digest}), do: {:ok, digest}

  defp final_lock_digest(%{lockfile: path}) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, lock_digest(bytes)}
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

  defp state_report(state_root, runs, contexts, legacy_runtimes) do
    %{
      schema: @list_schema,
      state_root: state_root,
      runs: runs,
      contexts: contexts,
      legacy_runtimes: legacy_runtimes
    }
  end

  defp read_contexts(state_root, runs) do
    leased_dependencies =
      runs
      |> Enum.filter(& &1.leased)
      |> Enum.map(& &1.dependency_identity)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    leased_builds =
      runs
      |> Enum.filter(& &1.leased)
      |> Enum.map(& &1.execution_identity)
      |> MapSet.new()

    %{
      deps:
        context_rows(
          Path.join([state_root, "contexts", "deps"]),
          :deps,
          leased_dependencies
        ),
      builds:
        context_rows(
          Path.join([state_root, "contexts", "build"]),
          :build,
          leased_builds
        )
    }
  end

  defp context_rows(parent, kind, leased) do
    parent
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.flat_map(fn path ->
      identity = Path.basename(path)

      if Regex.match?(~r/^[0-9a-f]{64}$/, identity) and ordinary_directory?(path) do
        [
          %{
            kind: kind,
            identity: identity,
            path: path,
            last_used_at: context_last_used(path),
            leased: MapSet.member?(leased, identity)
          }
        ]
      else
        []
      end
    end)
  end

  defp context_last_used(path) do
    marker = Path.join(path, @access_marker)

    with {:ok, bytes} <- File.read(marker),
         {timestamp, ""} <- bytes |> String.trim() |> Integer.parse() do
      timestamp
    else
      _missing_or_malformed -> nil
    end
  end

  defp context_candidates(contexts, now, older_than_seconds) do
    contexts
    |> Map.values()
    |> List.flatten()
    |> Enum.filter(fn context ->
      not context.leased and is_integer(context.last_used_at) and
        context.last_used_at <= now - older_than_seconds
    end)
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
           metadata["schema"] in [@runtime_schema, "mix_workspace_ops.runtime/v3", "mix_workspace_ops.runtime/v2"] ||
             {:error, {:runtime_schema, metadata_path}},
         {:ok, lease} <- lease_status(Path.join(root, "lease.json")) do
      {:ok,
       %{
         run_id: metadata["run_id"],
         cache_identity: metadata["cache_identity"],
         dependency_identity: null_to_nil(metadata["dependency_identity"]),
         execution_identity: metadata["execution_identity"],
         ownership: metadata["ownership"],
         status: metadata["status"],
         created_at: metadata["created_at"],
         finished_at: null_to_nil(metadata["finished_at"]),
         source_lock_digest: metadata["source_lock_digest"],
         operational_lock_digest:
           null_to_nil(metadata["operational_lock_digest"]) || metadata["source_lock_digest"],
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

          {:ok,
           %{
             active: process_alive?(pid, null_to_nil(lease["process_start"])),
             pid: pid
           }}
        end

      {:error, :enoent} ->
        {:ok, %{active: false, pid: nil}}

      {:error, reason} ->
        {:error, {:runtime_lease, path, reason}}
    end
  end

  defp process_alive?(pid, expected_start) when is_binary(pid) do
    Regex.match?(~r/^\d+$/, pid) and
      case expected_start do
        nil -> pid == System.pid() or File.dir?(Path.join("/proc", pid))
        expected -> process_start(pid) == expected
      end
  end

  defp process_alive?(_pid, _expected_start), do: false

  defp process_start(pid) do
    path = Path.join(["/proc", pid, "stat"])

    with {:ok, stat} <- File.read(path),
         [_command, fields] <- String.split(stat, ") ", parts: 2),
         values <- String.split(fields),
         value when is_binary(value) <- Enum.at(values, 19) do
      value
    else
      _unavailable -> nil
    end
  end

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

  defp maybe_remove_contexts(contexts, _state_root, true), do: {:ok, contexts}

  defp maybe_remove_contexts(contexts, state_root, false) do
    Enum.reduce_while(contexts, {:ok, []}, fn context, {:ok, removed} ->
      case remove_context(context, state_root) do
        :ok -> {:cont, {:ok, [context | removed]}}
        :leased -> {:cont, {:ok, removed}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, removed} -> {:ok, Enum.reverse(removed)}
      error -> error
    end
  end

  defp remove_context(context, state_root) do
    parent = context_parent(state_root, context.kind)
    path = Path.expand(context.path)

    if safe_context_target?(context, parent, path) do
      SyncLock.with_lock(context_lock(path), fn ->
        remove_context_locked(context, state_root, path)
      end)
    else
      {:error, {:unsafe_runtime_context_gc_target, path}}
    end
  end

  defp context_parent(state_root, :deps), do: Path.join([state_root, "contexts", "deps"])
  defp context_parent(state_root, :build), do: Path.join([state_root, "contexts", "build"])

  defp safe_context_target?(context, parent, path) do
    context.leased == false and inside?(path, parent) and Path.dirname(path) == parent and
      Regex.match?(~r/^[0-9a-f]{64}$/, Path.basename(path)) and ordinary_directory?(parent) and
      ordinary_directory?(path) and ordinary_regular?(Path.join(path, @access_marker))
  end

  defp remove_context_locked(context, state_root, path) do
    case context_leased_now?(state_root, context) do
      {:ok, true} ->
        :leased

      {:ok, false} ->
        case File.rm_rf(path) do
          {:ok, _removed} -> :ok
          {:error, reason, failed_path} -> {:error, {:runtime_context_gc, failed_path, reason}}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp context_leased_now?(state_root, context) do
    with {:ok, runs} <- read_runs(state_root) do
      {:ok,
       Enum.any?(runs, fn run ->
         run.leased and
           case context.kind do
             :deps -> run.dependency_identity == context.identity
             :build -> run.execution_identity == context.identity
           end
       end)}
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
    metadata
    |> Map.get(key, Map.get(metadata, Map.fetch!(@metadata_atom_keys, key)))
    |> null_to_nil()
  end

  defp null_to_nil(:null), do: nil
  defp null_to_nil(value), do: value

  defp inside?(path, root) do
    path = Path.expand(path)
    root = Path.expand(root)
    path == root or String.starts_with?(path, root <> "/")
  end

  defp context_lock(path), do: "mix_workspace_ops:context:" <> Path.expand(path)

  defp lock_digest(bytes) do
    case Lockfile.digest(bytes) do
      {:ok, digest} -> digest
      {:error, _reason} -> "invalid-" <> sha256(bytes)
    end
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end