defmodule MixWorkspaceOps.ResolutionTest do
  use MixWorkspaceOps.WorkspaceCase, async: true

  alias MixWorkspaceOps.{LocalOverrides, Registry, Resolution}
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

  describe "publish mode" do
    test "resolves through the publish order rather than the ordinary one", context do
      root = temporary_directory!(context)
      initialize_repository!(Path.join(root, "core"))
      initialize_repository!(Path.join(root, "consumer"))
      declaration = %{"github" => %{"repo" => "example-org/core"}, "hex" => "~> 1.0"}
      registry = registry(root, declaration)

      assert {:ok, development} = decide(registry, root, "core", declaration)
      assert development.source == "local"

      assert {:ok, publishing} = decide(registry, root, "core", declaration, publish?: true)
      assert publishing.source == "hex"
      assert publishing.reason == :publish
      assert publishing.location == "~> 1.0"
    end

    test "a configured publish order naming another source is honoured", context do
      root = temporary_directory!(context)
      initialize_repository!(Path.join(root, "core"))
      initialize_repository!(Path.join(root, "consumer"))

      declaration = %{
        "github" => %{"repo" => "example-org/core", "branch" => "main"},
        "order" => ["local", "github"],
        "publish_order" => ["github"]
      }

      registry = registry(root, declaration)

      assert {:ok, publishing} = decide(registry, root, "core", declaration, publish?: true)
      assert publishing.source == "github"
      assert publishing.reason == :publish
    end

    test "publishing a dependency with nothing to publish from is a typed error", context do
      root = temporary_directory!(context)
      initialize_repository!(Path.join(root, "core"))
      initialize_repository!(Path.join(root, "consumer"))
      declaration = %{"github" => %{"repo" => "example-org/core"}, "order" => ["local", "github"]}
      registry = registry(root, declaration)

      assert {:error, {:no_available_source, "core", ["hex"]}} =
               decide(registry, root, "core", declaration, publish?: true)
    end
  end

  describe "overrides" do
    test "each gesture wins over the one below it", context do
      root = temporary_directory!(context)
      initialize_repository!(Path.join(root, "core"))
      initialize_repository!(Path.join(root, "consumer"))

      declaration = %{
        "github" => %{"repo" => "example-org/core", "branch" => "main"},
        "hex" => "~> 1.0"
      }

      registry = registry(root, declaration)
      file = %{"core" => %{LocalOverrides.empty() | source: "github"}}

      assert {:ok, ordered} = decide(registry, root, "core", declaration)
      assert {ordered.source, ordered.reason} == {"local", :order}

      assert {:ok, run_mode} = decide(registry, root, "core", declaration, mode: "hex")
      assert {run_mode.source, run_mode.reason} == {"hex", :run_mode}

      assert {:ok, from_file} =
               decide(registry, root, "core", declaration, mode: "hex", overrides: file)

      assert {from_file.source, from_file.reason} == {"github", :local_override}

      assert {:ok, per_dependency} =
               decide(registry, root, "core", declaration,
                 mode: "hex",
                 overrides: file,
                 sources: %{"core" => "local"}
               )

      assert {per_dependency.source, per_dependency.reason} == {"local", :dependency_override}

      assert {:ok, publishing} =
               decide(registry, root, "core", declaration,
                 publish?: true,
                 sources: %{"core" => "hex"}
               )

      assert {publishing.source, publishing.reason} == {"hex", :publish}
    end

    test "an override bypasses an order that never reaches the source", context do
      root = temporary_directory!(context)
      initialize_repository!(Path.join(root, "core"))
      initialize_repository!(Path.join(root, "consumer"))
      declaration = %{"hex" => "~> 1.0", "order" => ["hex"]}
      registry = registry(root, declaration)

      assert {:ok, decision} =
               decide(registry, root, "core", declaration,
                 overrides: %{"core" => %{LocalOverrides.empty() | source: "local"}}
               )

      assert decision.source == "local"
      assert decision.location == Path.join(root, "core")
      assert decision.provider_project_id == "core"
    end

    test "an override path replaces the derived one", context do
      root = temporary_directory!(context)
      elsewhere = Path.join(root, "elsewhere/core")
      initialize_repository!(elsewhere)
      initialize_repository!(Path.join(root, "core"))
      initialize_repository!(Path.join(root, "consumer"))
      declaration = %{"hex" => "~> 1.0", "order" => ["hex"]}
      registry = registry(root, declaration)

      override = %{LocalOverrides.empty() | source: "local", path: [elsewhere]}

      assert {:ok, decision} =
               decide(registry, root, "core", declaration, overrides: %{"core" => override})

      assert decision.location == elsewhere
    end

    test "an override path takes the first candidate that is a checkout", context do
      root = temporary_directory!(context)
      elsewhere = Path.join(root, "elsewhere/core")
      initialize_repository!(elsewhere)
      initialize_repository!(Path.join(root, "core"))
      initialize_repository!(Path.join(root, "consumer"))
      declaration = %{"hex" => "~> 1.0", "order" => ["hex"]}
      registry = registry(root, declaration)

      override = %{
        LocalOverrides.empty()
        | source: "local",
          path: [Path.join(root, "nowhere"), elsewhere, Path.join(root, "core")]
      }

      assert {:ok, decision} =
               decide(registry, root, "core", declaration, overrides: %{"core" => override})

      assert decision.location == elsewhere

      unusable = %{LocalOverrides.empty() | source: "local", path: [Path.join(root, "nowhere")]}

      assert {:error, {:unavailable_source, "core", "local", :local_override}} =
               decide(registry, root, "core", declaration, overrides: %{"core" => unusable})
    end

    test "an override replaces the requirement and merges the coordinates", context do
      root = temporary_directory!(context)
      initialize_repository!(Path.join(root, "core"))
      initialize_repository!(Path.join(root, "consumer"))

      declaration = %{
        "github" => %{"repo" => "example-org/core", "branch" => "main"},
        "hex" => "~> 1.0"
      }

      registry = registry(root, declaration)

      assert {:ok, requirement} =
               decide(registry, root, "core", declaration,
                 overrides: %{"core" => %{LocalOverrides.empty() | source: "hex", hex: "~> 2.0"}}
               )

      assert requirement.location == "~> 2.0"

      assert {:ok, coordinates} =
               decide(registry, root, "core", declaration,
                 overrides: %{
                   "core" => %{
                     LocalOverrides.empty()
                     | source: "github",
                       github: %{"branch" => "trial"}
                   }
                 }
               )

      assert coordinates.location.repo == "example-org/core"
      assert coordinates.location.branch == "trial"
    end

    test "an override keyed on catalog identity reaches a Hex-only declaration", context do
      root = temporary_directory!(context)
      initialize_repository!(Path.join(root, "core"))
      initialize_repository!(Path.join(root, "consumer"))

      # The declaration names no provider and its order never reaches local,
      # which is the shape an override has to work against.
      declaration = %{"hex" => "~> 1.0", "order" => ["hex"]}
      registry = registry(root, declaration)

      assert {:ok, ordinary} = decide(registry, root, "core", declaration)
      assert ordinary.source == "hex"

      assert {:ok, overridden} =
               decide(registry, root, "core", declaration,
                 overrides: %{"core" => %{LocalOverrides.empty() | source: "local"}}
               )

      assert overridden.source == "local"
      assert overridden.provider_project_id == "core"
    end

    test "publishing refuses every gesture asking for a non-Hex source", context do
      root = temporary_directory!(context)
      initialize_repository!(Path.join(root, "core"))
      initialize_repository!(Path.join(root, "consumer"))
      declaration = %{"github" => %{"repo" => "example-org/core"}, "hex" => "~> 1.0"}
      registry = registry(root, declaration)

      assert {:error, {:unpublishable_local_override, "core", "path"}} =
               decide(registry, root, "core", declaration,
                 publish?: true,
                 overrides: %{
                   "core" => %{LocalOverrides.empty() | source: "local", requested_source: "path"}
                 }
               )

      assert {:error, {:unpublishable_source_override, "core", "local"}} =
               decide(registry, root, "core", declaration,
                 publish?: true,
                 sources: %{"core" => "local"}
               )

      assert {:error, {:unpublishable_run_mode, "github"}} =
               decide(registry, root, "core", declaration, publish?: true, mode: "github")

      assert {:ok, allowed} =
               decide(registry, root, "core", declaration,
                 publish?: true,
                 overrides: %{"core" => %{LocalOverrides.empty() | source: "hex"}}
               )

      assert allowed.source == "hex"
    end

    test "a configured publish order is honoured while an override is refused", context do
      root = temporary_directory!(context)
      initialize_repository!(Path.join(root, "core"))
      initialize_repository!(Path.join(root, "consumer"))

      declaration = %{
        "github" => %{"repo" => "example-org/core", "branch" => "main"},
        "order" => ["local", "github"],
        "publish_order" => ["github"]
      }

      registry = registry(root, declaration)

      assert {:ok, honoured} = decide(registry, root, "core", declaration, publish?: true)
      assert honoured.source == "github"

      assert {:error, {:unpublishable_local_override, "core", "path"}} =
               decide(registry, root, "core", declaration,
                 publish?: true,
                 overrides: %{
                   "core" => %{LocalOverrides.empty() | source: "local", requested_source: "path"}
                 }
               )
    end

    test "a named source that cannot be built from is a typed error", context do
      root = temporary_directory!(context)
      initialize_repository!(Path.join(root, "core"))
      initialize_repository!(Path.join(root, "consumer"))
      declaration = %{"hex" => "~> 1.0"}
      registry = registry(root, declaration)

      assert {:error, {:unavailable_source, "core", "github", :run_mode}} =
               decide(registry, root, "core", declaration, mode: "github")

      assert {:error, {:unavailable_source, "core", "local", :dependency_override}} =
               decide(registry, root, "core", declaration,
                 sources: %{"core" => "local"},
                 overrides: %{"core" => %{LocalOverrides.empty() | path: ["/nowhere/at/all"]}}
               )
    end

    test "resolve reads the override file from the consuming repository root", context do
      root = temporary_directory!(context)
      initialize_repository!(Path.join(root, "core"))
      consumer = initialize_repository!(Path.join(root, "consumer"))

      registry =
        root
        |> write_catalog!([
          catalog_repository("core", projects: [catalog_project("core")]),
          catalog_repository("consumer",
            projects: [catalog_project("consumer")],
            dependency_sources: %{"core" => %{"hex" => "~> 1.0", "order" => ["hex"]}}
          )
        ])
        |> Registry.load!()
        |> bind!(root)

      File.write!(
        Path.join(consumer, LocalOverrides.filename()),
        ~s|%{deps: %{core: %{source: :path}}}|
      )

      assert {:ok, report} =
               Resolution.resolve(registry, "consumer", dependency_reader: &reader/1)

      assert [decision] = report.decisions
      assert decision.source == "local"
      assert decision.reason == :local_override
      assert Map.keys(report.overrides) == ["core"]
    end
  end

  describe "the sources report" do
    test "says where each dependency comes from and what is there", context do
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

      assert [local, github] = Resolution.sources(report)

      assert local == %{
               application: "core",
               source: "local",
               reason: :order,
               provider: "core",
               location: Path.join(root, "core"),
               version: "0.1.0",
               opts: []
             }

      assert github.location == "example-org/third-party"
      assert github.version == "branch main"

      assert Resolution.format_sources([local, github]) ==
               """
               dependency sources:
                 core -> local (#{Path.join(root, "core")}) -> 0.1.0
                 third_party -> github (example-org/third-party) -> branch main\
               """

      assert Resolution.format_sources([]) == "dependency sources: (no managed dependencies)"
    end

    test "a hex source reports the requirement as its version", context do
      root = temporary_directory!(context)
      initialize_repository!(Path.join(root, "core"))
      initialize_repository!(Path.join(root, "consumer"))
      declaration = %{"hex" => "~> 1.0", "order" => ["hex"]}

      registry =
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

      assert {:ok, report} =
               Resolution.resolve(registry, "consumer", dependency_reader: &reader/1)

      assert [entry] = Resolution.sources(report)
      assert %{source: "hex", location: "hex", version: "~> 1.0"} = entry
    end
  end

  defp reader(%{id: "consumer"}), do: {:ok, ["core", "third_party"]}
  defp reader(_project), do: {:ok, []}

  defp decide(registry, root, app, declaration, opts \\ []) do
    Resolution.decide(
      registry,
      app,
      parse!(declaration),
      Keyword.put(opts, :consumer_root, Path.join(root, "consumer"))
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
