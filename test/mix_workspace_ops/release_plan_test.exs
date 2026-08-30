defmodule MixWorkspaceOps.Release.PlanTest do
  use MixWorkspaceOps.WorkspaceCase, async: true

  alias MixWorkspaceOps.Registry
  alias MixWorkspaceOps.Release.Plan

  test "builds a portable self-digested plan from derived and explicit edges", context do
    root = temporary_directory!(context)

    registry =
      root
      |> write_catalog!([
        catalog_repository("core",
          projects: [catalog_project("core")],
          release_chain: %{"core" => []}
        ),
        catalog_repository("plane",
          projects: [
            catalog_project("plane.rpc", app: "plane_rpc", path: "protocols/rpc"),
            catalog_project("plane.worker", app: "plane_worker", path: "runtimes/worker")
          ],
          dependency_sources: %{"core" => %{"hex" => "~> 1.0"}},
          release_chain: %{
            "plane_rpc" => ["core"],
            "plane_worker" => ["plane_rpc"]
          }
        ),
        catalog_repository("client",
          projects: [catalog_project("client")],
          dependency_sources: %{"plane_worker" => %{"hex" => "~> 1.0"}},
          release_chain: %{"client" => []}
        )
      ])
      |> Registry.load!()

    assert {:ok, plan} = Plan.build(registry, "client")
    assert plan.schema == "mix_workspace_ops.release_plan/v1"
    assert plan.registry.digest == registry.digest
    assert plan.package == "client"
    assert plan.order == ["core", "plane_rpc", "plane_worker", "client"]
    assert plan.digest == Plan.digest(plan)

    assert Enum.map(plan.units, & &1.package) == plan.order
    refute Plan.digest(plan) == Plan.digest(%{plan | package: "plane_worker"})

    assert Enum.find(plan.units, &(&1.package == "plane_worker")) == %{
             package: "plane_worker",
             project: %{id: "plane.worker", path: "runtimes/worker"},
             repository: %{
               id: "plane",
               github: "example-org/plane",
               default_branch: "main"
             }
           }

    encoded = MixWorkspaceOps.Report.encode(plan)
    refute encoded =~ root
  end

  test "unknown package remains a named chain error", context do
    root = temporary_directory!(context)

    registry =
      root
      |> write_catalog!([
        catalog_repository("alpha",
          projects: [catalog_project("alpha")],
          release_chain: %{"alpha" => []}
        )
      ])
      |> Registry.load!()

    assert Plan.build(registry, "absent") ==
             {:error, {:unknown_release_package, "absent"}}
  end
end
