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

  ## Selection sits beside the catalog, not in place of it

  A view narrows what an operation acts on. It does not narrow the catalog:
  `select/3` records which repositories and projects a view reached and leaves
  every catalogued record where it was. A pruned catalog would keep the whole
  document's `path` and `digest` while no longer describing that document, so a
  receipt naming the digest would describe a catalog that was never used — and
  because the current schema permits several projects to provide one
  application, pruning could change which project an application resolves to,
  silently, with the same digest on the record.

  The selection carries its own digest. The registry keeps the document's.
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
    :selection,
    bindings: %{},
    absent_checkouts: %{}
  ]

  @type project :: %{
          id: String.t(),
          app: String.t() | nil,
          path: String.t(),
          kind: String.t(),
          provides: [String.t()],
          current: boolean(),
          lineage: String.t() | nil,
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
  @type selection :: %{
          digest: String.t(),
          repository_ids: [String.t()],
          project_ids: [String.t()],
          applications: %{String.t() => [project()]},
          unselected_applications: %{String.t() => [String.t()]}
        }
  @type t :: %__MODULE__{
          path: String.t(),
          digest: String.t(),
          schema: String.t(),
          repositories: %{String.t() => repository()},
          projects: %{String.t() => project()},
          applications: %{String.t() => [project()]},
          selection: selection() | nil,
          bindings: %{String.t() => String.t()},
          absent_checkouts: %{String.t() => String.t()}
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

    with {:ok, bytes} <- File.read(path), do: load_document(bytes, path)
  end

  @doc """
  Loads a catalog document held in memory.

  `path` names where the bytes came from and is carried in the loaded registry;
  nothing is read from it. Every rule a document read from disk must satisfy is
  applied here, so a document assembled from somewhere other than a file is held
  to the same contract.
  """
  @spec load_document(binary(), String.t()) :: {:ok, t()} | {:error, term()}
  def load_document(bytes, path) do
    with {:ok, decoded} <- StrictJSON.decode(bytes),
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

  @doc """
  Binds every catalogued repository against an operator checkout root.

  A repository with no checkout is recorded in `absent_checkouts` with the path
  it was looked for at, and binding continues; a checkout that contradicts the
  catalog is an error. Which repositories an operation cannot proceed without is
  the operation's question, asked through `require_bound/2`.
  """
  @spec bind(t(), String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def bind(registry, checkout_root, opts \\ []) do
    case Binding.resolve(registry, checkout_root, opts) do
      {:ok, report} ->
        {:ok, %{registry | bindings: report.bound, absent_checkouts: report.absent}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  What binding found for one repository.

  `{:bound, root}` for a verified checkout, `{:absent, expected_path}` for a
  catalogued repository with no checkout, and `:unknown` for an id the catalog
  does not carry.
  """
  @spec checkout(t(), repository() | String.t()) ::
          {:bound, String.t()} | {:absent, String.t()} | :unknown
  def checkout(registry, repository) when is_map(repository),
    do: checkout(registry, repository.id)

  def checkout(%__MODULE__{} = registry, repository_id) when is_binary(repository_id) do
    case Map.fetch(registry.bindings, repository_id) do
      {:ok, root} ->
        {:bound, root}

      :error ->
        case Map.fetch(registry.absent_checkouts, repository_id) do
          {:ok, expected} -> {:absent, expected}
          :error -> :unknown
        end
    end
  end

  @doc "Repository ids with a verified checkout, sorted."
  @spec bound_repository_ids(t()) :: [String.t()]
  def bound_repository_ids(%__MODULE__{bindings: bindings}),
    do: bindings |> Map.keys() |> Enum.sort()

  @doc "Repository ids with no checkout, sorted."
  @spec absent_repository_ids(t()) :: [String.t()]
  def absent_repository_ids(%__MODULE__{absent_checkouts: absent}),
    do: absent |> Map.keys() |> Enum.sort()

  @doc """
  Refuses to continue where a repository an operation needs has no checkout.

  Eligibility is what the catalog and the selection permit; requirement is what
  one operation cannot proceed without. Only the second is fatal, and the error
  names the path the checkout was looked for at so an operator can clone it or
  record it in a binding file.
  """
  @spec require_bound(t(), [String.t()]) :: :ok | {:error, term()}
  def require_bound(%__MODULE__{} = registry, repository_ids) do
    repository_ids
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn id, :ok ->
      case checkout(registry, id) do
        {:bound, _root} -> {:cont, :ok}
        {:absent, expected} -> {:halt, {:error, {:absent_required_checkout, id, expected}}}
        :unknown -> {:halt, {:error, {:unknown_repository, id}}}
      end
    end)
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
  Resolves the project a dependency declaration names.

  `provider` is the declaration's explicit provider selection, or `nil`. The
  result distinguishes four outcomes a caller must not conflate:

    * `{:ok, project}` — catalog identity selects one project and the current
      selection permits it.
    * `{:known_unselected, project_ids}` — catalog identity selects the named
      project, but the current selection excludes it. The dependency is
      catalogued, so it is never an ordinary external package and selection
      never substitutes another provider.
    * `{:error, reason}` — several providers and no usable selection, or a
      provider naming a project that does not provide the application.
    * `:unknown` — no catalogued project provides it, so it is external.
  """
  @spec resolve_dependency(t(), String.t() | atom(), String.t() | nil) ::
          {:ok, project()} | {:known_unselected, [String.t()]} | {:error, term()} | :unknown
  def resolve_dependency(
        %__MODULE__{} = registry,
        app,
        provider \\ nil,
        consumer_repository \\ nil
      ) do
    app = to_string(app)

    case Contract.resolve_provider(registry.applications, app, provider, consumer_repository) do
      {:ok, project} ->
        if selected?(registry, project.id),
          do: {:ok, project},
          else: {:known_unselected, [project.id]}

      {:error, {:unprovided_application, ^app}} ->
        :unknown

      {:error, reason} ->
        {:error, reason}
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
  def providers(%__MODULE__{} = registry, app) do
    Map.get(registry.applications, to_string(app), [])
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

  @doc """
  Records which catalogued projects a selection reached.

  The catalog is untouched, and so is what binding found. What comes back is the
  same registry carrying a selection: the repository and project identities the
  view reached, the application index those projects provide, and the catalogued
  applications the selection leaves out, so a dependency on one of them can be
  reported as catalogued-but-unselected instead of being indistinguishable from
  a Hex package.

  Selecting takes nothing away. A selection that pruned what binding found would
  make the third set a subset of whichever selection happened to run first: bind
  two repositories, select one, select both again, and the second repository is
  still unbound though it is on disk and inside the selection. Scoping is a
  question `sets/1` answers at read time, by intersection.
  """
  @spec select(t(), [project()]) :: t()
  def select(%__MODULE__{} = registry, selected_projects) when is_list(selected_projects) do
    selected_repositories =
      selected_projects
      |> Enum.map(&repository!(registry, &1.repository))

    select(registry, selected_projects, selected_repositories)
  end

  @doc "Records the repositories and projects a selection reached independently."
  @spec select(t(), [project()], [repository()]) :: t()
  def select(%__MODULE__{} = registry, selected_projects, selected_repositories)
      when is_list(selected_projects) and is_list(selected_repositories) do
    projects =
      selected_projects
      |> Enum.map(& &1.id)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(&project!(registry, &1))

    project_ids = Enum.map(projects, & &1.id)

    repository_ids =
      (Enum.map(selected_repositories, & &1.id) ++ Enum.map(projects, & &1.repository))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(&repository!(registry, &1))
      |> Enum.map(& &1.id)

    applications = Contract.index_projects(projects)

    selection = %{
      digest: selection_digest(repository_ids, project_ids),
      repository_ids: repository_ids,
      project_ids: project_ids,
      applications: applications,
      unselected_applications: unselected(registry, applications)
    }

    %{registry | selection: selection}
  end

  @doc "What the current selection permits, or `nil` where nothing narrowed the catalog."
  @spec selection(t()) :: selection() | nil
  def selection(%__MODULE__{selection: selection}), do: selection

  @doc "The projects the selection permits, sorted by project id."
  @spec selected_projects(t()) :: [project()]
  def selected_projects(%__MODULE__{selection: nil} = registry),
    do: registry.projects |> Map.values() |> Enum.sort_by(& &1.id)

  def selected_projects(%__MODULE__{selection: selection} = registry),
    do: Enum.map(selection.project_ids, &Map.fetch!(registry.projects, &1))

  @doc """
  The repositories the selection permits, sorted by repository id.

  Each carries only the projects the selection reached, so a caller walking a
  repository's projects sees the selection rather than the catalog. The catalog
  record itself is unchanged and still reachable through `repository!/2`.
  """
  @spec selected_repositories(t()) :: [repository()]
  def selected_repositories(%__MODULE__{selection: nil} = registry),
    do: registry.repositories |> Map.values() |> Enum.sort_by(& &1.id)

  def selected_repositories(%__MODULE__{selection: selection} = registry) do
    permitted = MapSet.new(selection.project_ids)

    Enum.map(selection.repository_ids, fn id ->
      repository = Map.fetch!(registry.repositories, id)

      %{
        repository
        | projects: Enum.filter(repository.projects, &MapSet.member?(permitted, &1.id))
      }
    end)
  end

  @doc "The application index the selection permits."
  @spec selected_applications(t()) :: %{String.t() => [project()]}
  def selected_applications(%__MODULE__{selection: nil} = registry), do: registry.applications
  def selected_applications(%__MODULE__{selection: selection}), do: selection.applications

  @doc "True when the selection permits `project_id`."
  @spec selected?(t(), String.t() | atom()) :: boolean()
  def selected?(%__MODULE__{selection: nil} = registry, project_id),
    do: Map.has_key?(registry.projects, to_string(project_id))

  def selected?(%__MODULE__{selection: selection}, project_id),
    do: to_string(project_id) in selection.project_ids

  @doc """
  The three sets an operator has to be able to tell apart.

  What the catalog holds, what the selection permits, and what is materialized
  on this disk are three different questions with three different answers. One
  number for all three hides which of them is the reason a command found
  nothing to do: a repository can be absent from the catalog, present in the
  catalog and outside the view, or inside the view and not cloned, and the
  remedy differs in each case.

  `materialized` is scoped to the selection, because binding is: it says what
  is on this disk out of what the selection permits.
  """
  @spec sets(t()) :: map()
  def sets(%__MODULE__{} = registry) do
    %{
      catalogued: %{
        digest: registry.digest,
        repositories: map_size(registry.repositories),
        projects: map_size(registry.projects),
        applications: map_size(registry.applications)
      },
      selected: %{
        digest: selection_digest(registry),
        repositories: length(selected_repositories(registry)),
        projects: length(selected_projects(registry)),
        applications: map_size(selected_applications(registry)),
        unselected_applications: unselected_application_ids(registry)
      },
      materialized: %{
        repositories: map_size(materialized(registry, registry.bindings)),
        absent: map_size(materialized(registry, registry.absent_checkouts)),
        absent_repositories:
          registry |> materialized(registry.absent_checkouts) |> Map.keys() |> Enum.sort()
      }
    }
  end

  # What is materialized is a fact about this disk, and the selection is a
  # question asked of it. Intersecting at read time keeps both answerable: the
  # binding is intact for the next, wider selection, and this selection still
  # reports only what it permits.
  defp materialized(%__MODULE__{selection: nil}, found), do: found

  defp materialized(%__MODULE__{selection: selection}, found),
    do: Map.take(found, selection.repository_ids)

  @doc "Catalogued applications the selection leaves out, sorted."
  @spec unselected_application_ids(t()) :: [String.t()]
  def unselected_application_ids(%__MODULE__{selection: nil}), do: []

  def unselected_application_ids(%__MODULE__{selection: selection}),
    do: selection.unselected_applications |> Map.keys() |> Enum.sort()

  # A selection narrows the applications index, so a catalogued application
  # outside it would otherwise be indistinguishable from a Hex package. The
  # identities it leaves out are recorded so resolution can report them as
  # catalogued-but-unselected.
  defp unselected(registry, applications) do
    registry.applications
    |> Enum.reject(fn {app, _projects} -> Map.has_key?(applications, app) end)
    |> Map.new(fn {app, projects} -> {app, Enum.map(projects, & &1.id)} end)
  end

  @doc """
  The digest of the current selection, or `nil` where nothing narrowed the
  catalog.

  Two views over one catalog decide different things, so an artifact that
  attests to what was decided has to name the view as well as the document.
  """
  @spec selection_digest(t()) :: String.t() | nil
  def selection_digest(%__MODULE__{selection: nil}), do: nil
  def selection_digest(%__MODULE__{selection: selection}), do: selection.digest

  defp selection_digest(repository_ids, project_ids) do
    :json.encode(%{repositories: repository_ids, projects: project_ids})
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @spec repository_root(t(), repository() | String.t()) :: String.t()
  def repository_root(registry, repository_id) when is_binary(repository_id) do
    case checkout(registry, repository_id) do
      {:bound, root} ->
        root

      {:absent, expected} ->
        raise ArgumentError,
              "registry repository #{inspect(repository_id)} has no checkout at #{expected}"

      :unknown ->
        raise ArgumentError, "registry repository #{inspect(repository_id)} is not bound"
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
