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

  alias MixWorkspaceOps.{MixInputs, Project, Registry}

  @type resolution :: %{
          projects: [Registry.project()],
          edges: [{String.t(), String.t()}],
          dependency_applications: [dependency_application()],
          external_dependencies: [{String.t(), String.t()}],
          known_unselected: [{String.t(), String.t(), [String.t()]}],
          mix_env: String.t(),
          mix_target: String.t(),
          digest: String.t()
        }

  @type dependency_application :: %{
          consumer: String.t(),
          application: String.t(),
          classification: :managed | :known_unselected | :external,
          provider: String.t() | nil,
          candidates: [String.t()]
        }

  @spec resolve(Registry.t(), String.t() | atom(), keyword()) ::
          {:ok, resolution()} | {:error, term()}
  def resolve(registry, target, opts \\ []) do
    target = to_string(target)

    with {:ok, inputs} <- MixInputs.normalize(opts),
         opts = MixInputs.put(opts, inputs),
         reader = Keyword.get(opts, :dependency_reader, &Project.dependencies(registry, &1, opts)),
         state = initial_state(),
         {:ok, seeds} <- seed_projects(registry, target),
         :ok <- require_target_checkout(registry, target),
         {:ok, final} <- visit_seeds(registry, seeds, reader, state) do
      projects = Enum.reverse(final.ordered)
      edges = final.edges |> Enum.uniq() |> Enum.sort()

      dependency_applications =
        final.dependency_applications
        |> Enum.uniq()
        |> Enum.sort_by(&{&1.consumer, &1.application})

      external = final.external |> Enum.uniq() |> Enum.sort()
      known_unselected = final.known_unselected |> Enum.uniq() |> Enum.sort()

      {:ok,
       %{
         projects: projects,
         edges: edges,
         dependency_applications: dependency_applications,
         external_dependencies: external,
         known_unselected: known_unselected,
         mix_env: inputs.mix_env,
         mix_target: inputs.mix_target,
         digest:
           digest(
             projects,
             edges,
             dependency_applications,
             external,
             known_unselected,
             inputs
           )
       }}
    end
  rescue
    error in ArgumentError -> {:error, {:registry_target, Exception.message(error)}}
  end

  defp initial_state do
    %{
      visiting: MapSet.new(),
      visited: MapSet.new(),
      ordered: [],
      edges: [],
      dependency_applications: [],
      external: [],
      known_unselected: []
    }
  end

  # Requirement is the operation's question, not the catalog's. The one
  # repository this operation cannot proceed without is the target's own, and it
  # is refused through the mechanism that exists to refuse it, so an operator
  # sees the typed error naming the path rather than a rendered exception.
  defp require_target_checkout(registry, target) do
    repository = Registry.project!(registry, target).repository
    Registry.require_bound(registry, [repository])
  end

  defp seed_projects(registry, target) do
    project = Registry.project!(registry, target)

    if project.kind == "workspace_root" do
      case Registry.workspace_members(registry, project.repository) do
        {:ok, members} ->
          members = Enum.filter(members, &Registry.selected?(registry, &1.id))

          # The root is not a workspace *member*, but it is still the operation
          # target. Its own Mix project may declare dependencies that no member
          # uses, so the graph must walk it once as well. Keep it last to retain
          # the established member traversal order, and do not duplicate roots
          # explicitly included by a workspace definition.
          {:ok, include_target(members, project)}

        error ->
          error
      end
    else
      {:ok, [project]}
    end
  end

  defp include_target(members, project) do
    if Enum.any?(members, &(&1.id == project.id)), do: members, else: members ++ [project]
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
    case Map.fetch(Registry.dependency_sources(registry, project), dependency_app) do
      {:ok, declaration} ->
        reduce_declared_dependency(
          registry,
          project,
          dependency_app,
          declaration.provider,
          reader,
          current
        )

      :error ->
        reduce_undeclared_dependency(registry, project, dependency_app, reader, current)
    end
  end

  defp reduce_undeclared_dependency(registry, project, dependency_app, reader, current) do
    if Enum.any?(
         Registry.providers(registry, dependency_app),
         &(&1.repository == project.repository)
       ) do
      reduce_declared_dependency(
        registry,
        project,
        dependency_app,
        nil,
        reader,
        current
      )
    else
      reduce_external_dependency(project, dependency_app, current)
    end
  end

  defp reduce_declared_dependency(
         registry,
         project,
         dependency_app,
         provider,
         reader,
         current
       ) do
    case Registry.resolve_dependency(registry, dependency_app, provider, project.repository) do
      {:ok, dependency} ->
        reduce_managed_dependency(
          registry,
          project,
          dependency_app,
          dependency,
          reader,
          current
        )

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

  defp reduce_managed_dependency(
         registry,
         project,
         dependency_app,
         dependency,
         reader,
         current
       ) do
    application =
      dependency_application(project, dependency_app, :managed, dependency.id, [])

    current = %{
      current
      | edges: [{project.id, dependency.id} | current.edges],
        dependency_applications: [application | current.dependency_applications]
    }

    case visit(registry, dependency.id, reader, current) do
      {:ok, next} -> {:cont, {:ok, next}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp reduce_external_dependency(project, dependency_app, current) do
    application = dependency_application(project, dependency_app, :external, nil, [])

    next = %{
      current
      | external: [{project.id, dependency_app} | current.external],
        dependency_applications: [application | current.dependency_applications]
    }

    {:cont, {:ok, next}}
  end

  # The catalog provides this application and the selection excludes it. It is
  # reported under its own classification and never joins the external packages,
  # which is what makes a known internal dependency impossible to mistake for a
  # Hex package.
  defp reduce_known_unselected(project, dependency_app, candidates, current) do
    entry = {project.id, dependency_app, candidates}

    application =
      dependency_application(
        project,
        dependency_app,
        :known_unselected,
        List.first(candidates),
        candidates
      )

    next = %{
      current
      | known_unselected: [entry | current.known_unselected],
        dependency_applications: [application | current.dependency_applications]
    }

    {:cont, {:ok, next}}
  end

  defp dependency_application(project, application, classification, provider, candidates) do
    %{
      consumer: project.id,
      application: application,
      classification: classification,
      provider: provider,
      candidates: candidates
    }
  end

  defp digest(projects, edges, dependency_applications, external, known_unselected, inputs) do
    :json.encode(%{
      mix_env: inputs.mix_env,
      mix_target: inputs.mix_target,
      projects: Enum.map(projects, & &1.id),
      edges: Enum.map(edges, &Tuple.to_list/1),
      dependency_applications:
        Enum.map(dependency_applications, fn dependency ->
          %{
            consumer: dependency.consumer,
            application: dependency.application,
            classification: Atom.to_string(dependency.classification),
            provider: dependency.provider,
            candidates: dependency.candidates
          }
        end),
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
