defmodule MixWorkspaceOps.Catalog do
  @moduledoc "Safe workspace repository and Mix-project coordinate catalog."

  @statuses ~w(pilot deferred weld_owner weld_wedge weld_regression)
  @reserved_path_segments ~w(.git .mix_workspace_ops _build deps)

  @enforce_keys [:path, :root, :digest, :repositories, :projects]
  defstruct [:path, :root, :digest, :repositories, :projects]

  @type project :: %{
          app: String.t(),
          path: String.t(),
          repository: String.t(),
          managed_deps: [String.t()]
        }
  @type repository :: %{
          id: String.t(),
          path: String.t(),
          github: String.t(),
          status: String.t(),
          projects: [project()]
        }
  @type t :: %__MODULE__{
          path: String.t(),
          root: String.t(),
          digest: String.t(),
          repositories: %{String.t() => repository()},
          projects: %{String.t() => project()}
        }

  @spec load(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def load(path, opts \\ []) do
    path = Path.expand(path)
    root = opts |> Keyword.get(:root, Path.dirname(path)) |> Path.expand()

    with {:ok, bytes} <- File.read(path),
         {:ok, decoded} <- decode(bytes),
         {:ok, repositories} <- parse_repositories(decoded),
         {:ok, projects} <- index_projects(repositories),
         :ok <- validate_edges(projects) do
      {:ok,
       %__MODULE__{
         path: path,
         root: root,
         digest: sha256(bytes),
         repositories: Map.new(repositories, &{&1.id, &1}),
         projects: projects
       }}
    end
  end

  @spec load!(String.t(), keyword()) :: t()
  def load!(path, opts \\ []) do
    case load(path, opts) do
      {:ok, catalog} -> catalog
      {:error, reason} -> raise ArgumentError, "invalid workspace catalog: #{inspect(reason)}"
    end
  end

  @spec project!(t(), String.t() | atom()) :: project()
  def project!(%__MODULE__{projects: projects}, app) do
    app = to_string(app)

    case Map.fetch(projects, app) do
      {:ok, project} -> project
      :error -> raise ArgumentError, "unknown catalog project #{inspect(app)}"
    end
  end

  @spec repository!(t(), String.t()) :: repository()
  def repository!(%__MODULE__{repositories: repositories}, id) do
    case Map.fetch(repositories, id) do
      {:ok, repository} -> repository
      :error -> raise ArgumentError, "unknown catalog repository #{inspect(id)}"
    end
  end

  @spec repository_root(t(), repository() | String.t()) :: String.t()
  def repository_root(catalog, repository_id) when is_binary(repository_id) do
    catalog
    |> repository!(repository_id)
    |> then(&repository_root(catalog, &1))
  end

  def repository_root(%__MODULE__{} = catalog, repository) when is_map(repository) do
    Path.expand(repository.path, catalog.root)
  end

  @spec project_root(t(), project() | String.t() | atom()) :: String.t()
  def project_root(catalog, app) when is_binary(app) or is_atom(app) do
    catalog
    |> project!(app)
    |> then(&project_root(catalog, &1))
  end

  def project_root(%__MODULE__{} = catalog, project) when is_map(project) do
    repository = repository!(catalog, project.repository)

    catalog
    |> repository_root(repository.id)
    |> Path.join(project.path)
    |> Path.expand()
  end

  defp decode(bytes) do
    {:ok, :json.decode(bytes)}
  catch
    kind, reason -> {:error, {:json, kind, reason}}
  end

  defp parse_repositories(%{"schema" => 1, "repositories" => repositories})
       when is_list(repositories) do
    repositories
    |> Enum.reduce_while({:ok, []}, fn raw, {:ok, parsed} ->
      case parse_repository(raw) do
        {:ok, repository} -> {:cont, {:ok, [repository | parsed]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, parsed} -> ensure_unique(parsed, :id, "repository")
      error -> error
    end)
  end

  defp parse_repositories(_decoded), do: {:error, :unsupported_catalog_schema}

  defp parse_repository(%{
         "id" => id,
         "path" => path,
         "github" => github,
         "status" => status,
         "projects" => projects
       })
       when is_binary(id) and is_binary(path) and is_binary(github) and is_binary(status) and
              is_list(projects) do
    with :ok <- validate_identifier(id),
         :ok <- validate_relative_path(path),
         :ok <- validate_status(status),
         {:ok, parsed_projects} <- parse_projects(projects, id) do
      {:ok,
       %{
         id: id,
         path: path,
         github: github,
         status: status,
         projects: parsed_projects
       }}
    end
  end

  defp parse_repository(raw), do: {:error, {:invalid_repository, raw}}

  defp parse_projects(projects, repository_id) do
    projects
    |> Enum.reduce_while({:ok, []}, fn raw, {:ok, parsed} ->
      case parse_project(raw, repository_id) do
        {:ok, project} -> {:cont, {:ok, [project | parsed]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, parsed} -> ensure_unique(parsed, :app, "project")
      error -> error
    end)
  end

  defp parse_project(%{"app" => app, "path" => path, "managed_deps" => deps}, repository_id)
       when is_binary(app) and is_binary(path) and is_list(deps) do
    with :ok <- validate_identifier(app),
         :ok <- validate_relative_path(path),
         :ok <- validate_dependencies(deps) do
      {:ok,
       %{
         app: app,
         path: path,
         repository: repository_id,
         managed_deps: deps
       }}
    end
  end

  defp parse_project(raw, _repository_id), do: {:error, {:invalid_project, raw}}

  defp index_projects(repositories) do
    repositories
    |> Enum.flat_map(& &1.projects)
    |> ensure_unique(:app, "workspace project")
    |> case do
      {:ok, projects} -> {:ok, Map.new(projects, &{&1.app, &1})}
      error -> error
    end
  end

  defp validate_edges(projects) do
    missing =
      for {_app, project} <- projects,
          dependency <- project.managed_deps,
          not Map.has_key?(projects, dependency),
          do: {project.app, dependency}

    if missing == [], do: :ok, else: {:error, {:unknown_managed_dependencies, missing}}
  end

  defp validate_dependencies(dependencies) do
    if Enum.all?(dependencies, &(is_binary(&1) and validate_identifier(&1) == :ok)) do
      :ok
    else
      {:error, {:invalid_dependencies, dependencies}}
    end
  end

  defp validate_status(status) when status in @statuses, do: :ok
  defp validate_status(status), do: {:error, {:invalid_status, status}}

  defp validate_identifier(identifier) do
    if Regex.match?(~r/^[a-z][a-z0-9_]*$/, identifier) do
      :ok
    else
      {:error, {:invalid_identifier, identifier}}
    end
  end

  defp validate_relative_path(path) do
    expanded = Path.expand(path, "/workspace")
    segments = Path.split(path)

    cond do
      Path.type(path) == :absolute ->
        {:error, {:absolute_catalog_path, path}}

      expanded != "/workspace" and not String.starts_with?(expanded, "/workspace/") ->
        {:error, {:escaping_catalog_path, path}}

      Enum.any?(segments, &(&1 in @reserved_path_segments)) ->
        {:error, {:reserved_catalog_path, path}}

      true ->
        :ok
    end
  end

  defp ensure_unique(entries, key, label) do
    grouped = Enum.group_by(entries, &Map.fetch!(&1, key))
    duplicates = for {value, matches} <- grouped, length(matches) > 1, do: value

    if duplicates == [] do
      {:ok, Enum.reverse(entries)}
    else
      {:error, {:duplicate_entries, label, Enum.sort(duplicates)}}
    end
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
