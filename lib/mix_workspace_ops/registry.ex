defmodule MixWorkspaceOps.Registry do
  @moduledoc "Strict, portable repository and Mix-project identity registry."

  alias MixWorkspaceOps.Binding

  @schema "mix_workspace_ops.registry/v1"
  @project_kinds ~w(standalone workspace_root package tooling)
  @reserved_path_segments ~w(.git .mix_workspace_ops _build deps)

  @enforce_keys [:path, :digest, :repositories, :projects, :applications]
  defstruct [:path, :digest, :repositories, :projects, :applications, bindings: %{}]

  @type project :: %{
          id: String.t(),
          app: String.t(),
          path: String.t(),
          kind: String.t(),
          tags: [String.t()],
          profile: String.t(),
          repository: String.t()
        }
  @type repository :: %{
          id: String.t(),
          github: String.t(),
          default_branch: String.t(),
          projects: [project()]
        }
  @type t :: %__MODULE__{
          path: String.t(),
          digest: String.t(),
          repositories: %{String.t() => repository()},
          projects: %{String.t() => project()},
          applications: %{String.t() => project()},
          bindings: %{String.t() => String.t()}
        }

  @spec schema() :: String.t()
  def schema, do: @schema

  @spec load(String.t()) :: {:ok, t()} | {:error, term()}
  def load(path) do
    path = Path.expand(path)

    with {:ok, bytes} <- File.read(path),
         {:ok, decoded} <- decode(bytes),
         {:ok, repositories} <- parse_registry(decoded),
         {:ok, projects} <- index_unique(repositories, :projects, :id, "project id"),
         {:ok, applications} <- index_unique(repositories, :projects, :app, "application") do
      {:ok,
       %__MODULE__{
         path: path,
         digest: sha256(bytes),
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

  @spec project_for_app(t(), String.t() | atom()) :: {:ok, project()} | :error
  def project_for_app(%__MODULE__{applications: applications}, app) do
    Map.fetch(applications, to_string(app))
  end

  @spec repository!(t(), String.t()) :: repository()
  def repository!(%__MODULE__{repositories: repositories}, id) do
    case Map.fetch(repositories, id) do
      {:ok, repository} -> repository
      :error -> raise ArgumentError, "unknown registry repository #{inspect(id)}"
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

  defp decode(bytes) do
    {:ok, :json.decode(bytes)}
  catch
    kind, reason -> {:error, {:json, kind, reason}}
  end

  defp parse_registry(%{"schema" => @schema, "repositories" => repositories} = raw)
       when map_size(raw) == 2 and is_list(repositories) do
    repositories
    |> parse_list(&parse_repository/1)
    |> then(fn
      {:ok, parsed} -> ensure_unique(parsed, :id, "repository")
      error -> error
    end)
  end

  defp parse_registry(_decoded), do: {:error, :unsupported_registry_schema}

  defp parse_repository(
         %{
           "id" => id,
           "github" => github,
           "default_branch" => default_branch,
           "projects" => projects
         } = raw
       )
       when map_size(raw) == 4 and is_binary(id) and is_binary(github) and
              is_binary(default_branch) and is_list(projects) do
    with :ok <- validate_identifier(id),
         :ok <- validate_github(github),
         :ok <- validate_branch(default_branch),
         {:ok, parsed_projects} <- parse_projects(projects, id) do
      {:ok,
       %{
         id: id,
         github: github,
         default_branch: default_branch,
         projects: parsed_projects
       }}
    end
  end

  defp parse_repository(raw), do: {:error, {:invalid_repository, raw}}

  defp parse_projects(projects, repository_id) do
    projects
    |> parse_list(&parse_project(&1, repository_id))
    |> then(fn
      {:ok, parsed} -> ensure_unique(parsed, :id, "project")
      error -> error
    end)
  end

  defp parse_project(
         %{
           "id" => id,
           "app" => app,
           "path" => path,
           "kind" => kind,
           "tags" => tags,
           "profile" => profile
         } = raw,
         repository_id
       )
       when map_size(raw) == 6 and is_binary(id) and is_binary(app) and is_binary(path) and
              is_binary(kind) and is_list(tags) and is_binary(profile) do
    with :ok <- validate_stable_id(id),
         :ok <- validate_identifier(app),
         :ok <- validate_relative_path(path),
         :ok <- validate_kind(kind),
         :ok <- validate_tags(tags),
         :ok <- validate_stable_id(profile) do
      {:ok,
       %{
         id: id,
         app: app,
         path: path,
         kind: kind,
         tags: Enum.sort(tags),
         profile: profile,
         repository: repository_id
       }}
    end
  end

  defp parse_project(raw, _repository_id), do: {:error, {:invalid_project, raw}}

  defp parse_list(entries, parser) do
    entries
    |> Enum.reduce_while({:ok, []}, fn raw, {:ok, parsed} ->
      case parser.(raw) do
        {:ok, entry} -> {:cont, {:ok, [entry | parsed]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end)
  end

  defp index_unique(repositories, field, key, label) do
    entries = Enum.flat_map(repositories, &Map.fetch!(&1, field))

    case ensure_unique(entries, key, label) do
      {:ok, unique} -> {:ok, Map.new(unique, &{Map.fetch!(&1, key), &1})}
      error -> error
    end
  end

  defp ensure_unique(entries, key, label) do
    duplicates =
      entries
      |> Enum.group_by(&Map.fetch!(&1, key))
      |> Enum.filter(fn {_value, matches} -> length(matches) > 1 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    if duplicates == [],
      do: {:ok, entries},
      else: {:error, {:duplicate_entries, label, duplicates}}
  end

  defp validate_identifier(identifier) do
    if Regex.match?(~r/^[a-z][a-z0-9_]*$/, identifier),
      do: :ok,
      else: {:error, {:invalid_identifier, identifier}}
  end

  defp validate_stable_id(identifier) do
    if Regex.match?(~r/^[a-z][a-z0-9_.-]*$/, identifier),
      do: :ok,
      else: {:error, {:invalid_stable_id, identifier}}
  end

  defp validate_github(github) do
    if Regex.match?(~r/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/, github),
      do: :ok,
      else: {:error, {:invalid_github_identity, github}}
  end

  defp validate_branch(branch) do
    if branch != "" and not String.contains?(branch, ["..", " ", "~", "^", ":"]),
      do: :ok,
      else: {:error, {:invalid_default_branch, branch}}
  end

  defp validate_kind(kind) when kind in @project_kinds, do: :ok
  defp validate_kind(kind), do: {:error, {:invalid_project_kind, kind}}

  defp validate_tags(tags) do
    cond do
      not Enum.all?(tags, &is_binary/1) -> {:error, {:invalid_tags, tags}}
      tags != Enum.uniq(tags) -> {:error, {:duplicate_tags, tags}}
      Enum.any?(tags, &(validate_stable_id(&1) != :ok)) -> {:error, {:invalid_tags, tags}}
      true -> :ok
    end
  end

  defp validate_relative_path(path) do
    expanded = Path.expand(path, "/workspace")
    segments = Path.split(path)

    cond do
      Path.type(path) == :absolute ->
        {:error, {:absolute_registry_path, path}}

      expanded != "/workspace" and not String.starts_with?(expanded, "/workspace/") ->
        {:error, {:escaping_registry_path, path}}

      Enum.any?(segments, &(&1 in @reserved_path_segments)) ->
        {:error, {:reserved_registry_path, path}}

      true ->
        :ok
    end
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
