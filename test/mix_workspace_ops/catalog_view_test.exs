defmodule MixWorkspaceOps.CatalogViewTest do
  use MixWorkspaceOps.WorkspaceCase, async: true

  alias MixWorkspaceOps.{Registry, View}

  defp catalog(root) do
    root
    |> write_catalog!([
      catalog_repository("alpha",
        languages: ["elixir"],
        lifecycle: "active",
        groups: ["platform.core", "family.runtime"],
        projects: [
          catalog_project("alpha.root", app: "alpha_root", kind: "workspace_root"),
          catalog_project("alpha.core", app: "alpha_core", path: "core", kind: "package")
        ]
      ),
      catalog_repository("beta",
        languages: ["elixir", "rust"],
        lifecycle: "maintenance",
        groups: ["family.runtime"],
        projects: [catalog_project("beta")]
      ),
      catalog_repository("charts",
        languages: ["python"],
        lifecycle: "active",
        groups: ["family.analysis"]
      )
    ])
    |> Registry.load!()
  end

  test "selects repositories with no Mix projects", context do
    root = temporary_directory!(context)
    registry = catalog(root)

    {:ok, view} = View.load(write_catalog_view!(root, "analysis", %{"languages" => ["python"]}))

    assert {:ok, [repository]} = View.select_repositories(registry, view)
    assert repository.id == "charts"
    assert {:ok, []} = View.select(registry, view)
  end

  test "selects on groups, languages, and lifecycles", context do
    root = temporary_directory!(context)
    registry = catalog(root)

    select = fn selector ->
      {:ok, view} = View.load(write_catalog_view!(root, "v#{:erlang.phash2(selector)}", selector))
      {:ok, repositories} = View.select_repositories(registry, view)
      Enum.map(repositories, & &1.id)
    end

    assert select.(%{"groups_any" => ["family.runtime"]}) == ["alpha", "beta"]
    assert select.(%{"groups_all" => ["family.runtime", "platform.core"]}) == ["alpha"]
    assert select.(%{"languages" => ["rust"]}) == ["beta"]
    assert select.(%{"lifecycles" => ["maintenance"]}) == ["beta"]
    assert select.(%{"repository_ids" => ["alpha", "charts"]}) == ["alpha", "charts"]
    assert select.(%{"exclude_repository_ids" => ["alpha"]}) == ["beta", "charts"]
    assert select.(%{}) == ["alpha", "beta", "charts"]
  end

  test "selects projects within the selected repositories", context do
    root = temporary_directory!(context)
    registry = catalog(root)

    select = fn selector ->
      {:ok, view} = View.load(write_catalog_view!(root, "p#{:erlang.phash2(selector)}", selector))
      {:ok, projects} = View.select(registry, view)
      Enum.map(projects, & &1.id)
    end

    assert select.(%{"groups_any" => ["platform.core"]}) == ["alpha.core", "alpha.root"]
    assert select.(%{"project_ids" => ["alpha.core"]}) == ["alpha.core"]
    assert select.(%{"exclude_project_ids" => ["alpha.root"]}) == ["alpha.core", "beta"]
  end

  test "refuses a selector naming an unknown identity", context do
    root = temporary_directory!(context)
    registry = catalog(root)

    {:ok, repositories} =
      View.load(write_catalog_view!(root, "bad_repo", %{"repository_ids" => ["absent"]}))

    assert {:error, {:unknown_view_repositories, ["absent"]}} =
             View.select_repositories(registry, repositories)

    {:ok, projects} =
      View.load(write_catalog_view!(root, "bad_project", %{"project_ids" => ["absent"]}))

    assert {:error, {:unknown_view_projects, ["absent"]}} = View.select(registry, projects)
  end

  test "refuses an unknown selector key", context do
    root = temporary_directory!(context)
    path = write_catalog_view!(root, "typo", %{"group_any" => ["family.runtime"]})

    assert {:error, {:unknown_view_selector_keys, ["group_any"]}} = View.load(path)
  end

  test "a v1 view still loads and selects a v1 document by project tag", context do
    root = temporary_directory!(context)

    registry =
      root
      |> write_registry!([
        repository("alpha", [project("alpha", nil, tags: ["ecosystem", "pilot"])]),
        repository("beta", [project("beta", nil, tags: ["ecosystem"])])
      ])
      |> Registry.load!()

    {:ok, view} = View.load(write_legacy_view!(root, "pilot", %{"tags_any" => ["pilot"]}))

    assert view.schema == "mix_workspace_ops.view/v1"
    assert {:ok, [%{id: "alpha"}]} = View.select(registry, view)
    assert {:ok, [%{id: "alpha"}]} = View.select_repositories(registry, view)
  end

  test "a v1 view matches a v2 document against repository groups", context do
    root = temporary_directory!(context)
    registry = catalog(root)

    {:ok, view} =
      View.load(write_legacy_view!(root, "runtime", %{"tags_any" => ["family.runtime"]}))

    assert {:ok, repositories} = View.select_repositories(registry, view)
    assert Enum.map(repositories, & &1.id) == ["alpha", "beta"]
  end
end
