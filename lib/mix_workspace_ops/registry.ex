defmodule MixWorkspaceOps.Registry do
  @moduledoc """
  Repository-first catalog of portable identities, classifications, and
  dependency-source declarations.

  A repository is the unit of the catalog. It carries the identity every
  operation needs — remote coordinate, languages, lifecycle, disposition,
  visibility, roles, groups, agent scope — whether or not it builds anything with
  Mix. Mix data is an optional per-repository block, so a repository with no Mix
  project is still catalogued, grouped, and selectable.

  Two schemas load. `portfolio_registry.registry/v2` is current;
  `mix_workspace_ops.registry/v1` still loads and is normalized onto the same
  records.
  """

  alias MixWorkspaceOps.Binding
  alias MixWorkspaceOps.Registry.{Contract, Document, Source, Workspace}
  alias MixWorkspaceOps.StrictJSON

  @enforce_keys [:path, :digest, :schema, :repositories, :projects, :applications]
  defstruct [
    :path,
    :digest,
    :schema,
    :repositories,
    :projects,
    :applications,
    bindings: %{},
    unselected_applications: %{}
  ]

  @type project :: %{
          id: String.t(),
          app: String.t() | nil,
          path: String.t(),
          kind: String.t(),
          provides: [String.t()],
          dependency_sources: %{String.t() => Source.t()},
          repository: String.t()
        }
  @type repository :: %{
          id: String.t(),
          github: String.t(),
          default_branch: String.t(),
          languages: [String.t()],
          lifecycle: String.t(),
          disposition: String.t(),
          visibility: String.t(),
          roles: [String.t()],
          groups: [String.t()],
          agent_scope: String.t(),
          projects: [project()],
          workspace: map() | nil,
          dependency_sources: %{String.t() => Source.t()},
          release_chain: %{String.t() => [String.t()]}
        }
  @type t :: %__MODULE__{
          path: String.t(),
          digest: String.t(),
          schema: String.t(),
          repositories: %{String.t() => repository()},
          projects: %{String.t() => project()},
          applications: %{String.t() => [project()]},
          bindings: %{String.t() => String.t()},
          unselected_applications: %{String.t() => [String.t()]}
        }

  @doc "The schema identifier this version writes."
  @spec schema() :: String.t()
  def schema, do: Document.current_schema()

  @doc "Every schema identifier this version loads, current first."
  @spec schemas() :: [String.t()]
  def schemas, do: Document.schemas()

  @spec load(String.t()) :: {:ok, t()} | {:error, term()}
  def load(path) do
    path = Path.expand(path)

    with {:ok, bytes} <- File.read(path),
         {:ok, decoded} <- StrictJSON.decode(bytes),
         {:ok, {schema, repositories}} <- Document.parse(decoded),
         {:ok, projects} <- index_projects(repositories),
         applications = Contract.index_applications(repositories),
         :ok <- Contract.validate(repositories, applications, schema) do
      {:ok,
       %__MODULE__{
         path: path,
         digest: sha256(bytes),
         schema: schema,
         repositories: Map.new(repositories, &{&1.id, &1}),
         projects: projects,
         applications: applications
       }}
    end
  end

  @spec load!(String.t()) :: t()
  def load!(path) do
    case load(path) do
      {:ok, registry} -> registry
      {:error, reason} -> raise ArgumentError, "invalid workspace registry: #{inspect(reason)}"
    end
  end

  @spec bind(t(), String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def bind(registry, checkout_root, opts \\ []) do
    case Binding.resolve(registry, checkout_root, opts) do
      {:ok, bindings} -> {:ok, %{registry | bindings: bindings}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec project!(t(), String.t() | atom()) :: project()
  def project!(%__MODULE__{projects: projects}, id) do
    id = to_string(id)

    case Map.fetch(projects, id) do
      {:ok, project} -> project
      :error -> raise ArgumentError, "unknown registry project #{inspect(id)}"
    end
  end

  @doc """
  Finds the project providing `app`.

  Returns `{:ambiguous, projects}` where more than one project provides it, so a
  caller must either name a provider or report the candidates. It never picks the
  first match.
  """
  @spec project_for_app(t(), String.t() | atom()) ::
          {:ok, project()} | {:ambiguous, [project()]} | :error
  def project_for_app(%__MODULE__{applications: applications}, app) do
    case Map.get(applications, to_string(app), []) do
      [project] -> {:ok, project}
      [] -> :error
      several -> {:ambiguous, several}
    end
  end

  @doc "Resolves the provider of `app`, honouring an explicit provider project id."
  @spec provider_for(t(), String.t() | atom(), String.t() | nil) ::
          {:ok, project()} | {:error, term()}
  def provider_for(%__MODULE__{applications: applications}, app, provider \\ nil) do
    Contract.resolve_provider(applications, to_string(app), provider)
  end

  @doc """
  Resolves the project a dependency declaration names.

  `provider` is the declaration's explicit provider selection, or `nil`. The
  result distinguishes four outcomes a caller must not conflate:

    * `{:ok, project}` — one selected project provides the application.
    * `{:known_unselected, project_ids}` — the catalog provides the application
      but the current selection excludes every provider. The dependency is
      catalogued, so it is never an ordinary external package.
    * `{:error, reason}` — several providers and no usable selection, or a
      provider naming a project that does not provide the application.
    * `:unknown` — no catalogued project provides it, so it is external.
  """
  @spec resolve_dependency(t(), String.t() | atom(), String.t() | nil) ::
          {:ok, project()} | {:known_unselected, [String.t()]} | {:error, term()} | :unknown
  def resolve_dependency(%__MODULE__{} = registry, app, provider \\ nil) do
    app = to_string(app)

    case Map.get(registry.applications, app, []) do
      [] -> unselected_providers(registry, app)
      _candidates -> Contract.resolve_provider(registry.applications, app, provider)
    end
  end

  @doc """
  The provider selection a project's dependency-source table declares for `app`.

  Returns `nil` where the table carries no entry, which is the ordinary case.
  """
  @spec declared_provider(t(), project() | String.t(), String.t() | atom()) :: String.t() | nil
  def declared_provider(registry, project, app) do
    case Map.fetch(dependency_sources(registry, project), to_string(app)) do
      {:ok, declaration} -> declaration.provider
      :error -> nil
    end
  end

  @doc "Every project providing `app`, sorted by project id."
  @spec providers(t(), String.t() | atom()) :: [project()]
  def providers(%__MODULE__{applications: applications}, app) do
    Map.get(applications, to_string(app), [])
  end

  @doc """
  The derived members of a repository's umbrella or Blitz workspace.

  Membership derives from project metadata; the catalog records only the
  exceptions derivation cannot see.
  """
  @spec workspace_members(t(), repository() | String.t()) ::
          {:ok, [project()]} | {:error, term()}
  defdelegate workspace_members(registry, repository), to: Workspace, as: :members

  @doc "Every repository declaring a workspace, with its derived members."
  @spec workspaces(t()) :: [{repository(), [project()]}]
  defdelegate workspaces(registry), to: Workspace

  @spec repository!(t(), String.t()) :: repository()
  def repository!(%__MODULE__{repositories: repositories}, id) do
    case Map.fetch(repositories, id) do
      {:ok, repository} -> repository
      :error -> raise ArgumentError, "unknown registry repository #{inspect(id)}"
    end
  end

  @doc """
  The dependency-source declarations in effect for a project.

  A repository's table applies to every project in it. A project may declare its
  own entry for an application, which replaces the repository's entry for that
  application alone.
  """
  @spec dependency_sources(t(), project() | String.t()) :: %{String.t() => Source.t()}
  def dependency_sources(registry, project_id) when is_binary(project_id) do
    dependency_sources(registry, project!(registry, project_id))
  end

  def dependency_sources(registry, project) when is_map(project) do
    registry
    |> repository!(project.repository)
    |> Map.fetch!(:dependency_sources)
    |> Map.merge(project.dependency_sources)
  end

  @doc "Repositories carrying every group in `groups`."
  @spec repositories_in_groups(t(), [String.t()]) :: [repository()]
  def repositories_in_groups(%__MODULE__{repositories: repositories}, groups) do
    repositories
    |> Map.values()
    |> Enum.filter(fn repository -> Enum.all?(groups, &(&1 in repository.groups)) end)
    |> Enum.sort_by(& &1.id)
  end

  @spec groups(t()) :: [String.t()]
  def groups(%__MODULE__{repositories: repositories}) do
    repositories |> Map.values() |> Enum.flat_map(& &1.groups) |> Enum.uniq() |> Enum.sort()
  end

  @spec restrict(t(), [project()]) :: t()
  def restrict(%__MODULE__{} = registry, selected_projects) when is_list(selected_projects) do
    selected_ids = MapSet.new(selected_projects, & &1.id)

    repositories =
      registry.repositories
      |> Map.values()
      |> Enum.map(fn repository ->
        %{repository | projects: Enum.filter(repository.projects, &(&1.id in selected_ids))}
      end)
      |> Enum.reject(&(&1.projects == []))
      |> Map.new(&{&1.id, &1})

    applications = Contract.index_applications(Map.values(repositories))

    %{
      registry
      | repositories: repositories,
        projects: Map.new(selected_projects, &{&1.id, &1}),
        applications: applications,
        bindings: Map.take(registry.bindings, Map.keys(repositories)),
        unselected_applications: unselected(registry, applications)
    }
  end

  # Restriction narrows the applications index, so a catalogued application
  # outside the selection would otherwise be indistinguishable from a Hex
  # package. The identities it drops are recorded here so resolution can report
  # them as catalogued-but-unselected instead of external.
  defp unselected(registry, applications) do
    registry.applications
    |> Enum.reject(fn {app, _projects} -> Map.has_key?(applications, app) end)
    |> Map.new(fn {app, projects} -> {app, Enum.map(projects, & &1.id)} end)
    |> then(&Map.merge(registry.unselected_applications, &1))
  end

  defp unselected_providers(registry, app) do
    case Map.fetch(registry.unselected_applications, app) do
      {:ok, project_ids} -> {:known_unselected, project_ids}
      :error -> :unknown
    end
  end

  @spec repository_root(t(), repository() | String.t()) :: String.t()
  def repository_root(registry, repository_id) when is_binary(repository_id) do
    case Map.fetch(registry.bindings, repository_id) do
      {:ok, root} -> root
      :error -> raise ArgumentError, "registry repository #{inspect(repository_id)} is not bound"
    end
  end

  def repository_root(registry, repository) when is_map(repository) do
    repository_root(registry, repository.id)
  end

  @spec project_root(t(), project() | String.t() | atom()) :: String.t()
  def project_root(registry, id) when is_binary(id) or is_atom(id) do
    registry
    |> project!(id)
    |> then(&project_root(registry, &1))
  end

  def project_root(registry, project) when is_map(project) do
    registry
    |> repository_root(project.repository)
    |> Path.join(project.path)
    |> Path.expand()
  end

  defp index_projects(repositories) do
    projects = Enum.flat_map(repositories, & &1.projects)

    duplicates =
      projects
      |> Enum.group_by(& &1.id)
      |> Enum.filter(fn {_id, matches} -> length(matches) > 1 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    if duplicates == [],
      do: {:ok, Map.new(projects, &{&1.id, &1})},
      else: {:error, {:duplicate_entries, "project", duplicates}}
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
