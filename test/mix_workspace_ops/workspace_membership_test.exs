defmodule MixWorkspaceOps.WorkspaceMembershipTest do
  use MixWorkspaceOps.WorkspaceCase, async: true

  alias MixWorkspaceOps.{Graph, Registry, Resolution}

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

  test "a workspace graph walks the target after its derived selected members", context do
    root = temporary_directory!(context)
    initialize_repository!(Path.join(root, "plane"))

    projects = [
      catalog_project("plane", app: nil, kind: "workspace_root"),
      catalog_project("plane.alpha", app: "alpha", path: "apps/alpha", kind: "package"),
      catalog_project("plane.beta", app: "beta", path: "apps/beta", kind: "package"),
      catalog_project("plane.gamma", app: "gamma", path: "apps/gamma", kind: "package"),
      catalog_project("plane.scratch", path: "scratch", kind: "tooling"),
      catalog_project("plane.example", path: "examples/example", kind: "tooling"),
      catalog_project("plane.generated", path: "generated", kind: "generated"),
      catalog_project("plane.nested", app: nil, path: "nested", kind: "workspace_root"),
      catalog_project("plane.other", app: nil, path: "other", kind: "workspace_root")
    ]

    registry =
      root
      |> workspace_catalog(
        %{
          "kind" => "umbrella",
          "exclude_project_ids" => ["plane.example", "plane.scratch"]
        },
        projects
      )
      |> Registry.load!()
      |> bind!(root)

    reader = fn project ->
      send(self(), {:seed, project.id})
      {:ok, []}
    end

    assert {:ok, resolution} = Graph.resolve(registry, "plane", dependency_reader: reader)
    assert Enum.map(resolution.projects, & &1.id) == ~w(plane.alpha plane.beta plane.gamma plane)

    assert_received {:seed, "plane.alpha"}
    assert_received {:seed, "plane.beta"}
    assert_received {:seed, "plane.gamma"}
    assert_received {:seed, "plane"}
    refute_received {:seed, _other}

    selected =
      Registry.select(registry, [
        Registry.project!(registry, "plane"),
        Registry.project!(registry, "plane.alpha"),
        Registry.project!(registry, "plane.gamma")
      ])

    assert {:ok, selected_resolution} =
             Graph.resolve(selected, "plane", dependency_reader: fn _project -> {:ok, []} end)

    assert Enum.map(selected_resolution.projects, & &1.id) == ~w(plane.alpha plane.gamma plane)
  end

  test "a workspace root contributes dependencies that no member declares", context do
    root = temporary_directory!(context)
    initialize_repository!(Path.join(root, "plane"))
    initialize_repository!(Path.join(root, "support"))

    registry =
      root
      |> write_catalog!([
        catalog_repository("plane",
          workspace: %{"kind" => "umbrella"},
          dependency_sources: %{"support" => %{"hex" => "~> 0.1"}},
          projects: [
            catalog_project("plane", app: nil, kind: "workspace_root"),
            catalog_project("plane.core", app: "plane_core", path: "apps/core", kind: "package")
          ]
        ),
        catalog_repository("support", projects: [catalog_project("support")])
      ])
      |> Registry.load!()
      |> bind!(root)

    reader = fn
      %{id: "plane"} -> {:ok, ["support"]}
      _project -> {:ok, []}
    end

    assert {:ok, resolution} = Graph.resolve(registry, "plane", dependency_reader: reader)

    assert Enum.map(resolution.projects, & &1.id) == ~w(plane.core support plane)
    assert resolution.edges == [{"plane", "support"}]

    assert resolution.dependency_applications == [
             %{
               application: "support",
               candidates: [],
               classification: :managed,
               consumer: "plane",
               provider: "support"
             }
           ]

    assert {:ok, report} =
             Resolution.resolve(registry, "plane", dependency_reader: reader)

    assert [%{application: "support", source: "local"}] =
             Enum.map(Resolution.sources(report), &Map.take(&1, [:application, :source]))
  end
end
