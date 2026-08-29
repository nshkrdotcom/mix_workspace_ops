defmodule MixWorkspaceOps.ProviderSelectionTest do
  use MixWorkspaceOps.WorkspaceCase, async: true

  alias MixWorkspaceOps.{Graph, Registry, Resolution, View}

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
             {:ambiguous_application, "shared",
              [
                %{project: "upstream.shared", repository: "upstream"},
                %{project: "vendored.shared", repository: "vendored"}
              ]}}} =
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

    assert {:ok, project} = Registry.resolve_dependency(registry, "alpha_legacy")
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

    assert candidates == [
             %{project: "upstream.shared", repository: "upstream"},
             %{project: "vendored.shared", repository: "vendored"}
           ]
  end

  test "one current provider settles an otherwise ambiguous application", context do
    root = temporary_directory!(context)

    registry =
      root
      |> write_catalog!([
        catalog_repository("alpha", projects: [catalog_project("alpha")]),
        catalog_repository("upstream",
          projects: [catalog_project("upstream.shared", app: "shared", current: true)]
        ),
        catalog_repository("successor",
          projects: [catalog_project("successor.shared", app: "shared")]
        )
      ])
      |> Registry.load!()

    assert {:ok, %{id: "upstream.shared"}} = Registry.resolve_dependency(registry, "shared")
  end

  test "the consumer repository's own provider wins before the global current one", context do
    root = temporary_directory!(context)

    registry =
      root
      |> write_catalog!([
        catalog_repository("upstream",
          projects: [catalog_project("upstream.shared", app: "shared", current: true)]
        ),
        catalog_repository("vendored",
          projects: [
            catalog_project("vendored.consumer", app: "consumer"),
            catalog_project("vendored.shared", app: "shared")
          ]
        )
      ])
      |> Registry.load!()

    assert {:ok, %{id: "vendored.shared"}} =
             Registry.resolve_dependency(registry, "shared", nil, "vendored")

    assert {:ok, %{id: "upstream.shared"}} =
             Registry.resolve_dependency(registry, "shared", nil, "external")
  end

  test "graph traversal and source coordinates use the same consumer repository", context do
    root = temporary_directory!(context)
    initialize_repository!(Path.join(root, "upstream"))
    initialize_repository!(Path.join(root, "vendored"))
    File.mkdir_p!(Path.join(root, "vendored/consumer"))
    File.mkdir_p!(Path.join(root, "vendored/shared"))

    registry =
      root
      |> write_catalog!([
        catalog_repository("upstream",
          projects: [catalog_project("upstream.shared", app: "shared", current: true)]
        ),
        catalog_repository("vendored",
          dependency_sources: %{
            "shared" => %{
              "github" => %{},
              "order" => ["github"],
              "publish_order" => ["github"]
            }
          },
          projects: [
            catalog_project("vendored.consumer", app: "consumer", path: "consumer"),
            catalog_project("vendored.shared", app: "shared", path: "shared", kind: "package")
          ]
        )
      ])
      |> Registry.load!()
      |> bind!(root)

    reader = fn
      %{id: "vendored.consumer"} -> {:ok, ["shared"]}
      _project -> {:ok, []}
    end

    assert {:ok, graph} =
             Graph.resolve(registry, "vendored.consumer", dependency_reader: reader)

    assert graph.edges == [{"vendored.consumer", "vendored.shared"}]

    assert {:ok, report} =
             Resolution.resolve(registry, "vendored.consumer", dependency_reader: reader)

    assert [%{provider_project_id: "vendored.shared", location: coordinates}] = report.decisions
    assert coordinates.repo == "example-org/vendored"
  end

  test "two current providers are invalid rather than an order-dependent choice", context do
    root = temporary_directory!(context)

    path =
      write_catalog!(root, [
        catalog_repository("upstream",
          projects: [catalog_project("upstream.shared", app: "shared", current: true)]
        ),
        catalog_repository("successor",
          projects: [catalog_project("successor.shared", app: "shared", current: true)]
        )
      ])

    assert {:error,
            {:multiple_current_providers, "shared", ["successor.shared", "upstream.shared"]}} =
             Registry.load(path)
  end

  test "current must govern at least one provided application", context do
    root = temporary_directory!(context)

    path =
      write_catalog!(root, [
        catalog_repository("carrier",
          projects: [catalog_project("carrier.workspace", app: nil, current: true)]
        )
      ])

    assert {:error, {:current_without_application, "carrier.workspace"}} = Registry.load(path)
  end

  test "lineage never selects a dependency provider", context do
    root = temporary_directory!(context)

    registry =
      root
      |> write_catalog!([
        catalog_repository("upstream",
          projects: [catalog_project("upstream.shared", app: "shared")]
        ),
        catalog_repository("successor",
          projects: [
            catalog_project("successor.shared", app: "shared", lineage: "upstream.shared")
          ]
        )
      ])
      |> Registry.load!()

    assert {:error, {:ambiguous_application, "shared", candidates}} =
             Registry.resolve_dependency(registry, "shared")

    assert Enum.map(candidates, & &1.project) == ["successor.shared", "upstream.shared"]
  end

  test "a catalogued provider outside the selection is not an external package", context do
    root = temporary_directory!(context)

    registry =
      bound_two_providers(context, root, %{"hex" => "~> 0.1.0", "provider" => "vendored.shared"})

    view = write_catalog_view!(root, "consumer", %{"repository_ids" => ["alpha"]})
    {:ok, view} = View.load(view)
    {:ok, projects} = View.select(registry, view)
    selected = Registry.select(registry, projects)

    assert {:ok, resolution} =
             Graph.resolve(selected, "alpha", dependency_reader: shared_reader())

    assert resolution.external_dependencies == []

    assert resolution.known_unselected == [{"alpha", "shared", ["vendored.shared"]}]
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

  test "records the dependency application instead of inferring every application a project provides",
       context do
    root = temporary_directory!(context)
    initialize_repository!(Path.join(root, "consumer"))
    initialize_repository!(Path.join(root, "provider"))

    registry =
      root
      |> write_catalog!([
        catalog_repository("consumer",
          projects: [catalog_project("consumer")],
          dependency_sources: %{"shared" => %{"hex" => "~> 1.0"}}
        ),
        catalog_repository("provider",
          projects: [
            catalog_project("provider.bundle",
              app: nil,
              provides: ["compat", "shared"]
            )
          ]
        )
      ])
      |> Registry.load!()
      |> bind!(root)

    reader = fn project -> {:ok, if(project.id == "consumer", do: ["shared"], else: [])} end

    assert {:ok, graph} = Graph.resolve(registry, "consumer", dependency_reader: reader)

    assert graph.dependency_applications == [
             %{
               consumer: "consumer",
               application: "shared",
               classification: :managed,
               provider: "provider.bundle",
               candidates: []
             }
           ]

    assert {:ok, report} =
             Resolution.resolve(registry, "consumer", dependency_reader: reader)

    assert Enum.map(report.decisions, & &1.application) == ["shared"]
  end

  test "one application cannot carry conflicting provider identities in one graph", context do
    root = temporary_directory!(context)

    for repository <- ~w(z_target a_consumer selected_provider excluded_provider) do
      initialize_repository!(Path.join(root, repository))
    end

    source = fn provider ->
      %{"github" => %{}, "hex" => "~> 1.0", "provider" => provider}
    end

    registry =
      root
      |> write_catalog!([
        catalog_repository("z_target",
          projects: [catalog_project("z_target")],
          dependency_sources: %{
            "a_consumer" => %{"github" => %{}, "hex" => "~> 1.0"},
            "shared" => source.("selected_provider")
          }
        ),
        catalog_repository("a_consumer",
          projects: [catalog_project("a_consumer")],
          dependency_sources: %{"shared" => source.("excluded_provider")}
        ),
        catalog_repository("selected_provider",
          projects: [catalog_project("selected_provider", app: nil, provides: ["shared"])]
        ),
        catalog_repository("excluded_provider",
          projects: [catalog_project("excluded_provider", app: nil, provides: ["shared"])]
        )
      ])
      |> Registry.load!()
      |> bind!(root)

    selected =
      Registry.select(registry, [
        Registry.project!(registry, "z_target"),
        Registry.project!(registry, "a_consumer"),
        Registry.project!(registry, "selected_provider")
      ])

    reader = fn project ->
      case project.id do
        "z_target" -> {:ok, ["a_consumer", "shared"]}
        "a_consumer" -> {:ok, ["shared"]}
        _other -> {:ok, []}
      end
    end

    assert {:ok, graph} = Graph.resolve(selected, "z_target", dependency_reader: reader)

    assert {:error, {:conflicting_dependency_identities, "shared", uses}} =
             Resolution.resolve(selected, "z_target",
               closure: graph,
               dependency_reader: reader
             )

    assert uses == [
             %{
               consumer: "a_consumer",
               provider: "excluded_provider",
               classification: :known_unselected
             },
             %{
               consumer: "z_target",
               provider: "selected_provider",
               classification: :managed
             }
           ]

    assert Resolution.explain({:conflicting_dependency_identities, "shared", uses}) =~
             "a_consumer=excluded_provider (known_unselected)"
  end

  # A pruned catalog could change which project an application resolved to,
  # because the current schema permits several projects to provide one and
  # pruning removes candidates from the index the resolver reads. Selection
  # sits beside the catalog instead, and this walks every subset of the
  # fixture's projects to show the only thing a selection can change is
  # whether a provider is reachable at all.
  test "a selection never moves an application to a different provider", context do
    root = temporary_directory!(context)

    registry =
      root
      |> two_providers(declaration: %{"hex" => "~> 0.1.0", "provider" => "vendored.shared"})
      |> Registry.load!()

    project_ids = registry.projects |> Map.keys() |> Enum.sort()

    for subset <- subsets(project_ids) do
      selected = Registry.select(registry, Enum.map(subset, &Registry.project!(registry, &1)))

      for app <- Map.keys(registry.applications),
          provider <- [nil | Enum.map(Registry.providers(registry, app), & &1.id)] do
        catalogued = Registry.resolve_dependency(registry, app, provider)
        chosen = Registry.resolve_dependency(selected, app, provider)

        assert preserved?(catalogued, chosen, subset),
               "#{app} via #{inspect(provider)} moved under selection #{inspect(subset)}: " <>
                 "#{inspect(catalogued)} -> #{inspect(chosen)}"
      end
    end
  end

  test "a selection that removes the named provider says so rather than choosing another",
       context do
    root = temporary_directory!(context)

    registry =
      root
      |> two_providers(declaration: %{"hex" => "~> 0.1.0", "provider" => "vendored.shared"})
      |> Registry.load!()

    assert {:ok, %{id: "vendored.shared"}} =
             Registry.resolve_dependency(registry, "shared", "vendored.shared")

    without_vendored =
      Registry.select(registry, [
        Registry.project!(registry, "alpha"),
        Registry.project!(registry, "upstream.shared")
      ])

    assert {:known_unselected, ["vendored.shared"]} =
             Registry.resolve_dependency(without_vendored, "shared", "vendored.shared")

    without_either = Registry.select(registry, [Registry.project!(registry, "alpha")])

    assert {:known_unselected, ["vendored.shared"]} =
             Registry.resolve_dependency(without_either, "shared", "vendored.shared")

    assert Registry.unselected_application_ids(without_either) == ["shared"]
  end

  test "selection cannot replace an excluded current provider", context do
    root = temporary_directory!(context)

    registry =
      root
      |> write_catalog!([
        catalog_repository("alpha", projects: [catalog_project("alpha")]),
        catalog_repository("current",
          projects: [catalog_project("current.shared", app: "shared", current: true)]
        ),
        catalog_repository("fork", projects: [catalog_project("fork.shared", app: "shared")])
      ])
      |> Registry.load!()

    assert {:ok, %{id: "current.shared"}} = Registry.resolve_dependency(registry, "shared")

    selected =
      Registry.select(registry, [
        Registry.project!(registry, "alpha"),
        Registry.project!(registry, "fork.shared")
      ])

    assert {:known_unselected, ["current.shared"]} =
             Registry.resolve_dependency(selected, "shared")
  end

  # Where the catalog resolves an application to a project the selection keeps,
  # the selection must resolve it to the same project. Where the selection
  # removes that project, it must not resolve to a different one. A catalogued
  # resolution that was already an error or an ambiguity remains an error:
  # selection does not get to answer catalog identity by removing candidates.
  defp preserved?({:ok, project}, chosen, subset) do
    if project.id in subset,
      do: chosen == {:ok, project},
      else: chosen == {:known_unselected, [project.id]}
  end

  defp preserved?(catalogued, chosen, _subset), do: chosen == catalogued

  defp subsets([]), do: [[]]

  defp subsets([head | tail]) do
    rest = subsets(tail)
    rest ++ Enum.map(rest, &[head | &1])
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
    assert {:ok, %{id: "alpha"}} = Registry.resolve_dependency(registry, "alpha")
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
