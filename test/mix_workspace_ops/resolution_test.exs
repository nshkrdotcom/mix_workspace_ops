defmodule MixWorkspaceOps.ResolutionTest do
  use MixWorkspaceOps.WorkspaceCase, async: true

  alias MixWorkspaceOps.{Registry, Resolution}
  alias MixWorkspaceOps.Registry.Source

  describe "ordered resolution" do
    test "falls from local to github to hex with no configuration change", context do
      root = temporary_directory!(context)
      initialize_repository!(Path.join(root, "core"))
      initialize_repository!(Path.join(root, "consumer"))

      declaration = %{
        "github" => %{"repo" => "example-org/core", "branch" => "main"},
        "hex" => "~> 1.0"
      }

      registry = registry(root, declaration)

      assert {:ok, decision} = decide(registry, root, "core", declaration)
      assert decision.source == "local"
      assert decision.reason == :order
      assert decision.location == Path.join(root, "core")
      assert decision.provider_project_id == "core"

      File.rm_rf!(Path.join(root, "core"))

      assert {:ok, decision} = decide(registry, root, "core", declaration)
      assert decision.source == "github"

      assert decision.location == %{
               repo: "example-org/core",
               branch: "main",
               ref: nil,
               tag: nil,
               subdir: nil
             }

      assert decision.provider_project_id == nil

      assert {:ok, decision} =
               decide(registry, root, "core", Map.delete(declaration, "github"))

      assert decision.source == "hex"
      assert decision.location == "~> 1.0"
    end

    test "a derived path inside a Mix deps directory is not a sibling checkout", context do
      root = temporary_directory!(context)
      fetched_root = Path.join(root, "deps")
      File.mkdir_p!(fetched_root)
      initialize_repository!(Path.join(fetched_root, "core"))
      initialize_repository!(Path.join(fetched_root, "consumer"))
      initialize_repository!(Path.join(root, "sibling_consumer"))

      declaration = %{"hex" => "~> 1.0"}
      registry = registry(fetched_root, declaration)

      assert {:ok, sibling} =
               Resolution.decide(registry, "core", parse!(declaration),
                 consumer_root: Path.join(root, "sibling_consumer")
               )

      assert sibling.source == "local"
      assert sibling.location == Path.join(fetched_root, "core")

      assert {:ok, fetched} =
               Resolution.decide(registry, "core", parse!(declaration),
                 consumer_root: Path.join(fetched_root, "consumer")
               )

      assert fetched.source == "hex"
      assert Resolution.mix_deps_ancestor(Path.join(fetched_root, "consumer")) == fetched_root
      assert Resolution.mix_deps_ancestor(Path.join(root, "sibling_consumer")) == nil
    end

    test "no available candidate names the application and the order walked", context do
      root = temporary_directory!(context)
      initialize_repository!(Path.join(root, "core"))
      initialize_repository!(Path.join(root, "consumer"))
      registry = registry(root, %{"hex" => "~> 1.0"})
      File.rm_rf!(Path.join(root, "core"))

      assert {:error, {:no_available_source, "core", ["local"]}} =
               decide(registry, root, "core", %{"hex" => "~> 1.0", "order" => ["local"]})
    end

    test "an absent checkout falls through instead of failing", context do
      root = temporary_directory!(context)
      initialize_repository!(Path.join(root, "consumer"))

      registry =
        root
        |> write_catalog!([
          catalog_repository("core", projects: [catalog_project("core")]),
          catalog_repository("consumer", projects: [catalog_project("consumer")])
        ])
        |> Registry.load!()
        |> bind!(root)

      assert Registry.absent_repository_ids(registry) == ["core"]

      assert {:ok, decision} = decide(registry, root, "core", %{"hex" => "~> 1.0"})
      assert decision.source == "hex"
    end

    test "a declared provider selects among several catalogued providers", context do
      root = temporary_directory!(context)
      initialize_repository!(Path.join(root, "consumer"))
      initialize_repository!(Path.join(root, "upstream"))
      initialize_repository!(Path.join(root, "fork"))

      registry =
        root
        |> write_catalog!([
          catalog_repository("consumer", projects: [catalog_project("consumer")]),
          catalog_repository("upstream",
            projects: [catalog_project("upstream", app: "shared")]
          ),
          catalog_repository("fork", projects: [catalog_project("fork", app: "shared")])
        ])
        |> Registry.load!()
        |> bind!(root)

      assert {:ok, decision} =
               decide(registry, root, "shared", %{"provider" => "fork", "hex" => "~> 1.0"})

      assert decision.source == "local"
      assert decision.provider_project_id == "fork"
      assert decision.location == Path.join(root, "fork")

      assert {:ok, ambiguous} = decide(registry, root, "shared", %{"hex" => "~> 1.0"})
      assert ambiguous.source == "hex"
    end

    test "an explicit order is walked exactly as declared", context do
      root = temporary_directory!(context)
      initialize_repository!(Path.join(root, "core"))
      initialize_repository!(Path.join(root, "consumer"))
      registry = registry(root, %{"hex" => "~> 1.0"})

      assert {:ok, decision} =
               decide(registry, root, "core", %{
                 "hex" => "~> 1.0",
                 "github" => %{"repo" => "example-org/core"},
                 "order" => ["hex", "local"]
               })

      assert decision.source == "hex"
    end
  end

  describe "emitted options" do
    test "carries the declared options and re-atomizes environment names", context do
      root = temporary_directory!(context)
      initialize_repository!(Path.join(root, "core"))
      initialize_repository!(Path.join(root, "consumer"))
      registry = registry(root, %{"hex" => "~> 1.0"})

      assert {:ok, decision} =
               decide(registry, root, "core", %{
                 "hex" => "~> 1.0",
                 "opts" => %{
                   "override" => true,
                   "runtime" => false,
                   "optional" => true,
                   "only" => ["dev", "test"],
                   "targets" => ["host"]
                 }
               })

      assert decision.opts == [
               only: [:dev, :test],
               optional: true,
               override: true,
               runtime: false,
               targets: [:host]
             ]
    end

    test "refuses an option list beyond the atom bound", context do
      root = temporary_directory!(context)

      path =
        write_catalog!(root, [
          catalog_repository("core",
            projects: [catalog_project("core")],
            dependency_sources: %{
              "other" => %{"hex" => "~> 1.0", "opts" => %{"only" => List.duplicate("dev", 9)}}
            }
          )
        ])

      assert {:error, {:dependency_option_too_long, _where, "only", 8}} = Registry.load(path)
    end
  end

  describe "resolve/3 over a closure" do
    test "decides every application the closure depends on and no seed", context do
      root = temporary_directory!(context)
      initialize_repository!(Path.join(root, "core"))
      initialize_repository!(Path.join(root, "consumer"))

      registry =
        root
        |> write_catalog!([
          catalog_repository("core", projects: [catalog_project("core")]),
          catalog_repository("consumer",
            projects: [catalog_project("consumer")],
            dependency_sources: %{
              "core" => %{"hex" => "~> 1.0"},
              "third_party" => %{
                "github" => %{"repo" => "example-org/third-party", "branch" => "main"},
                "order" => ["github"],
                "publish_order" => ["github"]
              }
            }
          )
        ])
        |> Registry.load!()
        |> bind!(root)

      assert {:ok, report} =
               Resolution.resolve(registry, "consumer", dependency_reader: &reader/1)

      assert Enum.map(report.decisions, & &1.application) == ["core", "third_party"]
      assert Enum.map(report.decisions, & &1.source) == ["local", "github"]
      assert report.consumer_root == Path.join(root, "consumer")

      third_party = Enum.find(report.decisions, &(&1.application == "third_party"))
      assert third_party.declared_by == ["consumer"]
      assert third_party.provider_project_id == nil
    end
  end

  defp reader(%{id: "consumer"}), do: {:ok, ["core", "third_party"]}
  defp reader(_project), do: {:ok, []}

  defp decide(registry, root, app, declaration) do
    Resolution.decide(registry, app, parse!(declaration),
      consumer_root: Path.join(root, "consumer")
    )
  end

  defp parse!(declaration) do
    declaration = Map.reject(declaration, fn {_key, value} -> is_nil(value) end)
    {:ok, parsed} = Source.parse(declaration, "fixture", "core")
    parsed
  end

  defp registry(root, declaration) do
    root
    |> write_catalog!([
      catalog_repository("core", projects: [catalog_project("core")]),
      catalog_repository("consumer",
        projects: [catalog_project("consumer")],
        dependency_sources: %{"core" => declaration}
      )
    ])
    |> Registry.load!()
    |> bind!(root)
  end
end
