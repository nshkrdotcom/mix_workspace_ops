defmodule MixWorkspaceOps.Discovery do
  @moduledoc "Discovers canonical Git repositories and Mix projects without embedding ecosystem policy."

  alias MixWorkspaceOps.{Binding, Command, Git, Project}

  @pruned_directories ~w(.git .github .worktrees .cache _build _legacy deps deps_legacy_* doc cover dist node_modules priv_plts temp tmp backup backups build_support vendor vendored test priv fixtures templates)

  @spec scan(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def scan(checkout_root, github_owner) do
    checkout_root = Path.expand(checkout_root)

    with {:ok, entries} <- File.ls(checkout_root) do
      {repositories, unresolved} =
        entries
        |> Enum.sort()
        |> Enum.map(&Path.join(checkout_root, &1))
        |> Enum.filter(&File.dir?/1)
        |> Task.async_stream(&discover_checkout(&1, github_owner),
          max_concurrency: 4,
          ordered: false,
          timeout: :infinity
        )
        |> Enum.reduce({[], []}, &collect_checkout/2)

      {repositories, repository_duplicates} = reject_duplicate_repositories(repositories)
      {repositories, application_duplicates} = reject_duplicate_applications(repositories)

      {:ok,
       %{
         registry: %{
           schema: "mix_workspace_ops.registry/v1",
           repositories: Enum.sort_by(repositories, & &1["id"])
         },
         snapshot: %{
           schema: "portfolio_registry.snapshot/v1",
           observed_on: "2026-08-11",
           github_owner: github_owner,
           repositories: length(repositories),
           projects: Enum.sum(Enum.map(repositories, &length(&1["projects"]))),
           unresolved:
             Enum.sort_by(
               unresolved ++ repository_duplicates ++ application_duplicates,
               &{&1["repository"], &1["path"]}
             )
         }
       }}
    end
  end

  defp discover_checkout(path, owner) do
    case canonical_identity(path, owner) do
      {:ok, identity} -> discover_repository(path, identity)
      {:ambiguous_owner_identity, identities} -> {:unresolved, [ambiguity(path, identities)]}
      :skip -> :skip
    end
  rescue
    _error -> :skip
  catch
    _kind, _reason -> :skip
  end

  defp collect_checkout({:ok, :skip}, accumulator), do: accumulator

  defp collect_checkout({:ok, {:resolved, repository, errors}}, {repositories, unresolved}) do
    {[repository | repositories], errors ++ unresolved}
  end

  defp collect_checkout({:ok, {:unresolved, errors}}, {repositories, unresolved}) do
    {repositories, errors ++ unresolved}
  end

  defp canonical_identity(path, owner) do
    with true <- File.dir?(Path.join(path, ".git")),
         {:ok, root} <- Git.root(path),
         true <- root == path,
         {:ok, common_dir} <- Git.common_dir(path),
         true <- common_dir == Path.join(path, ".git"),
         {:ok, github} <- owned_identity(path, owner),
         [^owner, repository_name] <- String.split(github, "/"),
         true <- Path.basename(path) == repository_name do
      {:ok, %{github: github, repository_name: repository_name}}
    else
      {:ambiguous, identities} -> {:ambiguous_owner_identity, identities}
      _reason -> :skip
    end
  end

  # A checkout naming two of the owner's repositories on its origin states two
  # identities. Taking the first would let the directory name decide which, so
  # the checkout is reported unresolved and the operator settles it.
  defp owned_identity(path, owner) do
    case Enum.filter(Binding.github_identities(path), &String.starts_with?(&1, owner <> "/")) do
      [identity] -> {:ok, identity}
      [] -> :skip
      several -> {:ambiguous, several}
    end
  end

  defp ambiguity(path, identities) do
    %{
      "repository" => Path.basename(path),
      "path" => ".",
      "reason" => "ambiguous_owner_identity:#{Enum.join(identities, ",")}"
    }
  end

  defp discover_repository(path, identity) do
    mix_files = find_mix_files(path)

    if mix_files == [] do
      :skip
    else
      repository_id = stable_identifier(identity.repository_name)
      {projects, project_errors} = discover_projects(path, repository_id, mix_files)

      repository = %{
        "id" => repository_id,
        "github" => identity.github,
        "default_branch" => default_branch(path),
        "projects" => projects
      }

      errors =
        Enum.map(project_errors, fn {relative_path, category} ->
          %{
            "repository" => identity.github,
            "path" => relative_path,
            "reason" => category
          }
        end)

      if projects == [],
        do: {:unresolved, errors},
        else: {:resolved, repository, errors}
    end
  end

  defp discover_projects(repository_root, repository_id, mix_files) do
    project_paths = Enum.map(mix_files, &Path.dirname/1)
    workspace_root? = workspace_root?(repository_root, project_paths)

    project_paths
    |> Enum.map(fn project_path ->
      discover_project(repository_root, repository_id, project_path, workspace_root?)
    end)
    |> Enum.reduce({[], []}, fn
      {:ok, project}, {projects, errors} -> {[project | projects], errors}
      {:error, error}, {projects, errors} -> {projects, [error | errors]}
    end)
    |> then(fn {projects, errors} -> {Enum.sort_by(projects, & &1["id"]), errors} end)
  end

  defp discover_project(repository_root, repository_id, project_path, workspace_root?) do
    relative_path = Path.relative_to(project_path, repository_root)

    case Project.metadata_at(project_path) do
      {:ok, metadata} ->
        project_id =
          if is_binary(metadata.app) and (workspace_root? or relative_path != "."),
            do: "#{repository_id}.#{metadata.app}",
            else: repository_id

        if is_nil(metadata.app) and relative_path != "." do
          {:error, {relative_path, "non_application_nested_mix_project"}}
        else
          {:ok,
           %{
             "id" => project_id,
             "app" => metadata.app,
             "path" => relative_path,
             "kind" => project_kind(relative_path, workspace_root?),
             "tags" => ["ecosystem"],
             "profile" => "default"
           }}
        end

      {:error, _reason} ->
        {:error, {relative_path, "mix_metadata_unavailable"}}
    end
  end

  defp workspace_root?(repository_root, project_paths) do
    Enum.any?(project_paths, fn project_path ->
      relative_path = Path.relative_to(project_path, repository_root)
      relative_path != "." and not example_project_path?(relative_path)
    end)
  end

  defp example_project_path?(relative_path) do
    "examples" in Path.split(relative_path)
  end

  defp find_mix_files(root) do
    prune_expression =
      @pruned_directories
      |> Enum.flat_map(&["-name", &1, "-o"])
      |> Enum.drop(-1)

    arguments =
      [root, "-maxdepth", "6", "("] ++
        prune_expression ++
        [")", "-type", "d", "-prune", "-o", "-type", "f", "-name", "mix.exs", "-print"]

    case Command.run("find", arguments) do
      {:ok, result} -> result.output |> String.split("\n", trim: true) |> Enum.sort()
      {:error, _reason} -> []
    end
  end

  defp reject_duplicate_applications(repositories) do
    applications =
      for repository <- repositories,
          project <- repository["projects"],
          is_binary(project["app"]),
          do: %{
            app: project["app"],
            repository: repository["id"],
            project: project["id"],
            path: project["path"]
          }

    duplicates =
      applications
      |> Enum.group_by(& &1.app)
      |> Enum.filter(fn {_app, rows} -> length(rows) > 1 end)
      |> Map.new()

    {rejected, unresolved} = resolve_application_duplicates(duplicates)

    filtered =
      repositories
      |> Enum.map(fn repository ->
        Map.update!(
          repository,
          "projects",
          &Enum.reject(&1, fn project ->
            MapSet.member?(rejected, {repository["id"], project["id"]})
          end)
        )
      end)
      |> Enum.reject(&(&1["projects"] == []))

    {filtered, unresolved}
  end

  defp resolve_application_duplicates(duplicates) do
    Enum.reduce(duplicates, {MapSet.new(), []}, fn {app, rows}, {rejected, unresolved} ->
      canonical = Enum.filter(rows, &canonical_standalone?(&1, app))

      case canonical do
        [%{project: canonical_project} = selected] ->
          shadowed = Enum.reject(rows, &(&1 == selected))

          {
            reject_rows(rejected, shadowed),
            duplicate_evidence(
              unresolved,
              shadowed,
              "shadowed_application:#{app}:#{canonical_project}"
            )
          }

        _ambiguous ->
          {
            reject_rows(rejected, rows),
            duplicate_evidence(unresolved, rows, "duplicate_application:#{app}")
          }
      end
    end)
  end

  defp canonical_standalone?(row, app) do
    row.repository == app and row.project == app and row.path == "."
  end

  defp reject_rows(rejected, rows) do
    Enum.reduce(rows, rejected, &MapSet.put(&2, {&1.repository, &1.project}))
  end

  defp duplicate_evidence(unresolved, rows, reason) do
    Enum.reduce(rows, unresolved, fn row, evidence ->
      [
        %{
          "repository" => row.repository,
          "path" => row.path,
          "reason" => reason
        }
        | evidence
      ]
    end)
  end

  defp reject_duplicate_repositories(repositories) do
    duplicates =
      repositories
      |> Enum.group_by(& &1["id"])
      |> Enum.filter(fn {_id, rows} -> length(rows) > 1 end)
      |> Map.new()

    duplicate_ids = duplicates |> Map.keys() |> MapSet.new()
    filtered = Enum.reject(repositories, &MapSet.member?(duplicate_ids, &1["id"]))

    unresolved =
      for {id, rows} <- duplicates,
          repository <- rows,
          do: %{
            "repository" => repository["github"],
            "path" => ".",
            "reason" => "duplicate_repository_identity:#{id}"
          }

    {filtered, unresolved}
  end

  defp project_kind(".", true), do: "workspace_root"
  defp project_kind(".", false), do: "standalone"
  defp project_kind(_relative_path, _workspace?), do: "package"

  defp default_branch(path) do
    case Command.run("git", ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], cd: path) do
      {:ok, result} -> result.output |> String.trim() |> String.replace_prefix("origin/", "")
      {:error, _result} -> fallback_branch(path)
    end
  end

  defp fallback_branch(path) do
    cond do
      remote_branch_exists?(path, "main") -> "main"
      remote_branch_exists?(path, "master") -> "master"
      Git.branch!(path) == "" -> "main"
      true -> Git.branch!(path)
    end
  end

  defp remote_branch_exists?(path, branch) do
    match?(
      {:ok, _result},
      Command.run("git", ["show-ref", "--verify", "--quiet", "refs/remotes/origin/#{branch}"],
        cd: path
      )
    )
  end

  defp stable_identifier(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_.-]+/, "-")
    |> String.trim("-")
  end
end
