defmodule MixWorkspaceOps.Project do
  @moduledoc "Isolated discovery of authoritative Mix project metadata."

  alias MixWorkspaceOps.{Command, Registry}

  @marker "__MIX_WORKSPACE_OPS_METADATA__"
  @expression """
  config = Mix.Project.config()
  app = config |> Keyword.fetch!(:app) |> Atom.to_string()
  version = config |> Keyword.fetch!(:version) |> to_string()
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

    case Command.run(
           "mix",
           ["run", "--no-start", "--no-deps-check", "--no-compile", "-e", @expression],
           cd: project_root,
           env: [{"MIX_ENV", "dev"}, {"MIX_WORKSPACE_OPS_OVERLAY", nil}]
         ) do
      {:ok, result} -> parse(result.output, project)
      {:error, result} -> {:error, {:mix_project_metadata, project.id, result}}
    end
  end

  @spec dependencies(Registry.t(), Registry.project()) :: {:ok, [String.t()]} | {:error, term()}
  def dependencies(registry, project) do
    case metadata(registry, project) do
      {:ok, metadata} -> {:ok, metadata.dependencies}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse(output, project) do
    marker =
      output
      |> String.split("\n", trim: true)
      |> Enum.find(&String.starts_with?(&1, @marker))

    case marker do
      nil ->
        {:error, {:missing_metadata_marker, project.id}}

      @marker <> encoded ->
        parse_metadata(String.split(encoded, "\t"), project)
    end
  end

  defp parse_metadata([app, version, dependencies], project) do
    if app == project.app do
      {:ok,
       %{
         app: app,
         version: version,
         dependencies: if(dependencies == "", do: [], else: String.split(dependencies, ","))
       }}
    else
      {:error, {:application_identity_drift, project.id, project.app, app}}
    end
  end

  defp parse_metadata(_parts, project), do: {:error, {:invalid_metadata_marker, project.id}}
end
