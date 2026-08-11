defmodule MixWorkspaceOps.Graph do
  @moduledoc "Dependency closure and deterministic topological ordering."

  alias MixWorkspaceOps.Catalog

  @spec closure(Catalog.t(), String.t() | atom()) :: [Catalog.project()]
  def closure(catalog, target) do
    target = to_string(target)

    case visit(catalog, target, MapSet.new(), MapSet.new(), []) do
      {:ok, _visiting, _visited, ordered} ->
        Enum.reverse(ordered)

      {:error, cycle} ->
        raise ArgumentError, "managed dependency cycle: #{Enum.join(cycle, " -> ")}"
    end
  end

  @spec edges(Catalog.t()) :: [{String.t(), String.t()}]
  def edges(catalog) do
    catalog.projects
    |> Enum.flat_map(fn {app, project} -> Enum.map(project.managed_deps, &{app, &1}) end)
    |> Enum.sort()
  end

  defp visit(catalog, app, visiting, visited, ordered) do
    cond do
      MapSet.member?(visited, app) ->
        {:ok, visiting, visited, ordered}

      MapSet.member?(visiting, app) ->
        {:error, [app]}

      true ->
        project = Catalog.project!(catalog, app)
        visiting = MapSet.put(visiting, app)

        project.managed_deps
        |> visit_dependencies(catalog, app, visiting, visited, ordered)
        |> case do
          {:ok, final_visiting, final_visited, final_ordered} ->
            {:ok, MapSet.delete(final_visiting, app), MapSet.put(final_visited, app),
             [project | final_ordered]}

          error ->
            error
        end
    end
  end

  defp visit_dependencies(dependencies, catalog, app, visiting, visited, ordered) do
    Enum.reduce_while(dependencies, {:ok, visiting, visited, ordered}, fn dependency, state ->
      case visit_dependency(catalog, dependency, state) do
        {:ok, next_state} ->
          {:cont, {:ok, next_state.visiting, next_state.visited, next_state.ordered}}

        {:error, cycle} ->
          {:halt, {:error, [app | cycle]}}
      end
    end)
  end

  defp visit_dependency(catalog, dependency, {:ok, visiting, visited, ordered}) do
    case visit(catalog, dependency, visiting, visited, ordered) do
      {:ok, next_visiting, next_visited, next_ordered} ->
        {:ok, %{visiting: next_visiting, visited: next_visited, ordered: next_ordered}}

      error ->
        error
    end
  end
end
