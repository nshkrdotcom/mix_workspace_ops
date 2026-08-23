defmodule MixWorkspaceOps.ProviderSelectionTest do
  use MixWorkspaceOps.WorkspaceCase, async: true

  alias MixWorkspaceOps.{Graph, Registry}

  defp two_providers(root, opts \\ []) do
    write_catalog!(root, [
      catalog_repository("alpha",
        projects: [catalog_project("alpha")],
        dependency_sources: %{
          "shared" => Keyword.get(opts, :declaration, %{"hex" => "~> 0.1.0"})
        }
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

  test "an explicit provider resolves the ambiguity", context do
    root = temporary_directory!(context)

    registry =
      root
      |> two_providers(declaration: %{"hex" => "~> 0.1.0", "provider" => "vendored.shared"})
      |> Registry.load!()

    assert {:ok, project} =
             Registry.provider_for(
               registry,
               "shared",
               Registry.dependency_sources(registry, "alpha")["shared"].provider
             )

    assert project.id == "vendored.shared"
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

  test "the closure refuses an ambiguous dependency instead of taking the first match", context do
    root = temporary_directory!(context)
    initialize_repository!(Path.join(root, "alpha"))
    initialize_repository!(Path.join(root, "upstream"))
    initialize_repository!(Path.join(root, "vendored"))

    registry =
      root
      |> two_providers(declaration: %{"hex" => "~> 0.1.0", "provider" => "upstream.shared"})
      |> Registry.load!()
      |> bind!(root)

    reader = fn project -> {:ok, if(project.id == "alpha", do: ["shared"], else: [])} end

    assert {:error, {:ambiguous_application, "shared", candidates, "alpha"}} =
             Graph.resolve(registry, "alpha", dependency_reader: reader)

    assert candidates == ["upstream.shared", "vendored.shared"]
  end

  test "a v1 document keeps its global application uniqueness rule", context do
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
end
