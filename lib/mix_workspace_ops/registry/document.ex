defmodule MixWorkspaceOps.Registry.Document do
  @moduledoc """
  Parses a catalog document into normalized repository records.

  Two schemas are accepted. `portfolio_registry.registry/v2` is the current
  repository-first, language-aware shape. `mix_workspace_ops.registry/v1` is the
  Elixir-only shape it replaces; a v1 document still loads and is normalized onto
  the same records, so a v1 catalog keeps working while it is migrated.
  """

  alias MixWorkspaceOps.Registry.{Source, Workspace}

  @v1 "mix_workspace_ops.registry/v1"
  @v2 "portfolio_registry.registry/v2"

  @repository_required ~w(id github default_branch languages lifecycle disposition visibility
                          roles groups agent_scope)
  @repository_optional ~w(mix dependency_sources release_chain)
  @project_required ~w(id path kind)
  @project_optional ~w(app provides dependency_sources current lineage)

  @project_kinds ~w(standalone workspace_root package tooling generated)
  @lifecycles ~w(active maintenance dormant archived)
  @dispositions ~w(tracked superseded archived intentionally_untracked)
  @visibilities ~w(public private)
  @agent_scopes ~w(eligible restricted never)
  @workspace_kinds ~w(umbrella blitz)
  @reserved_path_segments ~w(.git .mix_workspace_ops _build deps)

  @v1_repository_keys ~w(id github default_branch projects)
  @v1_project_keys ~w(id app path kind tags profile)

  @spec schemas() :: [String.t()]
  def schemas, do: [@v2, @v1]

  @spec current_schema() :: String.t()
  def current_schema, do: @v2

  @spec legacy_schema() :: String.t()
  def legacy_schema, do: @v1

  @spec project_kinds() :: [String.t()]
  def project_kinds, do: @project_kinds

  @doc "Parses a decoded catalog document into `{schema, repositories}`."
  @spec parse(term()) :: {:ok, {String.t(), [map()]}} | {:error, term()}
  def parse(%{"schema" => @v2, "repositories" => repositories} = raw)
      when map_size(raw) == 2 and is_list(repositories) do
    with {:ok, parsed} <- map_ok(repositories, &repository/1),
         :ok <- unique(parsed, :id, "repository") do
      {:ok, {@v2, parsed}}
    end
  end

  def parse(%{"schema" => @v1, "repositories" => repositories} = raw)
      when map_size(raw) == 2 and is_list(repositories) do
    with {:ok, parsed} <- map_ok(repositories, &v1_repository/1),
         :ok <- unique(parsed, :id, "repository") do
      {:ok, {@v1, parsed}}
    end
  end

  def parse(_decoded), do: {:error, :unsupported_registry_schema}

  # -- v2 ------------------------------------------------------------------

  defp repository(raw) when is_map(raw) do
    with :ok <- keys(raw, @repository_required, @repository_optional, :repository),
         :ok <- stable_id(raw["id"]),
         :ok <- github(raw["github"]),
         :ok <- branch(raw["default_branch"]),
         {:ok, identity} <- classification(raw),
         {:ok, mix} <- mix_block(raw["mix"], raw["id"]),
         {:ok, sources} <- Source.parse_table(raw["dependency_sources"] || %{}, raw["id"]),
         {:ok, chain} <- release_chain(raw["release_chain"] || %{}, raw["id"]) do
      {:ok,
       identity
       |> Map.merge(mix)
       |> Map.merge(%{
         id: raw["id"],
         github: raw["github"],
         default_branch: raw["default_branch"],
         dependency_sources: sources,
         release_chain: chain
       })}
    end
  end

  defp repository(raw), do: {:error, {:invalid_repository, raw}}

  defp classification(raw) do
    with {:ok, languages} <- identifier_list(raw["languages"], :languages, min: 1),
         {:ok, roles} <- identifier_list(raw["roles"], :roles, min: 0),
         {:ok, groups} <- identifier_list(raw["groups"], :groups, min: 1),
         :ok <- member(raw["lifecycle"], @lifecycles, :lifecycle),
         :ok <- member(raw["disposition"], @dispositions, :disposition),
         :ok <- member(raw["visibility"], @visibilities, :visibility),
         :ok <- member(raw["agent_scope"], @agent_scopes, :agent_scope) do
      {:ok,
       %{
         languages: languages,
         lifecycle: raw["lifecycle"],
         disposition: raw["disposition"],
         visibility: raw["visibility"],
         roles: roles,
         groups: groups,
         agent_scope: raw["agent_scope"]
       }}
    end
  end

  defp mix_block(nil, _repository_id), do: {:ok, %{projects: [], workspace: nil}}

  defp mix_block(raw, repository_id) when is_map(raw) do
    with :ok <- keys(raw, ~w(projects), ~w(workspace), :mix),
         true <- is_list(raw["projects"]) || {:error, {:invalid_mix_projects, repository_id}},
         {:ok, projects} <- map_ok(raw["projects"], &project(&1, repository_id)),
         :ok <- unique(projects, :id, "project"),
         {:ok, workspace} <- workspace(raw["workspace"], repository_id, projects) do
      {:ok, %{projects: projects, workspace: workspace}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp mix_block(raw, repository_id), do: {:error, {:invalid_mix_block, repository_id, raw}}

  defp project(raw, repository_id) when is_map(raw) do
    app = nullable(raw["app"])

    with :ok <- keys(raw, @project_required, @project_optional, :project),
         :ok <- stable_id(raw["id"]),
         :ok <- relative_path(raw["path"]),
         :ok <- member(raw["kind"], @project_kinds, :project_kind),
         {:ok, provides} <- provides(raw["provides"], app),
         {:ok, current} <- current(raw["current"], raw["id"]),
         :ok <- current_provides_application(current, provides, raw["id"]),
         {:ok, lineage} <- lineage(raw["lineage"], raw["id"]),
         {:ok, sources} <- Source.parse_table(raw["dependency_sources"] || %{}, raw["id"]) do
      {:ok,
       %{
         id: raw["id"],
         app: app,
         path: raw["path"],
         kind: raw["kind"],
         provides: provides,
         current: current,
         lineage: lineage,
         dependency_sources: sources,
         repository: repository_id
       }}
    end
  end

  defp project(raw, repository_id), do: {:error, {:invalid_project, repository_id, raw}}

  defp provides(nil, nil), do: {:ok, []}
  defp provides(nil, app), do: {:ok, [app]}

  defp provides(raw, app) when is_list(raw) do
    with {:ok, provided} <- identifier_list(raw, :provides, min: 0) do
      if is_nil(app) or app in provided,
        do: {:ok, provided},
        else: {:error, {:application_not_provided, app, provided}}
    end
  end

  defp provides(raw, _app), do: {:error, {:invalid_provides, raw}}

  defp current(nil, _project_id), do: {:ok, false}
  defp current(value, _project_id) when is_boolean(value), do: {:ok, value}
  defp current(value, project_id), do: {:error, {:invalid_current_provider, project_id, value}}

  defp current_provides_application(true, [], project_id),
    do: {:error, {:current_without_application, project_id}}

  defp current_provides_application(_current, _provides, _project_id), do: :ok

  defp lineage(nil, _project_id), do: {:ok, nil}

  defp lineage(value, _project_id) when is_binary(value) do
    case stable_id(value) do
      :ok -> {:ok, value}
      {:error, _reason} -> {:error, {:invalid_lineage, value}}
    end
  end

  defp lineage(value, project_id), do: {:error, {:invalid_lineage, project_id, value}}

  defp workspace(nil, _repository_id, _projects), do: {:ok, nil}

  defp workspace(raw, repository_id, projects) when is_map(raw) do
    with :ok <- keys(raw, ~w(kind), ~w(include_project_ids exclude_project_ids), :workspace),
         :ok <- member(raw["kind"], @workspace_kinds, :workspace_kind),
         {:ok, include} <- project_ids(raw["include_project_ids"], projects, repository_id),
         {:ok, exclude} <- project_ids(raw["exclude_project_ids"], projects, repository_id),
         :ok <- disjoint_members(include, exclude, repository_id),
         :ok <- includable_members(include, projects, repository_id) do
      {:ok, %{kind: raw["kind"], include_project_ids: include, exclude_project_ids: exclude}}
    end
  end

  defp workspace(raw, repository_id, _projects),
    do: {:error, {:invalid_workspace, repository_id, raw}}

  defp project_ids(nil, _projects, _repository_id), do: {:ok, []}

  defp project_ids(raw, projects, repository_id) when is_list(raw) do
    known = MapSet.new(projects, & &1.id)
    unknown = Enum.reject(raw, &MapSet.member?(known, &1))

    cond do
      not Enum.all?(raw, &is_binary/1) -> {:error, {:invalid_workspace_members, repository_id}}
      raw != Enum.uniq(raw) -> {:error, {:duplicate_workspace_members, repository_id}}
      unknown != [] -> {:error, {:unknown_workspace_members, repository_id, Enum.sort(unknown)}}
      true -> {:ok, raw}
    end
  end

  defp project_ids(raw, _projects, repository_id),
    do: {:error, {:invalid_workspace_members, repository_id, raw}}

  defp disjoint_members(include, exclude, repository_id) do
    case include -- (include -- exclude) do
      [] -> :ok
      both -> {:error, {:contradictory_workspace_members, repository_id, Enum.sort(both)}}
    end
  end

  # A generated project is build output. Saying it is build output and saying it
  # is a workspace member are contradictory statements about the same project,
  # so the document is refused rather than one of the two being preferred.
  defp includable_members(include, projects, repository_id) do
    generated =
      projects
      |> Enum.filter(&(&1.kind in Workspace.never_member_kinds() and &1.id in include))
      |> Enum.map(& &1.id)
      |> Enum.sort()

    if generated == [],
      do: :ok,
      else: {:error, {:generated_workspace_member, repository_id, generated}}
  end

  defp release_chain(raw, repository_id) when is_map(raw) do
    raw
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, %{}}, fn {package, prerequisites}, {:ok, acc} ->
      case release_edge(package, prerequisites, repository_id) do
        {:ok, edge} -> {:cont, {:ok, Map.put(acc, package, edge)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp release_chain(raw, repository_id),
    do: {:error, {:invalid_release_chain, repository_id, raw}}

  defp release_edge(package, prerequisites, repository_id) do
    with :ok <- identifier(package, :release_package),
         {:ok, parsed} <- identifier_list(prerequisites, :release_prerequisites, min: 0) do
      if package in parsed do
        {:error, {:self_referential_release_edge, repository_id, package}}
      else
        {:ok, parsed}
      end
    end
  end

  # -- v1 ------------------------------------------------------------------

  defp v1_repository(%{"projects" => projects} = raw) when is_map(raw) and is_list(projects) do
    with :ok <- exact_keys(raw, @v1_repository_keys, :repository),
         :ok <- stable_id(raw["id"]),
         :ok <- github(raw["github"]),
         :ok <- branch(raw["default_branch"]),
         {:ok, parsed} <- map_ok(projects, &v1_project(&1, raw["id"])),
         :ok <- unique(parsed, :id, "project") do
      {:ok,
       %{
         id: raw["id"],
         github: raw["github"],
         default_branch: raw["default_branch"],
         languages: ["elixir"],
         lifecycle: "active",
         disposition: "tracked",
         visibility: "public",
         roles: [],
         groups: v1_groups(parsed),
         agent_scope: "eligible",
         projects: parsed,
         workspace: nil,
         dependency_sources: %{},
         release_chain: %{}
       }}
    end
  end

  defp v1_repository(raw), do: {:error, {:invalid_repository, raw}}

  defp v1_groups(projects) do
    case projects |> Enum.flat_map(& &1.tags) |> Enum.uniq() |> Enum.sort() do
      [] -> ["unclassified"]
      groups -> groups
    end
  end

  defp v1_project(raw, repository_id) when is_map(raw) do
    app = nullable(raw["app"])

    with :ok <- exact_keys(raw, @v1_project_keys, :project),
         :ok <- stable_id(raw["id"]),
         :ok <- v1_application(app, raw["kind"]),
         :ok <- relative_path(raw["path"]),
         :ok <- member(raw["kind"], @project_kinds, :project_kind),
         {:ok, tags} <- v1_tags(raw["tags"]),
         :ok <- stable_id(raw["profile"]) do
      {:ok,
       %{
         id: raw["id"],
         app: app,
         path: raw["path"],
         kind: raw["kind"],
         provides: if(is_nil(app), do: [], else: [app]),
         current: false,
         lineage: nil,
         dependency_sources: %{},
         repository: repository_id,
         tags: tags
       }}
    end
  end

  defp v1_project(raw, repository_id), do: {:error, {:invalid_project, repository_id, raw}}

  defp v1_application(nil, kind) when kind in ~w(workspace_root tooling), do: :ok
  defp v1_application(app, _kind) when is_binary(app), do: identifier(app, :application)
  defp v1_application(app, kind), do: {:error, {:invalid_application, app, kind}}

  defp v1_tags(tags) when is_list(tags) do
    cond do
      not Enum.all?(tags, &is_binary/1) -> {:error, {:invalid_tags, tags}}
      tags != Enum.uniq(tags) -> {:error, {:duplicate_tags, tags}}
      Enum.any?(tags, &(stable_id(&1) != :ok)) -> {:error, {:invalid_tags, tags}}
      true -> {:ok, Enum.sort(tags)}
    end
  end

  defp v1_tags(tags), do: {:error, {:invalid_tags, tags}}

  # -- shared --------------------------------------------------------------

  defp keys(raw, required, optional, label) do
    present = Map.keys(raw)

    cond do
      Enum.any?(required, &(&1 not in present)) ->
        {:error, {:missing_keys, label, Enum.sort(required -- present)}}

      present -- (required ++ optional) != [] ->
        {:error, {:unknown_keys, label, Enum.sort(present -- (required ++ optional))}}

      true ->
        :ok
    end
  end

  defp exact_keys(raw, expected, label) do
    if Enum.sort(Map.keys(raw)) == Enum.sort(expected),
      do: :ok,
      else: {:error, {:unexpected_keys, label, Enum.sort(Map.keys(raw))}}
  end

  defp map_ok(entries, parser) do
    entries
    |> Enum.reduce_while({:ok, []}, fn raw, {:ok, acc} ->
      case parser.(raw) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp unique(entries, key, label) do
    duplicates =
      entries
      |> Enum.group_by(&Map.fetch!(&1, key))
      |> Enum.filter(fn {_value, matches} -> length(matches) > 1 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    if duplicates == [], do: :ok, else: {:error, {:duplicate_entries, label, duplicates}}
  end

  defp identifier_list(nil, _field, min: 0), do: {:ok, []}
  defp identifier_list(nil, field, _opts), do: {:error, {:missing_field, field}}

  defp identifier_list(raw, field, opts) when is_list(raw) do
    minimum = Keyword.fetch!(opts, :min)

    cond do
      length(raw) < minimum -> {:error, {:empty_field, field}}
      not Enum.all?(raw, &identifier_value?/1) -> {:error, {:invalid_field, field, raw}}
      raw != Enum.uniq(raw) -> {:error, {:duplicate_field, field, raw}}
      true -> {:ok, Enum.sort(raw)}
    end
  end

  defp identifier_list(raw, field, _opts), do: {:error, {:invalid_field, field, raw}}

  defp member(value, allowed, field) do
    if value in allowed, do: :ok, else: {:error, {:invalid_field, field, value}}
  end

  defp identifier(value, field) do
    if identifier_value?(value), do: :ok, else: {:error, {:invalid_field, field, value}}
  end

  defp identifier_value?(value) when is_binary(value),
    do: Regex.match?(~r/^[a-z][a-z0-9_.-]*$/, value)

  defp identifier_value?(_value), do: false

  defp stable_id(value) do
    if identifier_value?(value), do: :ok, else: {:error, {:invalid_stable_id, value}}
  end

  defp github(value) when is_binary(value) do
    if Regex.match?(~r{^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$}, value),
      do: :ok,
      else: {:error, {:invalid_github_identity, value}}
  end

  defp github(value), do: {:error, {:invalid_github_identity, value}}

  defp branch(value) when is_binary(value) do
    if value != "" and not String.contains?(value, ["..", " ", "~", "^", ":"]),
      do: :ok,
      else: {:error, {:invalid_default_branch, value}}
  end

  defp branch(value), do: {:error, {:invalid_default_branch, value}}

  defp relative_path(path) when is_binary(path) do
    expanded = Path.expand(path, "/workspace")

    cond do
      Path.type(path) == :absolute ->
        {:error, {:absolute_registry_path, path}}

      expanded != "/workspace" and not String.starts_with?(expanded, "/workspace/") ->
        {:error, {:escaping_registry_path, path}}

      Enum.any?(Path.split(path), &(&1 in @reserved_path_segments)) ->
        {:error, {:reserved_registry_path, path}}

      true ->
        :ok
    end
  end

  defp relative_path(path), do: {:error, {:invalid_registry_path, path}}

  defp nullable(:null), do: nil
  defp nullable(value), do: value
end
