defmodule MixWorkspaceOps.Project do
  @moduledoc """
  Isolated discovery of authoritative Mix project metadata.

  `metadata/2` evaluates a project's `mix.exs` in a separate, time-limited
  subprocess, which is the only way to learn what Mix itself would compute.
  Phase P3 owns scrubbing the rest of the inherited environment.
  `declared_version/1` answers the one question that does not need evaluation,
  by parsing.
  """

  alias MixWorkspaceOps.{Command, MixInputs, Registry}
  alias MixWorkspaceOps.Project.{ProbeMemo, ProbeTree}

  @marker "__MIX_WORKSPACE_OPS_METADATA__"
  @maximum_mix_bytes 1024 * 1024
  @expression """
  Mix.start()
  Code.compile_file("mix.exs")
  config = Mix.Project.config()
  app =
    case Keyword.get(config, :app) do
      app when is_atom(app) and not is_nil(app) -> Atom.to_string(app)
      _other -> ""
    end
  version = config |> Keyword.get(:version, "") |> to_string()
  mix_env = Mix.env()
  mix_target = Mix.target()
  active_for = fn opts, key, current ->
    case Keyword.get(opts, key) do
      nil -> true
      value when is_atom(value) -> value == current
      values when is_list(values) -> current in values
      _other -> false
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
      "\t" <> dependency_fingerprint
  )
  """

  @type probe_options :: [
          probe_memo: ProbeMemo.t(),
          mix_env: String.t(),
          mix_target: String.t(),
          toolchain: term()
        ]

  @spec metadata(Registry.t(), Registry.project(), probe_options()) ::
          {:ok, map()} | {:error, term()}
  def metadata(registry, project, opts \\ []) do
    project_root = Registry.project_root(registry, project)

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
         {:ok, stage} <- ProbeTree.stage(project_root) do
      try do
        with {:ok, key} <- probe_key(stage, inputs, opts) do
          question = fn -> evaluate_at(stage, inputs.mix_env, inputs.mix_target) end

          case Keyword.get(opts, :probe_memo) do
            nil -> question.()
            memo -> ProbeMemo.fetch(memo, key, question)
          end
        end
      after
        ProbeTree.cleanup(stage)
      end
    end
  end

  @doc "Warms one invocation memo concurrently for a known project list."
  @spec prewarm(Registry.t(), [Registry.project()], ProbeMemo.t(), keyword()) ::
          [{String.t(), {:ok, map()} | {:error, term()}}]
  def prewarm(registry, projects, memo, opts \\ []) do
    max_concurrency = Keyword.get(opts, :max_concurrency, min(System.schedulers_online(), 8))
    probe_opts = Keyword.put(opts, :probe_memo, memo)

    projects
    |> Task.async_stream(
      fn project -> {project.id, metadata(registry, project, probe_opts)} end,
      max_concurrency: max_concurrency,
      ordered: false,
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end

  defp probe_key(stage, inputs, opts) do
    path = Path.join(stage.project_root, "mix.exs")

    with :ok <- readable(path), {:ok, bytes} <- File.read(path) do
      digest = :crypto.hash(:sha256, bytes)
      toolchain = Keyword.get_lazy(opts, :toolchain, &toolchain/0)
      {:ok, {digest, stage.source_digest, inputs.mix_env, inputs.mix_target, toolchain}}
    end
  end

  defp toolchain do
    mix_version = :mix |> Application.spec(:vsn) |> to_string()
    {System.version(), List.to_string(:erlang.system_info(:otp_release)), mix_version}
  end

  defp evaluate_at(stage, mix_env, mix_target) do
    state = Path.join(stage.root, "state")
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
           env: probe_environment(mix_env, mix_target, home, mix_home, hex_home, temporary, stage)
         ) do
      {:ok, result} -> parse(result.output)
      {:error, result} -> {:error, {:command_failed, result.exit_code, result.output}}
    end
  end

  defp probe_environment(mix_env, mix_target, home, mix_home, hex_home, temporary, stage) do
    [
      {"PATH", System.get_env("PATH") || "/usr/bin:/bin"},
      {"LANG", System.get_env("LANG") || "C"},
      {"HOME", home},
      {"MIX_HOME", mix_home},
      {"MIX_ARCHIVES", Path.join(mix_home, "archives")},
      {"HEX_HOME", hex_home},
      {"REBAR_CACHE_DIR", Path.join(state_parent(hex_home), "rebar")},
      {"TMPDIR", temporary},
      {"MIX_ENV", mix_env},
      {"MIX_TARGET", mix_target},
      {"MIX_WORKSPACE_OPS_PROBE", "1"},
      {"MIX_WORKSPACE_OPS_PROBE_ROOT", stage.root}
    ]
  end

  defp state_parent(path), do: Path.dirname(path)

  defp timeout_executable, do: System.find_executable("timeout") || "timeout"

  # Use the executable of the running toolchain rather than a version-manager
  # shim that re-resolves from the probed project's working directory. A
  # project's partial `.tool-versions` must not silently change which Elixir
  # the memo key says evaluated it.
  defp elixir_executable do
    candidate =
      :elixir
      |> :code.lib_dir()
      |> Path.join("../../bin/elixir")
      |> Path.expand()

    if File.regular?(candidate), do: candidate, else: version_manager_elixir()
  end

  defp version_manager_elixir do
    case Command.run("asdf", ["which", "elixir"], cd: System.tmp_dir!()) do
      {:ok, result} -> String.trim(result.output)
      {:error, _result} -> System.find_executable("elixir") || "elixir"
    end
  end

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

  defp parse_metadata([app, version, dependencies, dependency_fingerprint]) do
    {:ok,
     %{
       app: if(app == "", do: nil, else: app),
       version: version,
       dependencies: if(dependencies == "", do: [], else: String.split(dependencies, ",")),
       dependency_fingerprint: dependency_fingerprint
     }}
  end

  defp parse_metadata(_parts), do: {:error, :invalid_metadata_marker}
end
