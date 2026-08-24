defmodule MixWorkspaceOps.Project do
  @moduledoc """
  Isolated discovery of authoritative Mix project metadata.

  `metadata/2` evaluates a project's `mix.exs` in a scrubbed subprocess, which
  is the only way to learn what Mix itself would compute. `declared_version/1`
  answers the one question that does not need that, by parsing.
  """

  alias MixWorkspaceOps.{Command, Registry}

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

  @spec metadata(Registry.t(), Registry.project()) :: {:ok, map()} | {:error, term()}
  def metadata(registry, project) do
    project_root = Registry.project_root(registry, project)

    case metadata_at(project_root) do
      {:ok, %{app: app} = metadata} when app == project.app ->
        {:ok, metadata}

      {:ok, %{app: app}} ->
        {:error, {:application_identity_drift, project.id, project.app, app}}

      {:error, reason} ->
        {:error, {:mix_project_metadata, project.id, reason}}
    end
  end

  @spec metadata_at(String.t()) :: {:ok, map()} | {:error, term()}
  def metadata_at(project_root) do
    project_root = Path.expand(project_root)

    case Command.run(
           "timeout",
           [
             "--kill-after=2",
             "15",
             "elixir",
             "-e",
             @expression
           ],
           cd: project_root,
           env: [
             {"MIX_ENV", "dev"},
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
  def dependencies(registry, project) do
    case metadata(registry, project) do
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
