defmodule MixWorkspaceOps.Registry.Contract do
  @moduledoc """
  Cross-repository rules a catalog document must satisfy once every repository
  has parsed.

  Application identity and provider selection are separate concepts. Several
  projects may provide one application — a fork, an example, a successor, a
  vendored copy — and that is legal identity, not an error. It becomes an error
  only where a dependency declaration would have to choose between them without
  saying which, and the error names every candidate.
  """

  alias MixWorkspaceOps.Registry.{Document, Source}

  @doc """
  Indexes every provided application to the projects providing it.

  The index is a map of application name to a list of projects sorted by project
  id. A single-element list is the ordinary case; a longer one is legal identity
  awaiting an explicit provider selection.
  """
  @spec index_applications([map()]) :: %{String.t() => [map()]}
  def index_applications(repositories) do
    repositories |> Enum.flat_map(& &1.projects) |> index_projects()
  end

  @doc "Indexes a list of projects to the applications they provide."
  @spec index_projects([map()]) :: %{String.t() => [map()]}
  def index_projects(projects) do
    for project <- projects, app <- project.provides, reduce: %{} do
      acc -> Map.update(acc, app, [project], &[project | &1])
    end
    |> Map.new(fn {app, matches} -> {app, Enum.sort_by(matches, & &1.id)} end)
  end

  @doc "Applies every rule that needs the whole document."
  @spec validate([map()], %{String.t() => [map()]}, String.t()) :: :ok | {:error, term()}
  def validate(repositories, applications, schema) do
    with :ok <- validate_unique_applications(applications, schema),
         :ok <- validate_groups(repositories, schema),
         :ok <- validate_providers(repositories, applications) do
      validate_release_chain(repositories, applications)
    end
  end

  # v1 had one global application namespace and refused a document where two
  # projects provided the same application. v2 replaces that rule with explicit
  # provider selection, but a v1 document still means what it meant, so the rule
  # holds for exactly the schema that stated it.
  defp validate_unique_applications(applications, schema) do
    if schema == Document.legacy_schema() do
      duplicates =
        applications
        |> Enum.filter(fn {_app, projects} -> length(projects) > 1 end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()

      if duplicates == [],
        do: :ok,
        else: {:error, {:duplicate_entries, "application", duplicates}}
    else
      :ok
    end
  end

  @doc """
  Resolves the project providing `app` for a dependency declaration.

  An explicit `provider` selects among candidates. Without one, a single
  candidate resolves and several are an error naming all of them.
  """
  @spec resolve_provider(%{String.t() => [map()]}, String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def resolve_provider(applications, app, provider \\ nil)

  def resolve_provider(applications, app, nil) do
    case Map.get(applications, app, []) do
      [project] -> {:ok, project}
      [] -> {:error, {:unprovided_application, app}}
      several -> {:error, {:ambiguous_application, app, Enum.map(several, & &1.id)}}
    end
  end

  def resolve_provider(applications, app, provider) do
    candidates = Map.get(applications, app, [])

    case Enum.find(candidates, &(&1.id == provider)) do
      nil -> {:error, {:unknown_provider, app, provider, Enum.map(candidates, & &1.id)}}
      project -> {:ok, project}
    end
  end

  defp validate_groups(_repositories, "mix_workspace_ops.registry/v1"), do: :ok

  defp validate_groups(repositories, _schema) do
    total = length(repositories)

    universal =
      repositories
      |> Enum.flat_map(& &1.groups)
      |> Enum.frequencies()
      |> Enum.filter(fn {_group, count} -> total > 1 and count == total end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    if universal == [], do: :ok, else: {:error, {:universal_groups, universal}}
  end

  defp validate_providers(repositories, applications) do
    repositories
    |> Enum.flat_map(&declarations/1)
    |> Enum.reduce_while(:ok, fn {scope, app, declaration}, :ok ->
      case validate_declaration(applications, scope, app, declaration) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp declarations(repository) do
    repository_scoped =
      for {app, declaration} <- repository.dependency_sources,
          do: {repository.id, app, declaration}

    project_scoped =
      for project <- repository.projects,
          {app, declaration} <- project.dependency_sources,
          do: {project.id, app, declaration}

    repository_scoped ++ project_scoped
  end

  defp validate_declaration(applications, scope, app, declaration) do
    if Source.reaches?(declaration, "local") or
         Source.reaches_while_publishing?(declaration, "local") do
      case resolve_provider(applications, app, declaration.provider) do
        {:ok, _project} -> :ok
        {:error, reason} -> {:error, {:dependency_source, scope, reason}}
      end
    else
      validate_unused_provider(scope, app, declaration)
    end
  end

  defp validate_unused_provider(_scope, _app, %{provider: nil}), do: :ok

  defp validate_unused_provider(scope, app, _declaration),
    do: {:error, {:provider_without_local_source, scope, app}}

  defp validate_release_chain(repositories, applications) do
    repositories
    |> Enum.flat_map(fn repository ->
      for {package, prerequisites} <- repository.release_chain,
          do: {repository, package, prerequisites}
    end)
    |> Enum.reduce_while(:ok, fn {repository, package, prerequisites}, :ok ->
      case validate_release_edge(repository, package, prerequisites, applications) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_release_edge(repository, package, prerequisites, applications) do
    provided = Enum.flat_map(repository.projects, & &1.provides)
    missing = Enum.reject(prerequisites, &Map.has_key?(applications, &1))

    cond do
      package not in provided ->
        {:error, {:release_package_not_provided, repository.id, package}}

      missing != [] ->
        {:error, {:missing_release_prerequisite, package, Enum.sort(missing)}}

      true ->
        :ok
    end
  end
end
