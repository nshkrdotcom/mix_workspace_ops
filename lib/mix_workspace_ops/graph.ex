defmodule MixWorkspaceOps.Graph do
  @moduledoc """
  Dependency closure derived from authoritative Mix project metadata.

  Only the target's own checkout is required. A dependency whose repository has
  no checkout is a **leaf**: the edge is recorded and its own dependencies are
  not walked, because Mix fetches that dependency and resolves its dependencies
  from its own lock. There is no checkout here to read them from, and reading
  one that is not there is what turned "remove the sibling and it resolves
  GitHub" into a refusal.
  """

  alias MixWorkspaceOps.{Project, Registry}

  @type resolution :: %{
          projects: [Registry.project()],
          edges: [{String.t(), String.t()}],
          external_dependencies: [{String.t(), String.t()}],
          known_unselected: [{String.t(), String.t(), [String.t()]}],
          digest: String.t()
        }

  @spec resolve(Registry.t(), String.t() | atom(), keyword()) ::
          {:ok, resolution()} | {:error, term()}
  def resolve(registry, target, opts \\ []) do
    target = to_string(target)
    reader = Keyword.get(opts, :dependency_reader, &Project.dependencies(registry, &1))
    seeds = seed_projects(registry, target)

    state = %{
      visiting: MapSet.new(),
      visited: MapSet.new(),
      ordered: [],
      edges: [],
      external: [],
      known_unselected: []
    }

    with :ok <- require_target_checkout(registry, seeds),
         {:ok, final} <- visit_seeds(registry, seeds, reader, state) do
      projects = Enum.reverse(final.ordered)
      edges = final.edges |> Enum.uniq() |> Enum.sort()
      external = final.external |> Enum.uniq() |> Enum.sort()
      known_unselected = final.known_unselected |> Enum.uniq() |> Enum.sort()

      {:ok,
       %{
         projects: projects,
         edges: edges,
         external_dependencies: external,
         known_unselected: known_unselected,
         digest: digest(projects, edges, external, known_unselected)
       }}
    end
  rescue
    error in ArgumentError -> {:error, {:registry_target, Exception.message(error)}}
  end

  # Requirement is the operation's question, not the catalog's. The one
  # repository this operation cannot proceed without is the target's own, and it
  # is refused through the mechanism that exists to refuse it, so an operator
  # sees the typed error naming the path rather than a rendered exception.
  defp require_target_checkout(registry, seeds) do
    seeds
    |> Enum.map(& &1.repository)
    |> Enum.uniq()
    |> then(&Registry.require_bound(registry, &1))
  end

  defp seed_projects(registry, target) do
    project = Registry.project!(registry, target)

    if project.kind == "workspace_root" do
      registry
      |> Registry.repository!(project.repository)
      |> Map.fetch!(:projects)
      |> Enum.filter(&Registry.selected?(registry, &1.id))
      |> Enum.sort_by(& &1.id)
    else
      [project]
    end
  end

  defp visit_seeds(registry, seeds, reader, state) do
    Enum.reduce_while(seeds, {:ok, state}, fn project, {:ok, current} ->
      case visit(registry, project.id, reader, current) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp visit(registry, project_id, reader, state) do
    cond do
      MapSet.member?(state.visited, project_id) ->
        {:ok, state}

      MapSet.member?(state.visiting, project_id) ->
        {:error, {:dependency_cycle, project_id}}

      true ->
        project = Registry.project!(registry, project_id)

        case Registry.checkout(registry, project.repository) do
          {:absent, _expected} -> {:ok, leaf(state, project)}
          _reachable -> walk(registry, project, reader, state)
        end
    end
  end

  # An absent checkout ends the walk here. The project is still a closure member
  # and still carries a resolvable source, so resolution decides it exactly as it
  # decides any other dependency — `local` is simply unavailable for it.
  defp leaf(state, project) do
    %{state | visited: MapSet.put(state.visited, project.id), ordered: [project | state.ordered]}
  end

  defp walk(registry, project, reader, state) do
    state = %{state | visiting: MapSet.put(state.visiting, project.id)}

    with {:ok, dependencies} <- reader.(project),
         {:ok, state} <- visit_dependencies(registry, project, dependencies, reader, state) do
      {:ok,
       %{
         state
         | visiting: MapSet.delete(state.visiting, project.id),
           visited: MapSet.put(state.visited, project.id),
           ordered: [project | state.ordered]
       }}
    end
  end

  defp visit_dependencies(registry, project, dependencies, reader, state) do
    Enum.reduce_while(dependencies, {:ok, state}, fn dependency_app, {:ok, current} ->
      reduce_dependency(registry, project, dependency_app, reader, current)
    end)
  end

  # A dependency resolves through the declaring project's own dependency-source
  # table, so a declared `provider` selects among several catalogued providers
  # instead of the closure refusing an ambiguity the catalog already answered.
  defp reduce_dependency(registry, project, dependency_app, reader, current) do
    provider = Registry.declared_provider(registry, project, dependency_app)

    case Registry.resolve_dependency(registry, dependency_app, provider) do
      {:ok, dependency} ->
        reduce_managed_dependency(registry, project, dependency, reader, current)

      {:known_unselected, candidates} ->
        reduce_known_unselected(project, dependency_app, candidates, current)

      {:error, {:ambiguous_application, app, candidates}} ->
        {:halt, {:error, {:ambiguous_application, app, candidates, project.id}}}

      {:error, reason} ->
        {:halt, {:error, {:dependency_provider, project.id, reason}}}

      :unknown ->
        reduce_external_dependency(project, dependency_app, current)
    end
  end

  defp reduce_managed_dependency(registry, project, dependency, reader, current) do
    current = %{current | edges: [{project.id, dependency.id} | current.edges]}

    case visit(registry, dependency.id, reader, current) do
      {:ok, next} -> {:cont, {:ok, next}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp reduce_external_dependency(project, dependency_app, current) do
    next = %{current | external: [{project.id, dependency_app} | current.external]}
    {:cont, {:ok, next}}
  end

  # The catalog provides this application and the selection excludes it. It is
  # reported under its own classification and never joins the external packages,
  # which is what makes a known internal dependency impossible to mistake for a
  # Hex package.
  defp reduce_known_unselected(project, dependency_app, candidates, current) do
    entry = {project.id, dependency_app, candidates}
    {:cont, {:ok, %{current | known_unselected: [entry | current.known_unselected]}}}
  end

  defp digest(projects, edges, external, known_unselected) do
    :json.encode(%{
      projects: Enum.map(projects, & &1.id),
      edges: Enum.map(edges, &Tuple.to_list/1),
      external_dependencies: Enum.map(external, &Tuple.to_list/1),
      known_unselected:
        Enum.map(known_unselected, fn {consumer, app, candidates} ->
          [consumer, app, candidates]
        end)
    })
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
