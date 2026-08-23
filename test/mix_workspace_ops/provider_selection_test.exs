defmodule MixWorkspaceOps.ProviderSelectionTest do
  use MixWorkspaceOps.WorkspaceCase, async: true

  alias MixWorkspaceOps.{Graph, Registry, View}

  defp two_providers(root, opts \\ []) do
    declaration = Keyword.get(opts, :declaration, %{"hex" => "~> 0.1.0"})

    write_catalog!(root, [
      catalog_repository("alpha",
        projects: [catalog_project("alpha")],
        dependency_sources: if(is_nil(declaration), do: nil, else: %{"shared" => declaration})
      ),
      catalog_repository("upstream",
        projects: [catalog_project("upstream.shared", app: "shared")]
      ),
      catalog_repository("vendored",
        projects: [
          catalog_project("vendored.shared",
            app: "shared",
            path: "vendor/shared",
            kind: "package"
          )
        ]
      )
    ])
  end

  test "two projects may provide one application", context do
    root = temporary_directory!(context)

    registry =
      root
      |> two_providers(declaration: %{"hex" => "~> 0.1.0", "provider" => "upstream.shared"})
      |> Registry.load!()

    assert Enum.map(Registry.providers(registry, "shared"), & &1.id) ==
             ["upstream.shared", "vendored.shared"]
  end

  test "a declaration that could resolve locally must name its provider", context do
    root = temporary_directory!(context)

    assert {:error,
            {:dependency_source, "alpha",
             {:ambiguous_application, "shared", ["upstream.shared", "vendored.shared"]}}} =
             Registry.load(two_providers(root))
  end

  test "an unknown provider is refused and names the candidates", context do
    root = temporary_directory!(context)

    assert {:error,
            {:dependency_source, "alpha",
             {:unknown_provider, "shared", "absent.shared",
              ["upstream.shared", "vendored.shared"]}}} =
             Registry.load(two_providers(root, declaration: %{"provider" => "absent.shared"}))
  end

  test "a provider is refused where local can never be reached", context do
    root = temporary_directory!(context)

    declaration = %{
      "hex" => "~> 0.1.0",
      "order" => ["hex"],
      "provider" => "upstream.shared"
    }

    assert {:error, {:provider_without_local_source, "alpha", "shared"}} =
             Registry.load(two_providers(root, declaration: declaration))
  end

  test "a project provides applications beyond its own", context do
    root = temporary_directory!(context)

    registry =
      root
      |> write_catalog!([
        catalog_repository("alpha",
          projects: [
            catalog_project("alpha", app: "alpha", provides: ["alpha", "alpha_legacy"])
          ]
        )
      ])
      |> Registry.load!()

    assert {:ok, project} = Registry.project_for_app(registry, "alpha_legacy")
    assert project.id == "alpha"
  end

  test "a project may not omit its own application from what it provides", context do
    root = temporary_directory!(context)

    path =
      write_catalog!(root, [
        catalog_repository("alpha",
          projects: [catalog_project("alpha", app: "alpha", provides: ["other"])]
        )
      ])

    assert {:error, {:application_not_provided, "alpha", ["other"]}} = Registry.load(path)
  end

  test "the closure resolves the provider the declaration names", context do
    root = temporary_directory!(context)

    registry =
      bound_two_providers(context, root, %{"hex" => "~> 0.1.0", "provider" => "vendored.shared"})

    assert {:ok, resolution} =
             Graph.resolve(registry, "alpha", dependency_reader: shared_reader())

    assert Enum.map(resolution.projects, & &1.id) == ["vendored.shared", "alpha"]
    assert resolution.edges == [{"alpha", "vendored.shared"}]
    assert resolution.external_dependencies == []
    assert resolution.known_unselected == []
  end

  test "a declaration naming no provider leaves the closure ambiguous", context do
    root = temporary_directory!(context)
    registry = bound_two_providers(context, root, nil)

    assert {:error, {:ambiguous_application, "shared", candidates, "alpha"}} =
             Graph.resolve(registry, "alpha", dependency_reader: shared_reader())

    assert candidates == ["upstream.shared", "vendored.shared"]
  end

  test "a catalogued provider outside the selection is not an external package", context do
    root = temporary_directory!(context)

    registry =
      bound_two_providers(context, root, %{"hex" => "~> 0.1.0", "provider" => "vendored.shared"})

    view = write_catalog_view!(root, "consumer", %{"repository_ids" => ["alpha"]})
    {:ok, view} = View.load(view)
    {:ok, projects} = View.select(registry, view)
    selected = Registry.restrict(registry, projects)

    assert {:ok, resolution} =
             Graph.resolve(selected, "alpha", dependency_reader: shared_reader())

    assert resolution.external_dependencies == []

    assert resolution.known_unselected == [
             {"alpha", "shared", ["upstream.shared", "vendored.shared"]}
           ]
  end

  test "an uncatalogued dependency is still an external package", context do
    root = temporary_directory!(context)

    registry =
      bound_two_providers(context, root, %{"hex" => "~> 0.1.0", "provider" => "vendored.shared"})

    reader = fn project -> {:ok, if(project.id == "alpha", do: ["telemetry"], else: [])} end

    assert {:ok, resolution} = Graph.resolve(registry, "alpha", dependency_reader: reader)
    assert resolution.external_dependencies == [{"alpha", "telemetry"}]
    assert resolution.known_unselected == []
  end

  defp bound_two_providers(_context, root, declaration) do
    initialize_repository!(Path.join(root, "alpha"))
    initialize_repository!(Path.join(root, "upstream"))
    initialize_repository!(Path.join(root, "vendored"))

    root
    |> two_providers(declaration: declaration)
    |> Registry.load!()
    |> bind!(root)
  end

  defp shared_reader do
    fn project -> {:ok, if(project.id == "alpha", do: ["shared"], else: [])} end
  end

  test "a v1 document refuses two projects providing one application", context do
    root = temporary_directory!(context)

    path =
      write_registry!(root, [
        repository("alpha", [project("alpha"), project("alpha.shared", "shared")]),
        repository("beta", [project("beta"), project("beta.shared", "shared")])
      ])

    assert {:error, {:duplicate_entries, "application", ["shared"]}} = Registry.load(path)
  end

  test "a v1 document with one provider per application still loads", context do
    root = temporary_directory!(context)

    registry =
      root
      |> write_registry!([
        repository("alpha", [project("alpha")]),
        repository("beta", [project("beta")])
      ])
      |> Registry.load!()

    assert map_size(registry.applications) == 2
    assert {:ok, %{id: "alpha"}} = Registry.project_for_app(registry, "alpha")
  end

  test "a v2 document accepts what v1 refused", context do
    root = temporary_directory!(context)

    registry =
      root
      |> write_catalog!([
        catalog_repository("alpha",
          projects: [
            catalog_project("alpha"),
            catalog_project("alpha.shared", app: "shared", path: "shared", kind: "package")
          ]
        ),
        catalog_repository("beta",
          projects: [
            catalog_project("beta"),
            catalog_project("beta.shared", app: "shared", path: "shared", kind: "package")
          ]
        )
      ])
      |> Registry.load!()

    assert Enum.map(Registry.providers(registry, "shared"), & &1.id) ==
             ["alpha.shared", "beta.shared"]
  end
end
