defmodule MixWorkspaceOps.Discovery do
  @moduledoc "Discovers canonical Git repositories and Mix projects without embedding ecosystem policy."

  alias MixWorkspaceOps.{Command, Git, Project, RemoteIdentity}

  @pruned_directories ~w(.git .github .worktrees .cache _build _legacy deps deps_legacy_* doc cover dist node_modules priv_plts temp tmp backup backups build_support vendor vendored test priv fixtures templates)

  @spec scan(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def scan(checkout_root, github_owner, opts \\ []) do
    checkout_root = Path.expand(checkout_root)

    with {:ok, inventory} <- inventory(checkout_root, opts) do
      candidates = candidate_checkouts(inventory.entries, github_owner)

      {repositories, unresolved} =
        candidates
        |> async_results(&discover_candidate/1,
          max_concurrency: Keyword.get(opts, :max_concurrency, 4),
          ordered: true,
          timeout: Keyword.get(opts, :timeout, :infinity),
          on_timeout: :kill_task
        )
        |> Enum.zip(candidates)
        |> Enum.reduce({[], inventory_failures(inventory.entries)}, &collect_candidate/2)

      {repositories, repository_duplicates} = reject_duplicate_repositories(repositories)
      {repositories, application_duplicates} = reject_duplicate_applications(repositories)

      {:ok,
       %{
         schema: "mix_workspace_ops.discovery/v1",
         registry: %{
           # These are observed identity candidates, not a portable registry:
           # v2 requires portfolio-owned classification fields discovery cannot
           # infer without inventing policy.
           schema: "mix_workspace_ops.discovery_candidates/v1",
           repositories: Enum.sort_by(repositories, & &1["id"])
         },
         snapshot: %{
           schema: "portfolio_registry.snapshot/v1",
           observed_on: inventory.observed_on,
           github_owner: github_owner,
           repositories: length(repositories),
           projects: Enum.sum(Enum.map(repositories, &length(&1["projects"]))),
           entries: inventory.entries,
           summary: inventory.summary,
           unresolved:
             Enum.sort_by(
               unresolved ++ repository_duplicates ++ application_duplicates,
               &{&1["repository"], &1["path"]}
             )
         }
       }}
    end
  end

  @doc "Inventories every direct child without making Mix eligibility repository identity."
  @spec inventory(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def inventory(checkout_root, opts \\ []) do
    checkout_root = Path.expand(checkout_root)

    with {:ok, observed_on} <- observation_date(Keyword.get(opts, :clock, &Date.utc_today/0)),
         {:ok, names} <- File.ls(checkout_root) do
      paths = names |> Enum.sort() |> Enum.map(&Path.join(checkout_root, &1))
      inspector = Keyword.get(opts, :mix_inspector, &inspect_mix/1)

      entries =
        paths
        |> async_results(&protected_inspect(&1, inspector),
          max_concurrency: Keyword.get(opts, :max_concurrency, 4),
          ordered: true,
          timeout: Keyword.get(opts, :timeout, :infinity),
          on_timeout: :kill_task
        )
        |> Enum.zip(paths)
        |> Enum.map(&inventory_result/1)

      {:ok,
       %{
         schema: "portfolio_registry.snapshot/v1",
         observed_on: observed_on,
         checkout_root: checkout_root,
         entries: entries,
         summary: inventory_summary(entries)
       }}
    end
  end

  defp async_results(enumerable, function, options) do
    {:ok, supervisor} = Task.Supervisor.start_link()

    try do
      supervisor
      |> Task.Supervisor.async_stream_nolink(enumerable, function, options)
      |> Enum.to_list()
    after
      Supervisor.stop(supervisor)
    end
  end

  defp protected_inspect(path, inspector) do
    inspect_checkout(path, inspector)
  rescue
    error -> failed(path, {:exception, error.__struct__, Exception.message(error)})
  catch
    kind, reason -> failed(path, {kind, reason})
  end

  defp inventory_result({{:ok, entry}, _path}), do: entry
  defp inventory_result({{:exit, reason}, path}), do: failed(path, {:task_exit, reason})

  defp inspect_checkout(path, _inspector) when not is_binary(path),
    do: failed(inspect(path), :invalid_path)

  defp inspect_checkout(path, inspector) do
    if File.dir?(path),
      do: inspect_directory(path, inspector),
      else: not_a_repository(path, :not_a_directory)
  end

  defp inspect_directory(path, inspector) do
    case Git.root(path) do
      {:ok, ^path} -> inspect_git_checkout(path, Path.join(path, ".git"), inspector)
      {:ok, root} -> not_a_repository(path, {:nested_git_root, root})
      {:error, reason} -> classify_git_failure(path, reason)
    end
  end

  defp classify_git_failure(path, reason) do
    case File.lstat(Path.join(path, ".git")) do
      {:ok, _stat} -> failed(path, reason)
      {:error, :enoent} -> not_a_repository(path, reason)
      {:error, marker_reason} -> failed(path, {:git_marker, marker_reason, reason})
    end
  end

  defp inspect_git_checkout(path, marker, inspector) do
    with {:ok, common_dir} <- Git.common_dir(path),
         {:ok, remotes} <- Git.remote_urls(path),
         {:ok, identities} <- RemoteIdentity.hosted_identities(remotes),
         {:ok, mix_files} <- inspector.(path) do
      %{
        "path" => path,
        "name" => Path.basename(path),
        "status" => "discovered",
        "kind" => if(File.dir?(marker), do: "clone", else: "worktree"),
        "common_dir" => common_dir,
        "remotes" => remotes,
        "identities" => identities,
        "mix_files" => Enum.map(mix_files, &Path.relative_to(&1, path))
      }
    else
      {:error, reason} -> failed(path, reason)
      other -> failed(path, {:invalid_mix_inspector_result, other})
    end
  end

  defp inspect_mix(path), do: find_mix_files_result(path)

  defp observation_date(clock) when is_function(clock, 0) do
    case clock.() do
      %Date{} = date -> {:ok, Date.to_iso8601(date)}
      %DateTime{} = datetime -> {:ok, datetime |> DateTime.to_date() |> Date.to_iso8601()}
      other -> {:error, {:invalid_observation_clock, other}}
    end
  rescue
    error -> {:error, {:observation_clock, error.__struct__, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:observation_clock, kind, reason}}
  end

  defp observation_date(_clock), do: {:error, :invalid_observation_clock}

  defp failed(path, reason) do
    %{
      "path" => path,
      "name" => Path.basename(path),
      "status" => "failed",
      "reason" => inspect(reason, limit: :infinity)
    }
  end

  defp not_a_repository(path, reason) do
    %{
      "path" => path,
      "name" => Path.basename(path),
      "status" => "not_a_repository",
      "reason" => inspect(reason, limit: :infinity)
    }
  end

  defp inventory_summary(entries) do
    counts = Enum.frequencies_by(entries, & &1["status"])

    %{
      "total" => length(entries),
      "discovered" => Map.get(counts, "discovered", 0),
      "not_a_repository" => Map.get(counts, "not_a_repository", 0),
      "failed" => Map.get(counts, "failed", 0)
    }
  end

  defp candidate_checkouts(entries, owner) do
    Enum.flat_map(entries, &candidate_checkout(&1, owner))
  end

  defp candidate_checkout(
         %{"status" => "discovered", "kind" => "clone", "path" => path} = entry,
         owner
       ) do
    if entry["common_dir"] == Path.join(path, ".git") do
      candidate_identities(entry, owner)
    else
      []
    end
  end

  defp candidate_checkout(_entry, _owner), do: []

  defp candidate_identities(entry, owner) do
    identities = Enum.filter(entry["identities"] || [], &String.starts_with?(&1, owner <> "/"))

    case identities do
      [identity] -> candidate_identity(entry, identity)
      _other -> []
    end
  end

  defp candidate_identity(entry, identity) do
    repository_name = identity |> String.split("/") |> List.last()
    if Path.basename(entry["path"]) == repository_name, do: [{entry, identity}], else: []
  end

  defp discover_candidate({entry, github}) do
    identity = %{github: github, repository_name: Path.basename(entry["path"])}
    mix_files = Enum.map(entry["mix_files"], &Path.join(entry["path"], &1))
    discover_repository(entry["path"], identity, mix_files)
  end

  defp inventory_failures(entries) do
    for entry <- entries, entry["status"] == "failed" do
      %{"repository" => entry["name"], "path" => ".", "reason" => entry["reason"]}
    end
  end

  defp collect_candidate({{:ok, :skip}, _candidate}, accumulator), do: accumulator

  defp collect_candidate(
         {{:ok, {:resolved, repository, errors}}, _candidate},
         {repositories, unresolved}
       ) do
    {[repository | repositories], errors ++ unresolved}
  end

  defp collect_candidate(
         {{:ok, {:unresolved, errors}}, _candidate},
         {repositories, unresolved}
       ) do
    {repositories, errors ++ unresolved}
  end

  defp collect_candidate({{:exit, reason}, {entry, _identity}}, {repositories, unresolved}) do
    error = %{
      "repository" => entry["name"],
      "path" => ".",
      "reason" => "task_exit:#{inspect(reason, limit: :infinity)}"
    }

    {repositories, [error | unresolved]}
  end

  defp discover_repository(path, identity, mix_files) do
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
             "kind" => project_kind(relative_path, workspace_root?)
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

  defp find_mix_files_result(root) do
    prune_expression =
      @pruned_directories
      |> Enum.flat_map(&["-name", &1, "-o"])
      |> Enum.drop(-1)

    arguments =
      [root, "-maxdepth", "6", "("] ++
        prune_expression ++
        [")", "-type", "d", "-prune", "-o", "-type", "f", "-name", "mix.exs", "-print"]

    case Command.run("find", arguments) do
      {:ok, result} -> {:ok, result.output |> String.split("\n", trim: true) |> Enum.sort()}
      {:error, reason} -> {:error, {:mix_inspector_find, reason}}
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
