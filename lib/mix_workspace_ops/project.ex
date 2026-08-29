defmodule MixWorkspaceOps.Project do
  @moduledoc """
  Isolated discovery of authoritative Mix project metadata.

  `metadata/2` evaluates a project's `mix.exs` in a separate, time-limited
  subprocess, which is the only way to learn what Mix itself would compute.
  Phase P3 owns scrubbing the rest of the inherited environment.
  `declared_version/1` answers the one question that does not need evaluation,
  by parsing.
  """

  alias MixWorkspaceOps.{Command, Registry}
  alias MixWorkspaceOps.Project.ProbeMemo

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
  dependencies =
    config
    |> Keyword.get(:deps, [])
    |> Enum.flat_map(fn
      {dep, _value} when is_atom(dep) -> [Atom.to_string(dep)]
      {dep, _requirement, _opts} when is_atom(dep) -> [Atom.to_string(dep)]
      _other -> []
    end)
    |> Enum.uniq()
    |> Enum.sort()
  IO.puts("#{@marker}" <> app <> "\t" <> version <> "\t" <> Enum.join(dependencies, ","))
  """

  @type probe_options :: [
          probe_memo: ProbeMemo.t(),
          mix_env: String.t(),
          mix_target: String.t() | nil,
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
    mix_env = Keyword.get(opts, :mix_env, "dev")
    mix_target = Keyword.get_lazy(opts, :mix_target, fn -> System.get_env("MIX_TARGET") end)

    with {:ok, key} <- probe_key(project_root, mix_env, mix_target, opts) do
      question = fn -> evaluate_at(project_root, mix_env, mix_target) end

      case Keyword.get(opts, :probe_memo) do
        nil -> question.()
        memo -> ProbeMemo.fetch(memo, key, question)
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

  defp probe_key(project_root, mix_env, mix_target, opts) do
    path = Path.join(project_root, "mix.exs")

    with :ok <- readable(path), {:ok, bytes} <- File.read(path) do
      digest = :crypto.hash(:sha256, bytes)
      toolchain = Keyword.get_lazy(opts, :toolchain, &toolchain/0)
      {:ok, {digest, mix_env, mix_target, toolchain}}
    end
  end

  defp toolchain do
    mix_version = :mix |> Application.spec(:vsn) |> to_string()
    {System.version(), List.to_string(:erlang.system_info(:otp_release)), mix_version}
  end

  defp evaluate_at(project_root, mix_env, mix_target) do
    case Command.run(
           "timeout",
           [
             "--kill-after=2",
             "15",
             elixir_executable(),
             "-e",
             @expression
           ],
           cd: project_root,
           env: [
             {"MIX_ENV", mix_env},
             {"MIX_TARGET", mix_target},
             {"MIX_WORKSPACE_OPS_BOOTSTRAP", nil},
             {"MIX_WORKSPACE_OPS_CONTEXT_DIGEST", nil},
             {"MIX_WORKSPACE_OPS_LOCKFILE", nil},
             {"MIX_WORKSPACE_OPS_OVERLAY", nil}
           ]
         ) do
      {:ok, result} -> parse(result.output)
      {:error, result} -> {:error, {:command_failed, result.exit_code, result.output}}
    end
  end

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

  defp parse_metadata([app, version, dependencies]) do
    {:ok,
     %{
       app: if(app == "", do: nil, else: app),
       version: version,
       dependencies: if(dependencies == "", do: [], else: String.split(dependencies, ","))
     }}
  end

  defp parse_metadata(_parts), do: {:error, :invalid_metadata_marker}
end
