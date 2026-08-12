defmodule MixWorkspaceOps.Project do
  @moduledoc "Isolated discovery of authoritative Mix project metadata."

  alias MixWorkspaceOps.{Command, Registry}

  @marker "__MIX_WORKSPACE_OPS_METADATA__"
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
