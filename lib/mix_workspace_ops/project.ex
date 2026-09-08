defmodule MixWorkspaceOps.Project do
  @moduledoc """
  Isolated discovery of authoritative Mix project metadata.

  `metadata/2` evaluates a project's `mix.exs` in a separate, time-limited
  subprocess, which is the only way to learn what Mix itself would compute.
  It receives an explicit replacement environment and a disposable source tree.
  `declared_version/1` answers the one question that does not need evaluation,
  by parsing.
  """

  alias Mix.Sync.Lock, as: SyncLock
  alias MixWorkspaceOps.{Command, Git, MixInputs, Registry, ResourceBudget, Toolchain}
  alias MixWorkspaceOps.Project.{ProbeMemo, ProbeTree}

  @marker "__MIX_WORKSPACE_OPS_METADATA__"
  @maximum_mix_bytes 1024 * 1024
  @expression """
  Mix.start()
  Code.compile_file("mix.exs")
  config = Mix.Project.config()
  custom_deps_get_alias =
    config
    |> Keyword.get(:aliases, [])
    |> Keyword.has_key?(:"deps.get")
  app =
    case Keyword.get(config, :app) do
      app when is_atom(app) and not is_nil(app) -> Atom.to_string(app)
      _other -> ""
    end
  version = config |> Keyword.get(:version, "") |> to_string()
  mix_env = Mix.env()
  mix_target = Mix.target()
  dependency_scope = System.get_env("MIX_WORKSPACE_OPS_DEPENDENCY_SCOPE", "active")
  active_for = fn opts, key, current ->
    if key == :only and dependency_scope == "all" do
      true
    else
      current_names =
        case {key, dependency_scope} do
          {:only, "only:" <> names} -> String.split(names, ",", trim: true)
          _other -> [Atom.to_string(current)]
        end

      case Keyword.get(opts, key) do
        nil -> true
        value when is_atom(value) -> Atom.to_string(value) in current_names
        values when is_list(values) -> Enum.any?(values, &(Atom.to_string(&1) in current_names))
        _other -> false
      end
    end
  end
  active = fn opts ->
    active_for.(opts, :only, mix_env) and active_for.(opts, :targets, mix_target)
  end
  dependency_options = fn
    {_app, opts} when is_list(opts) -> opts
    {_app, _requirement, opts} when is_list(opts) -> opts
    _dependency -> []
  end
  semantic_options = fn opts ->
    Enum.reduce([:only, :optional, :runtime, :targets], %{}, fn key, acc ->
      case Keyword.fetch(opts, key) do
        {:ok, value} when key in [:only, :targets] ->
          values =
            value
            |> List.wrap()
            |> Enum.filter(&is_atom/1)
            |> Enum.map(&Atom.to_string/1)
            |> Enum.uniq()
            |> Enum.sort()

          if values == [], do: acc, else: Map.put(acc, Atom.to_string(key), values)

        {:ok, value} when key in [:optional, :runtime] and is_boolean(value) ->
          Map.put(acc, Atom.to_string(key), value)

        _absent_or_invalid ->
          acc
      end
    end)
  end
  declared_dependencies = Keyword.get(config, :deps, [])
  active_dependencies =
    Enum.filter(declared_dependencies, fn dependency ->
      active.(dependency_options.(dependency))
    end)
  dependencies =
    active_dependencies
    |> Enum.flat_map(fn
      {dep, _value} when is_atom(dep) ->
        [Atom.to_string(dep)]
      {dep, _requirement, _opts} when is_atom(dep) ->
        [Atom.to_string(dep)]
      dep when is_atom(dep) ->
        [Atom.to_string(dep)]
      _other -> []
    end)
    |> Enum.uniq()
    |> Enum.sort()
  dependency_declarations =
    active_dependencies
    |> Enum.flat_map(fn
      {dep, requirement} when is_atom(dep) and is_binary(requirement) ->
        [%{application: Atom.to_string(dep), requirement: %{kind: "string", value: requirement}, options: %{}}]
      {dep, %Regex{} = requirement} when is_atom(dep) ->
        encoded = %{kind: "regex", value: Regex.source(requirement), opts: Regex.opts(requirement)}
        [%{application: Atom.to_string(dep), requirement: encoded, options: %{}}]
      {dep, options} when is_atom(dep) and is_list(options) ->
        [%{application: Atom.to_string(dep), requirement: nil, options: semantic_options.(options)}]
      {dep, requirement, options} when is_atom(dep) and is_binary(requirement) and is_list(options) ->
        [%{application: Atom.to_string(dep), requirement: %{kind: "string", value: requirement}, options: semantic_options.(options)}]
      {dep, %Regex{} = requirement, options} when is_atom(dep) and is_list(options) ->
        encoded = %{kind: "regex", value: Regex.source(requirement), opts: Regex.opts(requirement)}
        [%{application: Atom.to_string(dep), requirement: encoded, options: semantic_options.(options)}]
      dep when is_atom(dep) ->
        [%{application: Atom.to_string(dep), requirement: nil, options: %{}}]
      _other ->
        []
    end)
    |> Enum.sort_by(& &1.application)
    |> :erlang.term_to_binary([:deterministic])
    |> Base.url_encode64(padding: false)
  project_root = File.cwd!()
  probe_root = System.fetch_env!("MIX_WORKSPACE_OPS_PROBE_ROOT")
  normalize_path = fn path ->
    cond do
      Path.type(path) == :relative ->
        {:relative, Path.relative_to(Path.expand(path, "/project"), "/project")}
      path == probe_root or String.starts_with?(path, probe_root <> "/") ->
        {:staged, Path.relative_to(path, project_root)}
      true ->
        {:absolute, path}
    end
  end
  normalize = fn normalize, value ->
    cond do
      match?({:path, path} when is_binary(path), value) ->
        {:path, normalize_path.(elem(value, 1))}
      is_map(value) ->
        value
        |> Enum.map(fn {key, item} -> {normalize.(normalize, key), normalize.(normalize, item)} end)
        |> Enum.sort()
      is_tuple(value) ->
        value |> Tuple.to_list() |> Enum.map(&normalize.(normalize, &1)) |> List.to_tuple()
      is_list(value) ->
        Enum.map(value, &normalize.(normalize, &1))
      true ->
        value
    end
  end
  dependency_fingerprint =
    active_dependencies
    |> then(&normalize.(normalize, &1))
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  IO.puts(
    "#{@marker}" <> app <> "\t" <> version <> "\t" <> Enum.join(dependencies, ",") <>
      "\t" <> dependency_fingerprint <> "\t" <> dependency_declarations <> "\t" <>
      if(custom_deps_get_alias, do: "1", else: "0")
  )
  """

  @type probe_options :: [
          probe_memo: ProbeMemo.t(),
          mix_env: String.t(),
          mix_target: String.t(),
          dependency_scope: :active | :all | {:only, [String.t()]},
          toolchain: term()
        ]

  @spec metadata(Registry.t(), Registry.project(), probe_options()) ::
          {:ok, map()} | {:error, term()}
  def metadata(registry, project, opts \\ []) do
    project_root = Registry.project_root(registry, project)
    repository_root = Registry.repository_root(registry, project.repository)
    opts = Keyword.put_new(opts, :repository_root, repository_root)

    case metadata_at(project_root, opts) do
      {:ok, %{app: app} = metadata} when app == project.app ->
        {:ok, metadata}

      {:ok, %{app: app}} ->
        {:error, {:application_identity_drift, project.id, project.app, app}}

      {:error, reason} ->
        {:error, {:mix_project_metadata, project.id, reason}}
    end
  end

  @spec metadata_at(String.t(), probe_options()) :: {:ok, map()} | {:error, term()}
  def metadata_at(project_root, opts \\ []) do
    project_root = Path.expand(project_root)

    with {:ok, inputs} <- MixInputs.normalize(opts),
         {:ok, {_, source_identity, _, _, _, _} = key, staged, ownership} <-
           probe_key(project_root, inputs, opts) do
      try do
        dependency_scope = Keyword.get(opts, :dependency_scope, :active)

        question = fn ->
          with {:ok, metadata} <-
                 evaluate_project(
                   project_root,
                   staged,
                   inputs.mix_env,
                   inputs.mix_target,
                   dependency_scope,
                   opts
                 ) do
            {:ok, specialize_dependency_fingerprint(metadata, source_identity)}
          end
        end

        case Keyword.get(opts, :probe_memo) do
          nil -> question.()
          memo -> ProbeMemo.fetch(memo, key, question)
        end
      after
        if ownership == :private, do: ProbeTree.cleanup(staged)
      end
    end
  end

  @doc "Warms one invocation memo concurrently for a known project list."
  @spec prewarm(Registry.t(), [Registry.project()], ProbeMemo.t(), keyword()) ::
          [{String.t(), {:ok, map()} | {:error, term()}}]
  def prewarm(registry, projects, memo, opts \\ []) do
    default_concurrency =
      ResourceBudget.snapshot()
      |> ResourceBudget.allocate(:cpu, length(projects))
      |> Map.fetch!(:workers)

    max_concurrency = Keyword.get(opts, :max_concurrency, default_concurrency)

    stage_table =
      :ets.new(__MODULE__, [:set, :public, read_concurrency: true, write_concurrency: true])

    probe_opts =
      opts |> Keyword.put(:probe_memo, memo) |> Keyword.put(:probe_stage_table, stage_table)

    try do
      :ok = snapshot_repository_identities(registry, projects, memo, max_concurrency)

      projects
      |> Task.async_stream(
        fn project -> {project.id, metadata(registry, project, probe_opts)} end,
        max_concurrency: max_concurrency,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)
    after
      cleanup_shared_stages(stage_table)
    end
  end

  defp probe_key(project_root, inputs, opts) do
    path = Path.join(project_root, "mix.exs")

    with :ok <- readable(path),
         {:ok, bytes} <- File.read(path),
         {:ok, source_identity, staged, ownership} <-
           probe_source_identity(project_root, opts) do
      digest = :crypto.hash(:sha256, bytes)
      toolchain = Keyword.get_lazy(opts, :toolchain, &toolchain/0)
      dependency_scope = Keyword.get(opts, :dependency_scope, :active)

      {:ok,
       {digest, source_identity, inputs.mix_env, inputs.mix_target, dependency_scope, toolchain},
       staged, ownership}
    end
  end

  defp probe_source_identity(project_root, opts) do
    case Keyword.get(opts, :repository_root) || git_root(project_root, opts) do
      {:error, _not_git} ->
        staged_source_identity(project_root)

      root when is_binary(root) ->
        git_probe_source_identity(project_root, root, opts)
    end
  end

  defp git_probe_source_identity(project_root, root, opts) do
    relative_project = Path.relative_to(project_root, root)

    with {:ok, extended?} <- repository_extended_source?(root, opts) do
      git_probe_source_identity(project_root, root, relative_project, extended?, opts)
    end
  end

  defp git_probe_source_identity(project_root, root, relative_project, true, opts) do
    case prewarmed_source_digest(root, opts) do
      {:hit, digest} ->
        {:ok, {:git_content, digest, relative_project}, nil, :none}

      :miss ->
        with {:ok, stage, ownership} <- probe_stage(project_root, opts) do
          maybe_snapshot_source_digest(root, stage.source_digest, ownership, opts)
          {:ok, {:git_content, stage.source_digest, relative_project}, stage, ownership}
        end
    end
  end

  defp git_probe_source_identity(_project_root, root, relative_project, false, opts) do
    with {:ok, repository_identity} <- repository_identity(root, opts) do
      {:ok, {:git, repository_identity, relative_project}, nil, :none}
    end
  end

  defp git_root(project_root, opts) do
    case Git.root(project_root, git_inspection_options(opts)) do
      {:ok, root} -> root
      {:error, reason} -> {:error, reason}
    end
  end

  defp repository_identity(root, opts) do
    case Keyword.get(opts, :probe_memo) do
      nil ->
        compute_repository_identity(root, opts)

      memo ->
        case ProbeMemo.snapshot(memo, {:repository_identity, root}) do
          {:hit, identity} ->
            identity

          :miss ->
            compute_repository_identity(root, opts)
        end
    end
  end

  defp compute_repository_identity(root, opts) do
    git_opts = git_inspection_options(opts)
    head = Git.head!(root, git_opts)
    dirty = if Git.clean?(root, git_opts), do: nil, else: Git.source_digest(root, git_opts)
    {:ok, {head, dirty}}
  end

  defp repository_extended_source?(root, opts) do
    case Keyword.get(opts, :probe_memo) do
      nil ->
        ProbeTree.extended_source?(root)

      memo ->
        case ProbeMemo.snapshot(memo, {:extended_probe_source, root}) do
          {:hit, result} -> result
          :miss -> ProbeTree.extended_source?(root)
        end
    end
  end

  defp prewarmed_source_digest(root, opts) do
    case Keyword.get(opts, :probe_memo) do
      nil -> :miss
      memo -> ProbeMemo.snapshot(memo, {:repository_probe_source, root})
    end
  end

  defp maybe_snapshot_source_digest(root, digest, :shared, opts) do
    :ok =
      ProbeMemo.put_snapshot(
        Keyword.fetch!(opts, :probe_memo),
        {:repository_probe_source, root},
        digest
      )
  end

  defp maybe_snapshot_source_digest(_root, _digest, _ownership, _opts), do: :ok

  defp snapshot_repository_identities(registry, projects, memo, max_concurrency) do
    projects
    |> Enum.map(&Registry.repository_root(registry, &1.repository))
    |> Enum.uniq()
    |> Task.async_stream(
      fn root ->
        {root, compute_repository_identity(root, []), ProbeTree.extended_source?(root)}
      end,
      max_concurrency: max_concurrency,
      ordered: false,
      timeout: :infinity
    )
    |> Enum.each(fn {:ok, {root, identity, extended_source}} ->
      :ok = ProbeMemo.put_snapshot(memo, {:repository_identity, root}, identity)
      :ok = ProbeMemo.put_snapshot(memo, {:extended_probe_source, root}, extended_source)
    end)

    :ok
  end

  defp git_inspection_options(_opts) do
    [
      replace_env: true,
      env: [
        {"PATH", Toolchain.path()},
        {"LANG", System.get_env("LANG") || "C"}
      ]
    ]
  end

  defp staged_source_identity(project_root) do
    with {:ok, stage} <- ProbeTree.stage(project_root) do
      {:ok, {:source, stage.source_digest}, stage, :private}
    end
  end

  defp evaluate_project(_project_root, %ProbeTree{} = stage, mix_env, mix_target, scope, _opts),
    do: evaluate_at(stage, mix_env, mix_target, scope)

  defp evaluate_project(project_root, nil, mix_env, mix_target, scope, opts) do
    with {:ok, stage, ownership} <- probe_stage(project_root, opts) do
      try do
        evaluate_at(stage, mix_env, mix_target, scope)
      after
        if ownership == :private, do: ProbeTree.cleanup(stage)
      end
    end
  end

  defp probe_stage(project_root, opts) do
    case {Keyword.get(opts, :probe_stage_table), Keyword.get(opts, :repository_root)} do
      {table, repository_root} when not is_nil(table) and is_binary(repository_root) ->
        with {:ok, repository_stage} <- shared_repository_stage(table, repository_root),
             relative <- Path.relative_to(project_root, repository_root),
             {:ok, project_stage} <- ProbeTree.for_project(repository_stage, relative) do
          {:ok, project_stage, :shared}
        end

      _no_shared_stage ->
        with {:ok, stage} <- ProbeTree.stage(project_root), do: {:ok, stage, :private}
    end
  end

  defp shared_repository_stage(table, repository_root) do
    key = Path.expand(repository_root)

    case :ets.lookup(table, key) do
      [{^key, result}] ->
        result

      [] ->
        lock = "mix_workspace_ops:probe-stage:" <> inspect(table) <> ":" <> sha256(key)
        SyncLock.with_lock(lock, fn -> create_shared_repository_stage(table, key) end)
    end
  end

  defp create_shared_repository_stage(table, key) do
    case :ets.lookup(table, key) do
      [{^key, result}] -> result
      [] -> ProbeTree.stage(key) |> tap(&:ets.insert(table, {key, &1}))
    end
  end

  defp cleanup_shared_stages(table) do
    table
    |> :ets.tab2list()
    |> Enum.each(fn
      {_root, {:ok, stage}} -> ProbeTree.cleanup(stage)
      {_root, {:error, _reason}} -> :ok
    end)
  end

  defp toolchain do
    mix_version = :mix |> Application.spec(:vsn) |> to_string()
    {System.version(), List.to_string(:erlang.system_info(:otp_release)), mix_version}
  end

  defp evaluate_at(stage, mix_env, mix_target, dependency_scope) do
    state = Path.join([stage.root, "state", sha256(stage.project_root)])
    home = Path.join(state, "home")
    mix_home = Path.join(state, "mix")
    hex_home = Path.join(state, "hex")
    temporary = Path.join(state, "tmp")

    for directory <- [state, home, mix_home, hex_home, temporary] do
      File.mkdir_p!(directory)
      File.chmod!(directory, 0o700)
    end

    case Command.run(
           timeout_executable(),
           [
             "--kill-after=2",
             "15",
             elixir_executable(),
             "-e",
             @expression
           ],
           cd: stage.project_root,
           replace_env: true,
           env:
             probe_environment(
               mix_env,
               mix_target,
               dependency_scope,
               home,
               mix_home,
               hex_home,
               temporary,
               stage
             )
         ) do
      {:ok, result} -> parse(result.output)
      {:error, result} -> {:error, {:command_failed, result.exit_code, result.output}}
    end
  end

  defp probe_environment(
         mix_env,
         mix_target,
         dependency_scope,
         home,
         mix_home,
         hex_home,
         temporary,
         stage
       ) do
    [
      {"PATH", Toolchain.path()},
      {"LANG", System.get_env("LANG") || "C"},
      {"HOME", home},
      {"MIX_HOME", mix_home},
      {"MIX_ARCHIVES", Path.join(mix_home, "archives")},
      {"HEX_HOME", hex_home},
      {"REBAR_CACHE_DIR", Path.join(state_parent(hex_home), "rebar")},
      {"TMPDIR", temporary},
      {"MIX_ENV", mix_env},
      {"MIX_TARGET", mix_target},
      {"ERL_AFLAGS", "+S 1:1"},
      {"MIX_WORKSPACE_OPS_DEPENDENCY_SCOPE", encode_dependency_scope(dependency_scope)},
      {"MIX_WORKSPACE_OPS_PROBE", "1"},
      {"MIX_WORKSPACE_OPS_PROBE_ROOT", stage.root}
    ]
  end

  defp state_parent(path), do: Path.dirname(path)

  defp encode_dependency_scope(:active), do: "active"
  defp encode_dependency_scope(:all), do: "all"
  defp encode_dependency_scope({:only, envs}), do: "only:" <> Enum.join(envs, ",")

  defp timeout_executable, do: System.find_executable("timeout") || "timeout"

  # A project's partial `.tool-versions` must not silently change which Elixir
  # the memo key says evaluated it.
  defp elixir_executable, do: Toolchain.executable("elixir")

  @doc """
  The version a project's `mix.exs` declares, read by parsing it.

  The file is parsed and never evaluated. A version is what an operator needs
  in a report and while deciding whether a published requirement still admits a
  sibling checkout, and neither is worth running a repository's build script
  for. A literal is taken as it stands and a module attribute — the ordinary
  `@version` shape — is resolved against the attributes the file sets.
  """
  @spec declared_version(String.t()) :: {:ok, String.t()} | {:error, term()}
  def declared_version(project_root) do
    path = project_root |> Path.expand() |> Path.join("mix.exs")

    with :ok <- readable(path), {:ok, bytes} <- File.read(path) do
      parse_version(bytes, path)
    end
  end

  defp readable(path) do
    case File.stat(path) do
      {:ok, %{type: :regular, size: size}} when size <= @maximum_mix_bytes -> :ok
      {:ok, %{type: :regular}} -> {:error, {:oversized_mix_exs, path}}
      {:ok, _stat} -> {:error, {:missing_mix_exs, path}}
      {:error, reason} -> {:error, {:missing_mix_exs, path, reason}}
    end
  end

  defp parse_version(bytes, path) do
    quoted = Code.string_to_quoted!(bytes, file: path)
    attributes = module_attributes(quoted)

    case find_version(quoted, attributes) do
      nil -> {:error, {:version_not_found, path}}
      version -> {:ok, version}
    end
  rescue
    _error -> {:error, {:unparsable_mix_exs, path}}
  end

  defp module_attributes(quoted) do
    {_quoted, attributes} =
      Macro.prewalk(quoted, %{}, fn
        {:@, _meta, [{name, _name_meta, [value]}]} = node, acc when is_atom(name) ->
          if is_binary(value), do: {node, Map.put_new(acc, name, value)}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    attributes
  end

  defp find_version(quoted, attributes) do
    {_quoted, version} =
      Macro.prewalk(quoted, nil, fn
        {:version, value} = node, nil -> {node, version_literal(value, attributes)}
        node, acc -> {node, acc}
      end)

    version
  end

  defp version_literal(value, _attributes) when is_binary(value), do: value

  defp version_literal({:@, _meta, [{name, _name_meta, nil}]}, attributes) when is_atom(name),
    do: Map.get(attributes, name)

  defp version_literal(_value, _attributes), do: nil

  @spec dependencies(Registry.t(), Registry.project()) :: {:ok, [String.t()]} | {:error, term()}
  def dependencies(registry, project, opts \\ []) do
    case metadata(registry, project, opts) do
      {:ok, metadata} -> {:ok, metadata.dependencies}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "The active dependency applications and their original Mix requirements."
  @spec dependency_declarations(Registry.t(), Registry.project(), probe_options()) ::
          {:ok, [map()]} | {:error, term()}
  def dependency_declarations(registry, project, opts \\ []) do
    case metadata(registry, project, opts) do
      {:ok, metadata} -> {:ok, metadata.dependency_declarations}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse(output) do
    marker =
      output
      |> String.split("\n", trim: true)
      |> Enum.find(&String.starts_with?(&1, @marker))

    case marker do
      nil ->
        {:error, :missing_metadata_marker}

      @marker <> encoded ->
        parse_metadata(String.split(encoded, "\t"))
    end
  end

  defp parse_metadata([
         app,
         version,
         dependencies,
         dependency_fingerprint,
         declarations,
         custom_deps_get_alias
       ]) do
    with {:ok, encoded} <- Base.url_decode64(declarations, padding: false),
         decoded when is_list(decoded) <- :erlang.binary_to_term(encoded, [:safe]),
         true <- custom_deps_get_alias in ["0", "1"],
         :ok <- validate_dependency_declarations(decoded) do
      {:ok,
       %{
         app: if(app == "", do: nil, else: app),
         version: version,
         dependencies: if(dependencies == "", do: [], else: String.split(dependencies, ",")),
         dependency_declarations: decoded,
         dependency_fingerprint: dependency_fingerprint,
         custom_deps_get_alias?: custom_deps_get_alias == "1"
       }}
    else
      _invalid -> {:error, :invalid_dependency_declarations}
    end
  end

  defp parse_metadata(_parts), do: {:error, :invalid_metadata_marker}

  defp specialize_dependency_fingerprint(metadata, source_identity) do
    fingerprint =
      if metadata.custom_deps_get_alias? do
        {metadata.dependency_fingerprint, source_identity}
        |> :erlang.term_to_binary([:deterministic])
        |> sha256()
      else
        metadata.dependency_fingerprint
      end

    metadata
    |> Map.put(:dependency_fingerprint, fingerprint)
    |> Map.delete(:custom_deps_get_alias?)
  end

  defp validate_dependency_declarations(declarations) do
    if Enum.all?(declarations, &valid_dependency_declaration?/1),
      do: :ok,
      else: {:error, :invalid_dependency_declarations}
  end

  defp valid_dependency_declaration?(%{
         application: app,
         requirement: requirement,
         options: options
       })
       when is_binary(app) and is_map(options),
       do: valid_requirement?(requirement) and valid_dependency_options?(options)

  defp valid_dependency_declaration?(_other), do: false

  defp valid_requirement?(nil), do: true

  defp valid_requirement?(%{kind: "string", value: value} = requirement),
    do: map_size(requirement) == 2 and is_binary(value)

  defp valid_requirement?(%{kind: "regex", value: value, opts: opts} = requirement),
    do: map_size(requirement) == 3 and is_binary(value) and is_binary(opts)

  defp valid_requirement?(_requirement), do: false

  defp valid_dependency_options?(options) do
    Enum.all?(options, fn
      {key, values} when key in ["only", "targets"] ->
        is_list(values) and Enum.all?(values, &is_binary/1)

      {key, value} when key in ["optional", "runtime"] ->
        is_boolean(value)

      _other ->
        false
    end)
  end

  defp sha256(bytes),
    do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
