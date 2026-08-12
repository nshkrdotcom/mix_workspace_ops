defmodule MixWorkspaceOps.View do
  @moduledoc "Strict named selectors over portable registry project identities and tags."

  alias MixWorkspaceOps.Registry

  @schema "mix_workspace_ops.view/v1"
  @enforce_keys [:path, :digest, :id, :description, :selector]
  defstruct [:path, :digest, :id, :description, :selector]

  @type t :: %__MODULE__{}

  @spec load(String.t()) :: {:ok, t()} | {:error, term()}
  def load(path) do
    path = Path.expand(path)

    with {:ok, bytes} <- File.read(path),
         {:ok, decoded} <- decode(bytes),
         {:ok, view} <- parse(decoded) do
      {:ok, struct!(__MODULE__, Map.merge(view, %{path: path, digest: digest(bytes)}))}
    end
  end

  @spec select(Registry.t(), t()) :: {:ok, [Registry.project()]} | {:error, term()}
  def select(registry, view) do
    selector = view.selector
    requested = MapSet.new(selector.project_ids)
    excluded = MapSet.new(selector.exclude_project_ids)
    unknown = MapSet.difference(requested, registry.projects |> Map.keys() |> MapSet.new())

    if MapSet.size(unknown) > 0 do
      {:error, {:unknown_view_projects, unknown |> MapSet.to_list() |> Enum.sort()}}
    else
      selected =
        registry.projects
        |> Map.values()
        |> Enum.filter(&selected?(&1, selector, requested))
        |> Enum.reject(&MapSet.member?(excluded, &1.id))
        |> Enum.sort_by(& &1.id)

      {:ok, selected}
    end
  end

  defp selected?(project, selector, requested) do
    tags = MapSet.new(project.tags)
    any = selector.tags_any == [] or Enum.any?(selector.tags_any, &MapSet.member?(tags, &1))
    all = Enum.all?(selector.tags_all, &MapSet.member?(tags, &1))
    explicit = MapSet.size(requested) == 0 or MapSet.member?(requested, project.id)
    any and all and explicit
  end

  defp parse(
         %{
           "schema" => @schema,
           "id" => id,
           "description" => description,
           "selector" =>
             %{
               "tags_any" => tags_any,
               "tags_all" => tags_all,
               "project_ids" => project_ids,
               "exclude_project_ids" => exclude_project_ids
             } = selector
         } = raw
       )
       when map_size(raw) == 4 and map_size(selector) == 4 and is_binary(id) and
              is_binary(description) and is_list(tags_any) and is_list(tags_all) and
              is_list(project_ids) and is_list(exclude_project_ids) do
    selector = %{
      tags_any: tags_any,
      tags_all: tags_all,
      project_ids: project_ids,
      exclude_project_ids: exclude_project_ids
    }

    validate_selector(id, description, selector)
  end

  defp parse(_decoded), do: {:error, :unsupported_view_schema}

  defp validate_selector(id, description, selector) do
    values =
      selector.tags_any ++
        selector.tags_all ++
        selector.project_ids ++
        selector.exclude_project_ids

    if Enum.all?(values, &is_binary/1) and length(values) == length(Enum.uniq(values)) do
      {:ok, %{id: id, description: description, selector: selector}}
    else
      {:error, :invalid_view_selector}
    end
  end

  defp decode(bytes) do
    {:ok, :json.decode(bytes)}
  catch
    kind, reason -> {:error, {:json, kind, reason}}
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
