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
  def packages(%Registry{repositories: repositories}) do
    repositories
    |> Map.values()
    |> Enum.flat_map(&Map.keys(&1.release_chain))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Derives the full prerequisite map for the release train.

  Returns `{:ok, chain}` where `chain` maps each train package to its sorted
  prerequisites, or an error when a package is provided by no project or the
  edges form a cycle.
  """
  @spec derive(Registry.t()) :: {:ok, chain()} | {:error, term()}
  def derive(%Registry{} = registry) do
    train = MapSet.new(packages(registry))

    with {:ok, providers} <- providers(registry, train) do
      chain =
        Map.new(providers, fn {package, project} ->
          {package, prerequisites(registry, package, project, train)}
        end)

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

  defp providers(registry, train) do
    train
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}}, fn package, {:ok, acc} ->
      case Registry.provider_for(registry, package) do
        {:ok, project} -> {:cont, {:ok, Map.put(acc, package, project)}}
        {:error, reason} -> {:halt, {:error, {:release_package, package, reason}}}
      end
    end)
  end

  defp prerequisites(registry, package, project, train) do
    repository = Registry.repository!(registry, project.repository)

    (derived(registry, package, project, repository, train) ++
       Map.get(repository.release_chain, package, []))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp derived(registry, package, project, repository, train) do
    {table, cross_repository_only?} =
      if project.dependency_sources == %{},
        do: {repository.dependency_sources, true},
        else: {project.dependency_sources, false}

    table
    |> Map.keys()
    |> Enum.filter(&MapSet.member?(train, &1))
    |> Enum.reject(&(&1 == package))
    |> Enum.filter(&visible?(registry, &1, project.repository, cross_repository_only?))
  end

  defp visible?(_registry, _app, _repository_id, false), do: true

  defp visible?(registry, app, repository_id, true) do
    case Registry.provider_for(registry, app) do
      {:ok, provider} -> provider.repository != repository_id
      {:error, _reason} -> false
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
