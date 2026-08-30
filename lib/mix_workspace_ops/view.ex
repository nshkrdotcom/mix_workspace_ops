defmodule MixWorkspaceOps.View do
  @moduledoc """
  Named selectors over the catalog.

  A view selects repositories first and projects second, so a repository with no
  Mix project is still reachable: `select_repositories/2` returns it and
  `registry select` reports it, even though it contributes no project.

  `MixWorkspaceOps.Registry.select/3` records repository and project matches
  independently, so repository-scoped fan-out can operate on a selected
  repository even when it has no Mix project.

  `portfolio_registry.view/v2` selects on repository identity, groups, languages,
  and lifecycles as well as project identity. `mix_workspace_ops.view/v1` still
  loads; its `tags_any` and `tags_all` match a v1 document's project tags and a
  v2 document's repository groups.
  """

  alias MixWorkspaceOps.{Registry, StrictJSON}

  @v1 "mix_workspace_ops.view/v1"
  @v2 "portfolio_registry.view/v2"

  @v1_selector_keys ~w(tags_any tags_all project_ids exclude_project_ids)
  @v2_selector_keys ~w(groups_any groups_all languages lifecycles repository_ids
                       exclude_repository_ids project_ids exclude_project_ids)

  @enforce_keys [:path, :digest, :schema, :id, :description, :selector]
  defstruct [:path, :digest, :schema, :id, :description, :selector]

  @type selector :: %{
          groups_any: [String.t()],
          groups_all: [String.t()],
          languages: [String.t()],
          lifecycles: [String.t()],
          repository_ids: [String.t()],
          exclude_repository_ids: [String.t()],
          project_ids: [String.t()],
          exclude_project_ids: [String.t()]
        }
  @type t :: %__MODULE__{
          path: String.t(),
          digest: String.t(),
          schema: String.t(),
          id: String.t(),
          description: String.t(),
          selector: selector()
        }

  @empty %{
    groups_any: [],
    groups_all: [],
    languages: [],
    lifecycles: [],
    repository_ids: [],
    exclude_repository_ids: [],
    project_ids: [],
    exclude_project_ids: []
  }

  @spec schema() :: String.t()
  def schema, do: @v2

  @spec schemas() :: [String.t()]
  def schemas, do: [@v2, @v1]

  @spec load(String.t()) :: {:ok, t()} | {:error, term()}
  def load(path) do
    path = Path.expand(path)

    with {:ok, bytes} <- File.read(path), do: load_document(bytes, path)
  end

  @doc """
  Loads a view document held in memory.

  `path` names where the bytes came from and is carried in the loaded view;
  nothing is read from it.
  """
  @spec load_document(binary(), String.t()) :: {:ok, t()} | {:error, term()}
  def load_document(bytes, path) do
    with {:ok, decoded} <- StrictJSON.decode(bytes, maximum_bytes: 1024 * 1024),
         {:ok, view} <- parse(decoded) do
      {:ok, struct!(__MODULE__, Map.merge(view, %{path: path, digest: digest(bytes)}))}
    end
  end

  @doc "Repositories the view selects, sorted by repository id."
  @spec select_repositories(Registry.t(), t()) ::
          {:ok, [Registry.repository()]} | {:error, term()}
  def select_repositories(registry, view) do
    with :ok <- known_repositories(registry, view) do
      selected =
        registry.repositories
        |> Map.values()
        |> Enum.filter(&repository_selected?(&1, view.selector))
        |> Enum.sort_by(& &1.id)

      {:ok, selected}
    end
  end

  @doc "Projects the view selects, sorted by project id."
  @spec select(Registry.t(), t()) :: {:ok, [Registry.project()]} | {:error, term()}
  def select(registry, view) do
    with :ok <- known_projects(registry, view),
         {:ok, repositories} <- select_repositories(registry, view) do
      selected =
        repositories
        |> Enum.flat_map(& &1.projects)
        |> Enum.filter(&project_selected?(&1, view.selector))
        |> Enum.sort_by(& &1.id)

      {:ok, selected}
    end
  end

  defp repository_selected?(repository, selector) do
    included?(selector.repository_ids, repository.id) and
      repository.id not in selector.exclude_repository_ids and
      any?(selector.groups_any, repository.groups) and
      all?(selector.groups_all, repository.groups) and
      any?(selector.languages, repository.languages) and
      included?(selector.lifecycles, repository.lifecycle)
  end

  defp project_selected?(project, selector) do
    included?(selector.project_ids, project.id) and
      project.id not in selector.exclude_project_ids
  end

  defp included?([], _value), do: true
  defp included?(allowed, value), do: value in allowed

  defp any?([], _values), do: true
  defp any?(required, values), do: Enum.any?(required, &(&1 in values))

  defp all?(required, values), do: Enum.all?(required, &(&1 in values))

  defp known_repositories(registry, view) do
    unknown = view.selector.repository_ids -- Map.keys(registry.repositories)

    if unknown == [],
      do: :ok,
      else: {:error, {:unknown_view_repositories, Enum.sort(unknown)}}
  end

  defp known_projects(registry, view) do
    unknown = view.selector.project_ids -- Map.keys(registry.projects)

    if unknown == [], do: :ok, else: {:error, {:unknown_view_projects, Enum.sort(unknown)}}
  end

  defp parse(
         %{"schema" => @v2, "id" => id, "description" => description, "selector" => selector} =
           raw
       )
       when map_size(raw) == 4 do
    with :ok <- strings(id, description),
         :ok <- selector_keys(selector, @v2_selector_keys),
         {:ok, parsed} <- selector_lists(selector, @v2_selector_keys) do
      {:ok, %{schema: @v2, id: id, description: description, selector: parsed}}
    end
  end

  defp parse(
         %{"schema" => @v1, "id" => id, "description" => description, "selector" => selector} =
           raw
       )
       when map_size(raw) == 4 do
    with :ok <- strings(id, description),
         :ok <- exact_selector_keys(selector, @v1_selector_keys),
         {:ok, parsed} <- selector_lists(selector, @v1_selector_keys) do
      selector =
        parsed
        |> Map.put(:groups_any, Map.fetch!(parsed, :tags_any))
        |> Map.put(:groups_all, Map.fetch!(parsed, :tags_all))
        |> Map.drop([:tags_any, :tags_all])

      {:ok, %{schema: @v1, id: id, description: description, selector: selector}}
    end
  end

  defp parse(_decoded), do: {:error, :unsupported_view_schema}

  defp strings(id, description) do
    if is_binary(id) and is_binary(description), do: :ok, else: {:error, :invalid_view_identity}
  end

  defp selector_keys(selector, allowed) when is_map(selector) do
    case Map.keys(selector) -- allowed do
      [] -> :ok
      unknown -> {:error, {:unknown_view_selector_keys, Enum.sort(unknown)}}
    end
  end

  defp selector_keys(_selector, _allowed), do: {:error, :invalid_view_selector}

  defp exact_selector_keys(selector, expected) when is_map(selector) do
    if Enum.sort(Map.keys(selector)) == Enum.sort(expected),
      do: :ok,
      else: {:error, :invalid_view_selector}
  end

  defp exact_selector_keys(_selector, _expected), do: {:error, :invalid_view_selector}

  defp selector_lists(selector, keys) do
    keys
    |> Enum.reduce_while({:ok, @empty}, fn key, {:ok, acc} ->
      case selector_list(Map.get(selector, key)) do
        {:ok, values} -> {:cont, {:ok, Map.put(acc, String.to_existing_atom(key), values)}}
        :error -> {:halt, {:error, {:invalid_view_selector, key}}}
      end
    end)
  end

  defp selector_list(nil), do: {:ok, []}

  defp selector_list(values) when is_list(values) do
    if Enum.all?(values, &is_binary/1) and values == Enum.uniq(values),
      do: {:ok, values},
      else: :error
  end

  defp selector_list(_values), do: :error

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
