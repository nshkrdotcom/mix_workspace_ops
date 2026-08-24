defmodule MixWorkspaceOps.Registry.ReleaseChain do
  @moduledoc """
  The order in which catalogued packages are published.

  Membership of the release train is declared: a package is in the train when the
  repository providing it lists the package in `release_chain`. Edges are then
  derived from the dependency-source declarations wherever derivation can see
  them, and stated explicitly only where it cannot.

  Derivation sees a cross-repository edge, because a repository's dependency
  table names the applications that repository consumes from elsewhere. It does
  not see an edge between two packages of the same repository, because a
  repository-scoped table does not say which of its projects consumes an entry.
  A project that declares its own table restores that attribution; otherwise the
  intra-repository edge is recorded in `release_chain`.
  """

  alias MixWorkspaceOps.Registry

  @type chain :: %{String.t() => [String.t()]}

  @doc "The declared release train: every package with a `release_chain` entry."
  @spec packages(Registry.t()) :: [String.t()]
  def packages(%Registry{} = registry) do
    registry
    |> Registry.selected_repositories()
    |> Enum.flat_map(&Map.keys(&1.release_chain))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Derives the full prerequisite map for the release train.

  Returns `{:ok, chain}` where `chain` maps each train package to its sorted
  prerequisites, or an error when a package is provided by no project, when the
  current selection excludes every provider of one, or when the edges form a
  cycle.
  """
  @spec derive(Registry.t()) :: {:ok, chain()} | {:error, term()}
  def derive(%Registry{} = registry) do
    train = MapSet.new(packages(registry))

    with {:ok, providers} <- providers(registry, train),
         {:ok, chain} <- chain(registry, providers, train) do
      case cycles(chain) do
        [] -> {:ok, chain}
        found -> {:error, {:release_chain_cycle, found}}
      end
    end
  end

  @doc "Prerequisites of `package` and everything they require, in publish order."
  @spec order(Registry.t(), String.t() | nil) :: {:ok, [String.t()]} | {:error, term()}
  def order(%Registry{} = registry, package \\ nil) do
    with {:ok, chain} <- derive(registry) do
      case package do
        nil -> {:ok, topological(chain, Map.keys(chain))}
        package when is_map_key(chain, package) -> {:ok, topological(chain, [package])}
        package -> {:error, {:unknown_release_package, package}}
      end
    end
  end

  defp chain(registry, providers, train) do
    providers
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, %{}}, fn {package, project}, {:ok, acc} ->
      case prerequisites(registry, package, project, train) do
        {:ok, required} -> {:cont, {:ok, Map.put(acc, package, required)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # A train package the current selection excludes is catalogued, so it is named
  # as unselected rather than as an application nothing provides. The two are
  # different facts and lead to different corrections: widen the view, or
  # catalogue the package.
  defp providers(registry, train) do
    train
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}}, fn package, {:ok, acc} ->
      case Registry.resolve_dependency(registry, package) do
        {:ok, project} ->
          {:cont, {:ok, Map.put(acc, package, project)}}

        {:known_unselected, project_ids} ->
          {:halt, {:error, {:unselected_release_package, package, project_ids}}}

        {:error, reason} ->
          {:halt, {:error, {:release_package, package, reason}}}

        :unknown ->
          {:halt, {:error, {:release_package, package, {:unprovided_application, package}}}}
      end
    end)
  end

  defp prerequisites(registry, package, project, train) do
    repository = Registry.repository!(registry, project.repository)

    with {:ok, derived} <- derived(registry, package, project, repository, train) do
      {:ok,
       (derived ++ Map.get(repository.release_chain, package, []))
       |> Enum.uniq()
       |> Enum.sort()}
    end
  end

  defp derived(registry, package, project, repository, train) do
    {table, cross_repository_only?} =
      if project.dependency_sources == %{},
        do: {repository.dependency_sources, true},
        else: {project.dependency_sources, false}

    table
    |> Enum.filter(fn {app, _declaration} ->
      MapSet.member?(train, app) and app != package
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, []}, fn {app, declaration}, {:ok, acc} ->
      case visible?(registry, app, declaration, project.repository, cross_repository_only?) do
        {:ok, true} -> {:cont, {:ok, [app | acc]}}
        {:ok, false} -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, {:release_prerequisite, package, app, reason}}}
      end
    end)
  end

  defp visible?(_registry, _app, _declaration, _repository_id, false), do: {:ok, true}

  # A repository-scoped table cannot attribute an entry to one of its own
  # projects, so an entry provided from inside the repository is not an edge.
  # The declaration's own provider selection answers the question where several
  # projects provide the application; an unresolved provider is an error, never
  # a dropped edge.
  #
  # A prerequisite every provider of which lies outside the selection is
  # catalogued, and its repository is unknown, so whether it is an edge cannot
  # be answered. Answering `false` would publish a package ahead of something it
  # requires, which is the failure a derived order exists to prevent, so it is
  # an error. Nothing reaches that clause while `providers/2` resolves the whole
  # train first, since every application arriving here is a train package that
  # already resolved; `providers/2` states the same decision where it is
  # reachable.
  defp visible?(registry, app, declaration, repository_id, true) do
    case Registry.resolve_dependency(registry, app, declaration.provider) do
      {:ok, provider} -> {:ok, provider.repository != repository_id}
      {:known_unselected, project_ids} -> {:error, {:unselected_provider, app, project_ids}}
      {:error, reason} -> {:error, reason}
      :unknown -> {:error, {:unprovided_application, app}}
    end
  end

  defp cycles(chain) do
    chain
    |> Map.keys()
    |> Enum.filter(&reaches_itself?(chain, &1))
    |> Enum.sort()
  end

  defp reaches_itself?(chain, package) do
    walk(chain, Map.get(chain, package, []), %{}, package)
  end

  @spec walk(chain(), [String.t()], %{String.t() => true}, String.t()) :: boolean()
  defp walk(chain, queue, seen, target) do
    case queue do
      [] ->
        false

      [^target | _rest] ->
        true

      [next | rest] when is_map_key(seen, next) ->
        walk(chain, rest, seen, target)

      [next | rest] ->
        walk(chain, Map.get(chain, next, []) ++ rest, Map.put(seen, next, true), target)
    end
  end

  defp topological(chain, roots) do
    {ordered, _seen} =
      roots
      |> Enum.sort()
      |> Enum.reduce({[], %{}}, fn package, acc -> emit(chain, package, acc) end)

    Enum.reverse(ordered)
  end

  @spec emit(chain(), String.t(), {[String.t()], %{String.t() => true}}) ::
          {[String.t()], %{String.t() => true}}
  defp emit(chain, package, {ordered, seen}) do
    if Map.has_key?(seen, package) do
      {ordered, seen}
    else
      {ordered, seen} =
        chain
        |> Map.get(package, [])
        |> Enum.sort()
        |> Enum.reduce({ordered, Map.put(seen, package, true)}, fn prerequisite, acc ->
          emit(chain, prerequisite, acc)
        end)

      {[package | ordered], seen}
    end
  end
end
