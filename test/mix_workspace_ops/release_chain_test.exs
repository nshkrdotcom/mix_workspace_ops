defmodule MixWorkspaceOps.ReleaseChainTest do
  use MixWorkspaceOps.WorkspaceCase, async: true

  alias MixWorkspaceOps.Registry
  alias MixWorkspaceOps.Registry.ReleaseChain

  defp catalog(root, repositories), do: root |> write_catalog!(repositories) |> Registry.load!()

  test "membership is declared and prerequisites are derived across repositories", context do
    root = temporary_directory!(context)

    registry =
      catalog(root, [
        catalog_repository("core",
          projects: [catalog_project("core")],
          release_chain: %{"core" => []}
        ),
        catalog_repository("middle",
          projects: [catalog_project("middle")],
          dependency_sources: %{"core" => %{"hex" => "~> 0.1.0"}},
          release_chain: %{"middle" => []}
        ),
        catalog_repository("leaf",
          projects: [catalog_project("leaf")],
          dependency_sources: %{
            "middle" => %{"hex" => "~> 0.1.0"},
            "unmanaged" => %{"hex" => "~> 0.1.0", "order" => ["hex"]}
          },
          release_chain: %{"leaf" => []}
        )
      ])

    assert ReleaseChain.packages(registry) == ["core", "leaf", "middle"]

    assert {:ok, chain} = ReleaseChain.derive(registry)
    assert chain == %{"core" => [], "middle" => ["core"], "leaf" => ["middle"]}

    assert {:ok, ["core", "middle", "leaf"]} = ReleaseChain.order(registry, "leaf")
    assert {:ok, ["core", "middle"]} = ReleaseChain.order(registry, "middle")
  end

  test "a dependency outside the train is not a release prerequisite", context do
    root = temporary_directory!(context)

    registry =
      catalog(root, [
        catalog_repository("core", projects: [catalog_project("core")]),
        catalog_repository("leaf",
          projects: [catalog_project("leaf")],
          dependency_sources: %{"core" => %{"hex" => "~> 0.1.0"}},
          release_chain: %{"leaf" => []}
        )
      ])

    assert {:ok, %{"leaf" => []}} = ReleaseChain.derive(registry)
  end

  test "an intra-repository edge is declared, not derived from the repository table", context do
    root = temporary_directory!(context)

    repository = fn release_chain ->
      catalog_repository("plane",
        projects: [
          catalog_project("plane.core", app: "plane_core", path: "core/plane", kind: "package"),
          catalog_project("plane.rpc", app: "plane_rpc", path: "protocols/rpc", kind: "package")
        ],
        dependency_sources: %{"plane_core" => %{"hex" => "~> 0.1.0"}},
        release_chain: release_chain
      )
    end

    derived_only =
      catalog(root, [repository.(%{"plane_core" => [], "plane_rpc" => []})])

    assert {:ok, %{"plane_core" => [], "plane_rpc" => []}} = ReleaseChain.derive(derived_only)

    declared =
      catalog(root, [repository.(%{"plane_core" => [], "plane_rpc" => ["plane_core"]})])

    assert {:ok, %{"plane_core" => [], "plane_rpc" => ["plane_core"]}} =
             ReleaseChain.derive(declared)

    assert {:ok, ["plane_core", "plane_rpc"]} = ReleaseChain.order(declared, "plane_rpc")
  end

  test "a project table restores intra-repository attribution", context do
    root = temporary_directory!(context)

    registry =
      catalog(root, [
        catalog_repository("plane",
          projects: [
            catalog_project("plane.core", app: "plane_core", path: "core/plane", kind: "package"),
            catalog_project("plane.rpc",
              app: "plane_rpc",
              path: "protocols/rpc",
              kind: "package",
              dependency_sources: %{"plane_core" => %{"hex" => "~> 0.1.0"}}
            )
          ],
          release_chain: %{"plane_core" => [], "plane_rpc" => []}
        )
      ])

    assert {:ok, %{"plane_core" => [], "plane_rpc" => ["plane_core"]}} =
             ReleaseChain.derive(registry)
  end

  test "a package must be provided by a project of its own repository", context do
    root = temporary_directory!(context)

    path =
      write_catalog!(root, [
        catalog_repository("core",
          projects: [catalog_project("core")],
          release_chain: %{"elsewhere" => []}
        )
      ])

    assert {:error, {:release_package_not_provided, "core", "elsewhere"}} = Registry.load(path)
  end

  test "a prerequisite absent from the catalog is refused", context do
    root = temporary_directory!(context)

    path =
      write_catalog!(root, [
        catalog_repository("core",
          projects: [catalog_project("core")],
          release_chain: %{"core" => ["absent"]}
        )
      ])

    assert {:error, {:missing_release_prerequisite, "core", ["absent"]}} = Registry.load(path)
  end

  test "a cycle is refused", context do
    root = temporary_directory!(context)

    registry =
      catalog(root, [
        catalog_repository("alpha",
          projects: [catalog_project("alpha")],
          release_chain: %{"alpha" => ["beta"]}
        ),
        catalog_repository("beta",
          projects: [catalog_project("beta")],
          release_chain: %{"beta" => ["alpha"]}
        )
      ])

    assert {:error, {:release_chain_cycle, ["alpha", "beta"]}} = ReleaseChain.derive(registry)
  end

  test "an unknown package is refused by name", context do
    root = temporary_directory!(context)

    registry =
      catalog(root, [
        catalog_repository("alpha",
          projects: [catalog_project("alpha")],
          release_chain: %{"alpha" => []}
        )
      ])

    assert {:error, {:unknown_release_package, "beta"}} = ReleaseChain.order(registry, "beta")
    assert {:ok, ["alpha"]} = ReleaseChain.order(registry)
  end

  test "a train package the selection excludes is named unselected, not unprovided",
       context do
    root = temporary_directory!(context)

    registry =
      catalog(root, [
        catalog_repository("plane",
          projects: [
            catalog_project("plane.core", app: "plane_core", path: "core/plane", kind: "package"),
            catalog_project("plane.rpc", app: "plane_rpc", path: "protocols/rpc", kind: "package")
          ],
          release_chain: %{"plane_core" => [], "plane_rpc" => ["plane_core"]}
        )
      ])

    selected = Registry.restrict(registry, [Registry.project!(registry, "plane.core")])

    assert ReleaseChain.packages(selected) == ["plane_core", "plane_rpc"]

    assert {:error, {:unselected_release_package, "plane_rpc", ["plane.rpc"]}} =
             ReleaseChain.derive(selected)
  end

  test "a v1 document declares no release train", context do
    root = temporary_directory!(context)

    registry =
      root
      |> write_registry!([repository("alpha", [project("alpha")])])
      |> Registry.load!()

    assert ReleaseChain.packages(registry) == []
    assert {:ok, %{}} = ReleaseChain.derive(registry)
  end
end
