defmodule MixWorkspaceOps.Impact do
  @moduledoc "Reverse dependency impact over a `DependencyIndex`."

  alias MixWorkspaceOps.{DependencyIndex, Registry}

  @spec analyze(Registry.t(), DependencyIndex.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def analyze(%Registry{} = registry, index, target) when is_binary(target) do
    with {:ok, normalized} <- normalize_target(registry, target),
         reverse <- reverse_edges(index.edges),
         {:ok, traversal} <- traverse(normalized.seed_projects, reverse) do
      selected = MapSet.new(index.selected_projects)
      affected = traversal.affected |> Enum.sort()
      selected_affected = Enum.filter(affected, &MapSet.member?(selected, &1))
      direct = traversal.direct |> Enum.sort()
      transitive = affected -- Enum.uniq(normalized.seed_projects ++ direct)

      {:ok,
       %{
         schema: "mix_workspace_ops.impact/v1",
         target: normalized,
         seed_projects: Enum.sort(normalized.seed_projects),
         direct_dependents: direct,
         transitive_dependents: Enum.sort(transitive),
         affected_projects: affected,
         selected_affected_projects: selected_affected,
         affected_repositories: affected_repositories(registry, affected),
         paths: traversal.paths,
         coverage: DependencyIndex.coverage(index),
         safe_affected_only: index.complete,
         dependency_index_digest: index.digest,
         mix_env: index.mix_env,
         mix_target: index.mix_target
       }}
    end
  end

  def analyze(_registry, _index, target), do: {:error, {:invalid_impact_target, target}}

  defp normalize_target(registry, target) do
    matches =
      []
      |> maybe_project(registry, target)
      |> maybe_repository(registry, target)
      |> maybe_application(registry, target)

    case matches do
      [] ->
        {:error, {:unknown_impact_target, target}}

      [%{ambiguous_providers: candidates}] ->
        {:error, {:ambiguous_impact_provider, target, Enum.sort(candidates)}}

      [%{seed_projects: []} = match] ->
        {:error, {:impact_target_outside_selection, match.kind, target}}

      [match] ->
        {:ok, match}

      many ->
        equivalent_target(many, target)
    end
  end

  # Registry, project and application identifiers intentionally live in
  # different namespaces and commonly share the same spelling (for example a
  # repository `core` containing project/app `core`). That is not a meaningful
  # ambiguity when every matching identity denotes the exact same seed set.
  # Preserve hard ambiguity when the spellings would select different work.
  defp equivalent_target(matches, target) do
    ambiguous = Enum.find(matches, &Map.has_key?(&1, :ambiguous_providers))

    cond do
      ambiguous ->
        {:error, {:ambiguous_impact_provider, target, Enum.sort(ambiguous.ambiguous_providers)}}

      Enum.any?(matches, &(&1.seed_projects == [])) ->
        kinds = matches |> Enum.map(& &1.kind) |> Enum.sort()
        {:error, {:ambiguous_impact_target, target, kinds}}

      true ->
        groups = Enum.group_by(matches, &Enum.sort(&1.seed_projects))

        case Map.to_list(groups) do
          [{_seeds, equivalent}] ->
            chosen =
              Enum.min_by(equivalent, fn match ->
                case match.kind do
                  :project -> 0
                  :application -> 1
                  :repository -> 2
                end
              end)

            aliases = equivalent |> Enum.map(& &1.kind) |> Enum.uniq() |> Enum.sort()
            {:ok, Map.put(chosen, :matched_kinds, aliases)}

          _different_seed_sets ->
            kinds = matches |> Enum.map(& &1.kind) |> Enum.sort()
            {:error, {:ambiguous_impact_target, target, kinds}}
        end
    end
  end

  defp maybe_project(matches, registry, target) do
    case Map.fetch(registry.projects, target) do
      {:ok, project} -> [%{kind: :project, id: target, seed_projects: [project.id]} | matches]
      :error -> matches
    end
  end

  defp maybe_repository(matches, registry, target) do
    case Map.fetch(registry.repositories, target) do
      {:ok, repository} ->
        seeds =
          repository.projects
          |> Enum.filter(&Registry.selected?(registry, &1.id))
          |> Enum.map(& &1.id)
          |> Enum.sort()

        [%{kind: :repository, id: target, seed_projects: seeds} | matches]

      :error ->
        matches
    end
  end

  defp maybe_application(matches, registry, target) do
    case Map.get(registry.applications, target) do
      nil ->
        matches

      _providers ->
        case Registry.resolve_dependency(registry, target) do
          {:ok, project} ->
            [%{kind: :application, id: target, seed_projects: [project.id]} | matches]

          {:known_unselected, [project_id]} ->
            [%{kind: :application, id: target, seed_projects: [project_id]} | matches]

          {:known_unselected, candidates} ->
            [%{kind: :application, id: target, ambiguous_providers: candidates, seed_projects: []} | matches]

          {:error, {:ambiguous_application, _app, candidates}} ->
            [%{kind: :application, id: target, ambiguous_providers: candidates, seed_projects: []} | matches]

          {:error, _reason} ->
            matches

          :unknown ->
            matches
        end
    end
  end

  # Include known-unselected candidate edges: the selected consumer's real Mix
  # dependency is known even when the provider lies outside the current view.
  defp reverse_edges(edges) do
    Enum.reduce(edges, %{}, fn edge, acc ->
      providers =
        case edge.classification do
          :managed -> [edge.provider]
          :known_unselected -> edge.candidates
          :external -> []
        end

      Enum.reduce(providers, acc, fn provider, map ->
        Map.update(map, provider, [edge.consumer], fn consumers ->
          [edge.consumer | consumers]
        end)
      end)
    end)
    |> Map.new(fn {provider, consumers} -> {provider, consumers |> Enum.uniq() |> Enum.sort()} end)
  end

  defp traverse([], _reverse), do: {:error, :impact_target_has_no_projects}

  defp traverse(seeds, reverse) do
    seeds = Enum.uniq(seeds) |> Enum.sort()
    visited = MapSet.new(seeds)
    paths = Map.new(seeds, &{&1, [&1]})
    direct = seeds |> Enum.flat_map(&Map.get(reverse, &1, [])) |> Enum.uniq() |> Enum.sort()
    {visited, paths} = bfs(seeds, reverse, visited, paths)

    {:ok,
     %{
       affected: visited |> MapSet.to_list() |> Enum.sort(),
       direct: direct,
       paths: paths |> Enum.sort_by(&elem(&1, 0)) |> Map.new()
     }}
  end

  defp bfs([], _reverse, visited, paths), do: {visited, paths}

  defp bfs([provider | rest], reverse, visited, paths) do
    base_path = Map.fetch!(paths, provider)

    {new_nodes, visited, paths} =
      reverse
      |> Map.get(provider, [])
      |> Enum.sort()
      |> Enum.reduce({[], visited, paths}, fn consumer, {queue, seen, path_map} ->
        if MapSet.member?(seen, consumer) do
          {queue, seen, path_map}
        else
          # Store human-readable consumer -> ... -> target direction.
          path = [consumer | base_path]
          {[consumer | queue], MapSet.put(seen, consumer), Map.put(path_map, consumer, path)}
        end
      end)

    bfs(rest ++ Enum.reverse(new_nodes), reverse, visited, paths)
  end

  defp affected_repositories(registry, project_ids) do
    project_ids
    |> Enum.group_by(fn id -> Registry.project!(registry, id).repository end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {repository, projects} ->
      %{repository: repository, projects: Enum.sort(projects)}
    end)
  end
end
