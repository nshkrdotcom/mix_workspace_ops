defmodule MixWorkspaceOps.Doctor do
  @moduledoc """
  Read-only validation of catalogued repositories and Mix-project identities.

  A repository with no checkout is reported, not fatal. Absence is a fact about
  one operator's disk, and a report that stops at the first repository someone
  has not cloned tells that operator nothing about the ones they have.

  """

  alias MixWorkspaceOps.{Binding, Git, Project, Registry}

  @spec inspect(Registry.t()) :: map()
  def inspect(registry) do
    catalogued = Binding.catalogued_identities(registry)

    repositories =
      registry
      |> Registry.selected_repositories()
      |> Enum.map(&inspect_repository(registry, &1, catalogued))

    checks = Enum.flat_map(repositories, & &1.checks)

    %{
      schema: "mix_workspace_ops.doctor/v1",
      registry: registry.path,
      registry_digest: registry.digest,
      healthy: Enum.all?(checks, & &1.pass),
      repositories: repositories
    }
  end

  defp inspect_repository(registry, repository, catalogued) do
    case Registry.checkout(registry, repository) do
      {:bound, root} -> inspect_bound_repository(registry, repository, root, catalogued)
      {:absent, expected} -> absent_repository(repository, expected)
      :unknown -> absent_repository(repository, nil)
    end
  end

  # An absent checkout carries no checks, so it neither passes nor fails: there
  # is nothing on disk to hold to the catalog. It is still a row, because a
  # report that omitted it would be indistinguishable from one where every
  # repository was present.
  defp absent_repository(repository, expected) do
    %{
      id: repository.id,
      status: "absent",
      root: nil,
      expected_root: expected,
      healthy: true,
      checks: [],
      projects: []
    }
  end

  defp inspect_bound_repository(registry, repository, root, catalogued) do
    projects = Enum.map(repository.projects, &inspect_project(registry, &1))

    checks =
      [
        check(:directory, File.dir?(root), root),
        check(:git_root, git_root?(root), root),
        check(:remote, remote_matches?(root, repository.github, catalogued), repository.github),
        check(:clean, Git.clean?(root), root),
        check(:branch, Git.branch!(root) == repository.default_branch, repository.default_branch)
      ] ++ Enum.flat_map(projects, & &1.checks)

    %{
      id: repository.id,
      status: "bound",
      root: root,
      expected_root: root,
      healthy: all_pass?(checks),
      checks: checks,
      projects: projects
    }
  rescue
    error ->
      check = check(:repository_fault, false, Exception.message(error))

      %{
        id: repository.id,
        status: "bound",
        root: root,
        expected_root: root,
        healthy: false,
        checks: [check],
        projects: []
      }
  end

  defp inspect_project(registry, project) do
    root = Registry.project_root(registry, project)

    metadata_check =
      case Project.metadata(registry, project) do
        {:ok, metadata} -> check(:mix_identity, metadata.app == project.app, metadata)
        {:error, reason} -> check(:mix_identity, false, reason)
      end

    checks = [
      check(:mix_project, File.regular?(Path.join(root, "mix.exs")), root),
      metadata_check
    ]

    %{id: project.id, app: project.app, root: root, checks: checks}
  end

  defp git_root?(root), do: match?({:ok, ^root}, Git.root(root))

  # The same rule binding applies: exactly one origin URL resolves to a
  # catalogued repository, and it is this one.
  defp remote_matches?(root, github, catalogued),
    do: match?({:ok, ^github}, Binding.resolve_identity(root, catalogued))

  defp check(name, pass?, detail), do: %{name: name, pass: pass?, detail: detail}
  defp all_pass?(checks), do: Enum.all?(checks, & &1.pass)
end
