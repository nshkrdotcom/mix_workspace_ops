defmodule MixWorkspaceOps.WorkspaceMembershipTest do
  use MixWorkspaceOps.WorkspaceCase, async: true

  alias MixWorkspaceOps.Registry

  defp workspace_catalog(root, workspace, projects) do
    write_catalog!(root, [
      catalog_repository("plane", workspace: workspace, projects: projects)
    ])
  end

  defp members(registry, repository_id \\ "plane") do
    {:ok, members} = Registry.workspace_members(registry, repository_id)
    Enum.map(members, & &1.id)
  end

  test "an umbrella root is a container, not a member", context do
    root = temporary_directory!(context)

    registry =
      root
      |> workspace_catalog(%{"kind" => "umbrella"}, [
        catalog_project("plane", app: "plane_workspace", kind: "workspace_root"),
        catalog_project("plane.core", path: "apps/core", kind: "package"),
        catalog_project("plane.web", path: "apps/web", kind: "package")
      ])
      |> Registry.load!()

    assert members(registry) == ["plane.core", "plane.web"]
  end

  test "a workspace root that builds itself is an explicit inclusion", context do
    root = temporary_directory!(context)

    registry =
      root
      |> workspace_catalog(
        %{"kind" => "blitz", "include_project_ids" => ["plane"]},
        [
          catalog_project("plane", app: "plane_workspace", kind: "workspace_root"),
          catalog_project("plane.core", path: "core/plane", kind: "package"),
          catalog_project("plane.edge", path: "edge/plane", kind: "package")
        ]
      )
      |> Registry.load!()

    assert members(registry) == ["plane", "plane.core", "plane.edge"]
  end

  test "a generated project is never a member", context do
    root = temporary_directory!(context)

    registry =
      root
      |> workspace_catalog(%{"kind" => "blitz"}, [
        catalog_project("plane", app: "plane_workspace", kind: "workspace_root"),
        catalog_project("plane.core", path: "core/plane", kind: "package"),
        catalog_project("plane.consumer",
          app: "plane_consumer",
          path: "packaging/consumer",
          kind: "generated"
        )
      ])
      |> Registry.load!()

    assert members(registry) == ["plane.core"]
  end

  test "a generated project may not be included as a member", context do
    root = temporary_directory!(context)

    path =
      workspace_catalog(root, %{"kind" => "blitz", "include_project_ids" => ["plane.consumer"]}, [
        catalog_project("plane", app: "plane_workspace", kind: "workspace_root"),
        catalog_project("plane.core", path: "core/plane", kind: "package"),
        catalog_project("plane.consumer",
          app: "plane_consumer",
          path: "packaging/consumer",
          kind: "generated"
        )
      ])

    assert {:error, {:generated_workspace_member, "plane", ["plane.consumer"]}} =
             Registry.load(path)
  end

  test "an exclusion removes a project derivation would include", context do
    root = temporary_directory!(context)

    registry =
      root
      |> workspace_catalog(
        %{"kind" => "blitz", "exclude_project_ids" => ["plane.scratch"]},
        [
          catalog_project("plane", app: "plane_workspace", kind: "workspace_root"),
          catalog_project("plane.core", path: "core/plane", kind: "package"),
          catalog_project("plane.scratch", path: "scratch/plane", kind: "tooling")
        ]
      )
      |> Registry.load!()

    assert members(registry) == ["plane.core"]
  end

  test "a project may not be included and excluded at once", context do
    root = temporary_directory!(context)

    path =
      workspace_catalog(
        root,
        %{
          "kind" => "blitz",
          "include_project_ids" => ["plane"],
          "exclude_project_ids" => ["plane"]
        },
        [
          catalog_project("plane", app: "plane_workspace", kind: "workspace_root"),
          catalog_project("plane.core", path: "core/plane", kind: "package")
        ]
      )

    assert {:error, {:contradictory_workspace_members, "plane", ["plane"]}} = Registry.load(path)
  end

  test "a repository with no workspace has no membership to derive", context do
    root = temporary_directory!(context)

    registry =
      root
      |> write_catalog!([catalog_repository("alpha", projects: [catalog_project("alpha")])])
      |> Registry.load!()

    assert {:error, {:not_a_workspace, "alpha"}} = Registry.workspace_members(registry, "alpha")
    assert Registry.workspaces(registry) == []
  end

  test "every declared workspace is listed with its members", context do
    root = temporary_directory!(context)

    registry =
      root
      |> write_catalog!([
        catalog_repository("plane",
          workspace: %{"kind" => "umbrella"},
          projects: [
            catalog_project("plane", app: "plane_workspace", kind: "workspace_root"),
            catalog_project("plane.core", path: "apps/core", kind: "package")
          ]
        ),
        catalog_repository("alpha", projects: [catalog_project("alpha")])
      ])
      |> Registry.load!()

    assert [{repository, members}] = Registry.workspaces(registry)
    assert repository.id == "plane"
    assert Enum.map(members, & &1.id) == ["plane.core"]
  end
end
