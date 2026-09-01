defmodule MixWorkspaceOps.CatalogSchemaTest do
  use MixWorkspaceOps.WorkspaceCase, async: true

  alias MixWorkspaceOps.Registry
  alias MixWorkspaceOps.Registry.Source

  describe "schema acceptance" do
    test "loads only the canonical v2 schema and rejects legacy v1", context do
      root = temporary_directory!(context)

      v2 =
        root
        |> write_catalog!([catalog_repository("alpha", projects: [catalog_project("alpha")])])
        |> Registry.load!()

      assert v2.schema == "portfolio_registry.registry/v2"
      assert Registry.schema() == "portfolio_registry.registry/v2"
      assert Registry.schemas() == ["portfolio_registry.registry/v2"]

      legacy = Path.join(root, "legacy.json")
      File.write!(legacy, :json.encode(%{"schema" => "mix_workspace_ops.registry/v1", "repositories" => []}))
      assert {:error, :unsupported_registry_schema} = Registry.load(legacy)
    end

    test "rejects an unknown schema", context do
      root = temporary_directory!(context)
      path = Path.join(root, "registry.json")
      File.write!(path, :json.encode(%{"schema" => "other/v9", "repositories" => []}))

      assert {:error, :unsupported_registry_schema} = Registry.load(path)
    end
  end

  describe "repository records" do
    test "catalogues a repository with no Mix data at all", context do
      root = temporary_directory!(context)

      registry =
        root
        |> write_catalog!([
          catalog_repository("analysis", languages: ["python"], groups: ["family.analysis"]),
          catalog_repository("alpha", projects: [catalog_project("alpha")])
        ])
        |> Registry.load!()

      assert registry.repositories["analysis"].languages == ["python"]
      assert registry.repositories["analysis"].projects == []
      assert registry.repositories["analysis"].workspace == nil
      refute Map.has_key?(registry.projects, "analysis")
    end

    test "requires a classification vocabulary to be respected", context do
      root = temporary_directory!(context)

      for {key, value, field} <- [
            {:lifecycle, "retired", :lifecycle},
            {:disposition, "unknown", :disposition},
            {:visibility, "internal", :visibility},
            {:agent_scope, "maybe", :agent_scope}
          ] do
        path = write_catalog!(root, [catalog_repository("alpha", [{key, value}])])
        assert {:error, {:invalid_field, ^field, ^value}} = Registry.load(path)
      end
    end

    test "requires at least one language and one group", context do
      root = temporary_directory!(context)

      no_language = write_catalog!(root, [catalog_repository("alpha", languages: [])])
      assert {:error, {:empty_field, :languages}} = Registry.load(no_language)

      no_group = write_catalog!(root, [catalog_repository("alpha", groups: [])])
      assert {:error, {:empty_field, :groups}} = Registry.load(no_group)
    end

    test "rejects a group carried by every repository", context do
      root = temporary_directory!(context)

      path =
        write_catalog!(root, [
          catalog_repository("alpha", groups: ["everything", "family.alpha"]),
          catalog_repository("beta", groups: ["everything", "family.beta"])
        ])

      assert {:error, {:universal_groups, ["everything"]}} = Registry.load(path)
    end

    test "rejects an absolute or escaping project path", context do
      root = temporary_directory!(context)

      absolute =
        write_catalog!(root, [
          catalog_repository("alpha", projects: [catalog_project("alpha", path: "/elsewhere")])
        ])

      assert {:error, {:absolute_registry_path, "/elsewhere"}} = Registry.load(absolute)

      escaping =
        write_catalog!(root, [
          catalog_repository("alpha", projects: [catalog_project("alpha", path: "../sibling")])
        ])

      assert {:error, {:escaping_registry_path, "../sibling"}} = Registry.load(escaping)
    end
  end

  describe "dependency sources" do
    test "omitted order inherits local, github, then hex", context do
      root = temporary_directory!(context)

      registry =
        root
        |> write_catalog!([
          catalog_repository("alpha",
            projects: [catalog_project("alpha")],
            dependency_sources: %{
              "beta" => %{"github" => %{"repo" => "example-org/beta"}, "hex" => "~> 0.1.0"}
            }
          ),
          catalog_repository("beta", projects: [catalog_project("beta")])
        ])
        |> Registry.load!()

      declaration = Registry.dependency_sources(registry, "alpha")["beta"]

      assert declaration.order == ["local", "github", "hex"]
      assert declaration.publish_order == ["hex"]
      assert declaration.opts == %{}
      assert Source.default_order() == ["local", "github", "hex"]
      assert Source.default_publish_order() == ["hex"]
    end

    test "a Hex declaration may name a differently published package", context do
      root = temporary_directory!(context)

      path =
        write_catalog!(root, [
          catalog_repository("alpha",
            projects: [catalog_project("alpha")],
            dependency_sources: %{
              "beta" => %{
                "hex" => %{"requirement" => "~> 1.0", "package" => "beta_fork"},
                "order" => ["hex"]
              }
            }
          )
        ])

      registry = Registry.load!(path)
      declaration = Registry.dependency_sources(registry, "alpha")["beta"]
      assert declaration.hex == "~> 1.0"
      assert declaration.hex_package == "beta_fork"
    end

    test "lineage is parsed as documentation on a project", context do
      root = temporary_directory!(context)

      registry =
        root
        |> write_catalog!([
          catalog_repository("alpha",
            projects: [catalog_project("alpha", lineage: "predecessor.alpha")]
          )
        ])
        |> Registry.load!()

      assert Registry.project!(registry, "alpha").lineage == "predecessor.alpha"
    end

    test "carries a declared order, publish order, and Mix options", context do
      root = temporary_directory!(context)

      registry =
        root
        |> write_catalog!([
          catalog_repository("alpha",
            projects: [catalog_project("alpha")],
            dependency_sources: %{
              "sprite" => %{
                "github" => %{"repo" => "other-org/sprite-ex", "branch" => "main"},
                "order" => ["github"],
                "publish_order" => ["github"],
                "opts" => %{"override" => true, "only" => ["dev", "test"], "runtime" => false}
              }
            }
          )
        ])
        |> Registry.load!()

      declaration = Registry.dependency_sources(registry, "alpha")["sprite"]

      assert declaration.order == ["github"]
      assert declaration.publish_order == ["github"]

      assert declaration.opts == %{
               "override" => true,
               "only" => ["dev", "test"],
               "runtime" => false
             }

      assert declaration.github.repo == "other-org/sprite-ex"
      assert declaration.github.branch == "main"
      refute Source.reaches?(declaration, "local")
    end

    test "an order may not name a source the declaration does not carry", context do
      root = temporary_directory!(context)

      path =
        write_catalog!(root, [
          catalog_repository("alpha",
            projects: [catalog_project("alpha")],
            dependency_sources: %{"beta" => %{"order" => ["hex"]}}
          )
        ])

      assert {:error, {:undeclared_source, {"alpha", "beta"}, :order, ["hex"]}} =
               Registry.load(path)
    end

    test "a local source needs a catalogued provider", context do
      root = temporary_directory!(context)

      path =
        write_catalog!(root, [
          catalog_repository("alpha",
            projects: [catalog_project("alpha")],
            dependency_sources: %{"beta" => %{"hex" => "~> 0.1.0"}}
          )
        ])

      assert {:error, {:dependency_source, "alpha", {:unprovided_application, "beta"}}} =
               Registry.load(path)
    end

    test "an uncatalogued application resolves once the order omits local", context do
      root = temporary_directory!(context)

      registry =
        root
        |> write_catalog!([
          catalog_repository("alpha",
            projects: [catalog_project("alpha")],
            dependency_sources: %{"beta" => %{"hex" => "~> 0.1.0", "order" => ["hex"]}}
          )
        ])
        |> Registry.load!()

      assert Registry.dependency_sources(registry, "alpha")["beta"].order == ["hex"]
    end

    test "rejects unknown keys, options, and conflicting revisions", context do
      root = temporary_directory!(context)

      declaration = fn source ->
        write_catalog!(root, [
          catalog_repository("alpha",
            projects: [catalog_project("alpha")],
            dependency_sources: %{"beta" => source}
          ),
          catalog_repository("beta", projects: [catalog_project("beta")])
        ])
      end

      assert {:error, {:unknown_dependency_source_keys, {"alpha", "beta"}, ["path"]}} =
               Registry.load(declaration.(%{"path" => "../beta"}))

      assert {:error, {:unknown_dependency_option, {"alpha", "beta"}, "manager"}} =
               Registry.load(declaration.(%{"opts" => %{"manager" => "rebar"}}))

      assert {:error, {:conflicting_github_revision, {"alpha", "beta"}, ["branch", "tag"]}} =
               Registry.load(
                 declaration.(%{
                   "github" => %{"repo" => "example-org/beta", "branch" => "main", "tag" => "v1"}
                 })
               )

      assert {:error, {:invalid_hex_requirement, {"alpha", "beta"}, "0.1"}} =
               Registry.load(declaration.(%{"hex" => "0.1"}))
    end

    test "a project entry replaces the repository entry for one application", context do
      root = temporary_directory!(context)

      registry =
        root
        |> write_catalog!([
          catalog_repository("alpha",
            projects: [
              catalog_project("alpha.root", app: "alpha_root", kind: "workspace_root"),
              catalog_project("alpha.child",
                app: "alpha_child",
                path: "apps/alpha_child",
                kind: "package",
                dependency_sources: %{"beta" => %{"hex" => "~> 0.2.0"}}
              )
            ],
            dependency_sources: %{
              "beta" => %{"hex" => "~> 0.1.0"},
              "gamma" => %{"hex" => "~> 0.1.0"}
            }
          ),
          catalog_repository("beta", projects: [catalog_project("beta")]),
          catalog_repository("gamma", projects: [catalog_project("gamma")])
        ])
        |> Registry.load!()

      root_table = Registry.dependency_sources(registry, "alpha.root")
      child_table = Registry.dependency_sources(registry, "alpha.child")

      assert root_table["beta"].hex == "~> 0.1.0"
      assert child_table["beta"].hex == "~> 0.2.0"
      assert child_table["gamma"].hex == "~> 0.1.0"
    end
  end

  describe "workspace membership" do
    test "records the derivation mechanism and its exceptions", context do
      root = temporary_directory!(context)

      registry =
        root
        |> write_catalog!([
          catalog_repository("alpha",
            projects: [
              catalog_project("alpha.root", app: "alpha_root", kind: "workspace_root"),
              catalog_project("alpha.core", app: "alpha_core", path: "core", kind: "package"),
              catalog_project("alpha.output",
                app: "alpha_output",
                path: "packaging/consumer",
                kind: "generated"
              )
            ],
            workspace: %{"kind" => "blitz", "exclude_project_ids" => ["alpha.output"]}
          )
        ])
        |> Registry.load!()

      workspace = registry.repositories["alpha"].workspace

      assert workspace.kind == "blitz"
      assert workspace.exclude_project_ids == ["alpha.output"]
      assert workspace.include_project_ids == []
      assert registry.projects["alpha.output"].kind == "generated"
    end

    test "rejects an exception naming a project of another repository", context do
      root = temporary_directory!(context)

      path =
        write_catalog!(root, [
          catalog_repository("alpha",
            projects: [catalog_project("alpha")],
            workspace: %{"kind" => "umbrella", "exclude_project_ids" => ["beta"]}
          ),
          catalog_repository("beta", projects: [catalog_project("beta")])
        ])

      assert {:error, {:unknown_workspace_members, "alpha", ["beta"]}} = Registry.load(path)
    end

    test "rejects an unknown workspace kind", context do
      root = temporary_directory!(context)

      path =
        write_catalog!(root, [
          catalog_repository("alpha",
            projects: [catalog_project("alpha")],
            workspace: %{"kind" => "poncho"}
          )
        ])

      assert {:error, {:invalid_field, :workspace_kind, "poncho"}} = Registry.load(path)
    end
  end
end