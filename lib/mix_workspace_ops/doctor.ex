defmodule MixWorkspaceOps.Doctor do
  @moduledoc "Read-only validation of catalog repositories, projects, and operator overlays."

  alias MixWorkspaceOps.{Catalog, Git, Overlay}

  @spec inspect(Catalog.t()) :: map()
  def inspect(catalog) do
    repositories =
      catalog.repositories
      |> Map.values()
      |> Enum.sort_by(& &1.id)
      |> Enum.map(&inspect_repository(catalog, &1))

    checks = Enum.flat_map(repositories, & &1.checks)

    %{
      schema: 1,
      catalog: catalog.path,
      catalog_digest: catalog.digest,
      healthy: Enum.all?(checks, & &1.pass),
      repositories: repositories
    }
  end

  defp inspect_repository(catalog, repository) do
    root = Catalog.repository_root(catalog, repository)
    projects = Enum.map(repository.projects, &inspect_project(catalog, &1))

    checks =
      [
        check(:directory, File.dir?(root), root),
        check(:git_root, git_root?(root), root),
        check(:remote, remote_matches?(root, repository.github), repository.github),
        check(:clean, git_clean?(root), root),
        check(:upstream, upstream_matches?(root), root),
        inspect_overlay(root)
      ] ++ Enum.flat_map(projects, & &1.checks)

    %{
      id: repository.id,
      root: root,
      status: repository.status,
      healthy: all_pass?(checks),
      checks: checks
    }
  end

  defp inspect_project(catalog, project) do
    root = Catalog.project_root(catalog, project)
    checks = [check(:mix_project, File.regular?(Path.join(root, "mix.exs")), root)]
    %{app: project.app, root: root, checks: checks}
  end

  defp inspect_overlay(root) do
    case Overlay.read(root) do
      {:ok, overlay} -> check(:overlay, true, %{mode: overlay.mode, target: overlay.target})
      {:error, :enoent} -> check(:overlay, true, :inactive)
      {:error, reason} -> check(:overlay, false, reason)
    end
  end

  defp git_root?(root) do
    File.dir?(root) and match?({:ok, ^root}, Git.root(root))
  rescue
    _error -> false
  end

  defp remote_matches?(root, github) do
    Git.remote_url!(root)
    |> String.replace_suffix(".git", "")
    |> String.ends_with?(github)
  rescue
    MixWorkspaceOps.CommandError -> false
  end

  defp git_clean?(root), do: File.dir?(root) and Git.clean?(root)

  defp upstream_matches?(root) do
    File.dir?(root) and Git.head!(root) == Git.upstream_head!(root)
  rescue
    MixWorkspaceOps.CommandError -> false
  end

  defp check(name, pass?, detail), do: %{name: name, pass: pass?, detail: detail}
  defp all_pass?(checks), do: Enum.all?(checks, & &1.pass)
end
