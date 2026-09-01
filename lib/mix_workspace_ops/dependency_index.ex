defmodule MixWorkspaceOps.DependencyIndex do
  @moduledoc """
  Selected-scope dependency facts derived from authoritative Mix project probes.

  Registry `dependency_sources` rows are used only to resolve an application
  observed by Mix to a portfolio provider. They are never treated as dependency
  declarations.
  """

  alias MixWorkspaceOps.{MixInputs, Project, Registry, Report}
  alias MixWorkspaceOps.Project.ProbeMemo

  @type edge :: %{
          consumer: String.t(),
          application: String.t(),
          classification: :managed | :known_unselected | :external,
          provider: String.t() | nil,
          candidates: [String.t()]
        }

  @type t :: %{
          mix_env: String.t(),
          mix_target: String.t(),
          selected_projects: [String.t()],
          probed_projects: [String.t()],
          absent_projects: [String.t()],
          failed_projects: [map()],
          excluded_projects: [String.t()],
          edges: [edge()],
          external_dependencies: [map()],
          known_unselected: [map()],
          complete: boolean(),
          digest: String.t()
        }

  @spec build(Registry.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def build(%Registry{} = registry, opts \\ []) do
    with {:ok, inputs} <- MixInputs.normalize(opts) do
      opts = MixInputs.put(opts, inputs)
      memo = Keyword.get(opts, :probe_memo, ProbeMemo.new())
      opts = Keyword.put(opts, :probe_memo, memo)
      selected = Registry.selected_projects(registry)
      selected_ids = Enum.map(selected, & &1.id)

      state = %{
        probed: [],
        absent: [],
        failed: [],
        edges: []
      }

      with {:ok, state} <- scan_projects(registry, selected, opts, state) do
        edges = Enum.sort_by(state.edges, &{&1.consumer, &1.application, &1.provider || ""})
        probed = state.probed |> Enum.uniq() |> Enum.sort()
        absent = state.absent |> Enum.uniq() |> Enum.sort()
        failed = Enum.sort_by(state.failed, & &1.project)
        excluded = (Map.keys(registry.projects) -- selected_ids) |> Enum.sort()

        base = %{
          mix_env: inputs.mix_env,
          mix_target: inputs.mix_target,
          selected_projects: Enum.sort(selected_ids),
          probed_projects: probed,
          absent_projects: absent,
          failed_projects: failed,
          excluded_projects: excluded,
          edges: edges,
          external_dependencies:
            for(edge <- edges, edge.classification == :external,
              do: %{consumer: edge.consumer, application: edge.application}
            ),
          known_unselected:
            for(edge <- edges, edge.classification == :known_unselected,
              do: %{
                consumer: edge.consumer,
                application: edge.application,
                candidates: edge.candidates
              }
            ),
          complete: absent == [] and failed == []
        }

        {:ok, Map.put(base, :digest, digest(base))}
      end
    end
  end

  @doc "Classifies one dependency application observed by Mix for one consumer."
  @spec classify_dependency(Registry.t(), Registry.project(), String.t()) ::
          {:ok, edge()} | {:error, term()}
  def classify_dependency(registry, project, application) do
    provider = Registry.declared_provider(registry, project, application)

    case Registry.resolve_dependency(registry, application, provider, project.repository) do
      {:ok, dependency} ->
        {:ok,
         %{
           consumer: project.id,
           application: application,
           classification: :managed,
           provider: dependency.id,
           candidates: []
         }}

      {:known_unselected, candidates} ->
        {:ok,
         %{
           consumer: project.id,
           application: application,
           classification: :known_unselected,
           provider: List.first(candidates),
           candidates: Enum.sort(candidates)
         }}

      :unknown ->
        {:ok,
         %{
           consumer: project.id,
           application: application,
           classification: :external,
           provider: nil,
           candidates: []
         }}

      {:error, reason} ->
        {:error, {:dependency_provider, project.id, application, reason}}
    end
  end

  @spec coverage(t()) :: map()
  def coverage(index) do
    %{
      complete: index.complete,
      selected_project_count: length(index.selected_projects),
      probed_project_count: length(index.probed_projects),
      absent_projects: index.absent_projects,
      failed_projects: index.failed_projects
    }
  end

  defp scan_projects(_registry, [], _opts, state), do: {:ok, state}

  defp scan_projects(registry, [project | rest], opts, state) do
    case Registry.checkout(registry, project.repository) do
      {:absent, _expected} ->
        scan_projects(registry, rest, opts, %{state | absent: [project.id | state.absent]})

      :unknown ->
        scan_projects(registry, rest, opts, %{
          state
          | failed: [%{project: project.id, reason: :unbound_repository} | state.failed]
        })

      {:bound, _root} ->
        case read_dependencies(registry, project, opts) do
          {:ok, dependencies} ->
            case classify_all(registry, project, dependencies) do
              {:ok, edges} ->
                scan_projects(registry, rest, opts, %{
                  state
                  | probed: [project.id | state.probed],
                    edges: edges ++ state.edges
                })

              {:error, reason} ->
                # Provider ambiguity is a dependency-fact failure. Keep the index
                # inspectable/incomplete so affected execution can conservatively
                # widen instead of under-testing.
                scan_projects(registry, rest, opts, %{
                  state
                  | probed: [project.id | state.probed],
                    failed: [%{project: project.id, reason: reason} | state.failed]
                })
            end

          {:error, reason} ->
            scan_projects(registry, rest, opts, %{
              state
              | failed: [%{project: project.id, reason: reason} | state.failed]
            })
        end
    end
  end

  defp read_dependencies(registry, project, opts) do
    case Keyword.get(opts, :dependency_reader) do
      nil ->
        Project.dependencies(registry, project, opts)

      reader when is_function(reader, 2) ->
        reader.(project, opts)

      reader when is_function(reader, 1) ->
        reader.(project)

      invalid ->
        {:error, {:invalid_dependency_reader, invalid}}
    end
  end

  defp classify_all(registry, project, dependencies) do
    dependencies
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn application, {:ok, acc} ->
      case classify_dependency(registry, project, application) do
        {:ok, edge} -> {:cont, {:ok, [edge | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, edges} -> {:ok, Enum.reverse(edges)}
      error -> error
    end
  end

  @doc "Portable dependency/coverage facts suitable for freezing in a plan."
  def portable(index) do
    %{
      mix_env: index.mix_env,
      mix_target: index.mix_target,
      selected_projects: index.selected_projects,
      probed_projects: index.probed_projects,
      absent_projects: index.absent_projects,
      failed_projects:
        Enum.map(index.failed_projects, fn failure ->
          %{project: failure.project, reason: reason_tag(failure.reason)}
        end),
      edges: index.edges,
      complete: index.complete,
      digest: index.digest
    }
  end

  defp digest(index) do
    %{
      mix_env: index.mix_env,
      mix_target: index.mix_target,
      selected_projects: index.selected_projects,
      probed_projects: index.probed_projects,
      absent_projects: index.absent_projects,
      failed_projects:
        Enum.map(index.failed_projects, fn failure ->
          %{project: failure.project, reason: reason_tag(failure.reason)}
        end),
      edges: index.edges,
      complete: index.complete
    }
    |> Report.encode()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp reason_tag(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_tag({tag, _rest}) when is_atom(tag), do: Atom.to_string(tag)
  defp reason_tag({tag, _a, _b}) when is_atom(tag), do: Atom.to_string(tag)
  defp reason_tag({tag, _a, _b, _c}) when is_atom(tag), do: Atom.to_string(tag)
  defp reason_tag(_reason), do: "probe_failure"
end
