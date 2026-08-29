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

      assert decision.provider_project_id == "core"

      assert {:ok, decision} =
               decide(registry, root, "core", Map.delete(declaration, "github"))

      assert decision.source == "hex"
      assert decision.location == "~> 1.0"
    end

    test "an empty GitHub declaration opts into derived coordinates", context do
      root = temporary_directory!(context)
      initialize_repository!(Path.join(root, "core"))
      initialize_repository!(Path.join(root, "consumer"))
      registry = registry(root, %{"github" => %{}})
      File.rm_rf!(Path.join(root, "core"))

      assert {:ok, derived} = decide(registry, root, "core", %{"github" => %{}})
      assert derived.source == "github"
      assert derived.location.repo == "example-org/core"
      assert derived.location.branch == "main"

      assert {:ok, declared} =
               decide(registry, root, "core", %{
                 "github" => %{"repo" => "other-org/fork", "ref" => "abc123"}
               })

      assert declared.location.repo == "other-org/fork"
      assert declared.location.ref == "abc123"

      assert {:ok, without_github} =
               decide(registry, root, "core", %{"hex" => "~> 1.0"})

      assert without_github.source == "hex"
      assert %{source: "github", outcome: :no_github_coordinates} in without_github.considered
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

      assert {:error, {:no_available_source, "core", ["local"], considered}} =
               decide(registry, root, "core", %{"hex" => "~> 1.0", "order" => ["local"]})

      assert considered == [%{source: "local", outcome: :missing_path}]
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

      # Without a provider the catalog cannot say which project this is, and
      # answering from Hex would answer a question nobody asked — and answer it
      # differently from the closure, which refuses the same input.
      assert {:error,
              {:ambiguous_application, "shared",
               [
                 %{project: "fork", repository: "fork"},
                 %{project: "upstream", repository: "upstream"}
               ]}} =
               decide(registry, root, "shared", %{"hex" => "~> 1.0"})
    end

    test "a provider naming a project that does not provide the application is an error",
         context do
      root = temporary_directory!(context)
      initialize_repository!(Path.join(root, "consumer"))
      initialize_repository!(Path.join(root, "upstream"))

      registry =
        root
        |> write_catalog!([
          catalog_repository("consumer", projects: [catalog_project("consumer")]),
          catalog_repository("upstream", projects: [catalog_project("upstream", app: "shared")])
        ])
        |> Registry.load!()
        |> bind!(root)

      assert {:error, {:unknown_provider, "shared", "absent", ["upstream"]}} =
               Resolution.decide(
                 registry,
                 "shared",
                 %{
                   github: nil,
                   hex: "~> 1.0",
                   provider: "absent",
                   order: Source.default_order(),
                   publish_order: Source.default_publish_order(),
                   opts: %{}
                 },
                 consumer_root: Path.join(root, "consumer")
               )
    end

    test "an application the catalog does not provide falls through to its declaration",
         context do
      root = temporary_directory!(context)
      initialize_repository!(Path.join(root, "consumer"))
      registry = registry(root, %{"hex" => "~> 1.0"})

      assert {:ok, decision} =
               decide(registry, root, "third_party", %{
                 "github" => %{"repo" => "example-org/third-party", "branch" => "main"}
               })

      assert decision.source == "github"

      assert decision.considered == [
               %{source: "local", outcome: :no_catalogued_provider},
               %{source: "github", outcome: :chosen},
               %{source: "hex", outcome: :not_reached}
             ]
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
    test "a renamed Hex package emits Mix's hex option", context do
      root = temporary_directory!(context)
      initialize_repository!(Path.join(root, "consumer"))
      registry = registry(root, %{"hex" => "~> 1.0"})

      assert {:ok, decision} =
               decide(registry, root, "third_party", %{
                 "hex" => %{"requirement" => "~> 2.0", "package" => "third_party_fork"},
                 "order" => ["hex"]
               })

      assert decision.location == "~> 2.0"
      assert decision.opts == [hex: :third_party_fork]
    end

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

  describe "which applications are decided" do
    # A catalogued application no table declares was never managed: the file
    # this replaces raised for one, and iterated its table and nothing else.
    # Deciding it anyway invented a declaration whose publish order is `hex`
    # with no requirement, so publish resolution could never complete.
    test "an application no dependency-source table declares is not decided", context do
      root = temporary_directory!(context)
      initialize_repository!(Path.join(root, "core"))
      initialize_repository!(Path.join(root, "third_party"))
      initialize_repository!(Path.join(root, "consumer"))

      registry =
        root
        |> write_catalog!([
          catalog_repository("core", projects: [catalog_project("core")]),
          catalog_repository("third_party", projects: [catalog_project("third_party")]),
          catalog_repository("consumer",
            projects: [catalog_project("consumer")],
            dependency_sources: %{"core" => %{"hex" => "~> 1.0"}}
          )
        ])
        |> Registry.load!()
        |> bind!(root)

      assert {:ok, report} =
               Resolution.resolve(registry, "consumer", dependency_reader: &reader/1)

      assert Enum.map(report.decisions, & &1.application) == ["core"]

      # And publish resolution completes, which it could not while the
      # undeclared application inherited a `hex` order with no requirement.
      assert {:ok, publishing} =
               Resolution.resolve(registry, "consumer",
                 dependency_reader: &reader/1,
                 publish?: true
               )

      assert Enum.map(publishing.decisions, &{&1.application, &1.source}) == [{"core", "hex"}]
    end

    test "a whole-closure mode names every application it cannot serve", context do
      root = temporary_directory!(context)
      initialize_repository!(Path.join(root, "core"))
      initialize_repository!(Path.join(root, "third_party"))
      initialize_repository!(Path.join(root, "consumer"))

      registry =
        root
        |> write_catalog!([
          catalog_repository("core", projects: [catalog_project("core")]),
          catalog_repository("third_party", projects: [catalog_project("third_party")]),
          catalog_repository("consumer",
            projects: [catalog_project("consumer")],
            dependency_sources: %{
              "core" => %{"order" => ["local"]},
              "third_party" => %{"order" => ["local"]}
            }
          )
        ])
        |> Registry.load!()
        |> bind!(root)

      assert {:error, {:unavailable_run_mode, "hex", ["core", "third_party"]}} =
               Resolution.resolve(registry, "consumer",
                 dependency_reader: &reader/1,
                 mode: "hex"
               )
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

      assert {:error, {:no_available_source, "core", ["hex"], considered}} =
               decide(registry, root, "core", declaration, publish?: true)

      assert considered == [%{source: "hex", outcome: :no_hex_requirement}]
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

      assert {:error, {:unavailable_source, "core", "local", :dependency_override}} =
               decide(registry, root, "core", declaration,
                 sources: %{"core" => "local"},
                 overrides: %{"core" => %{LocalOverrides.empty() | path: ["/nowhere/at/all"]}}
               )
    end

    # An explicit request is the operator overriding the declaration's intent,
    # and the catalog has held the provider's repository identity the whole
    # time. Refusing a declaration that carries no GitHub block made 82 of the
    # live catalog's 558 declarations unable to serve `--mode git` at all.
    test "an explicit git request falls back to the catalogued repository identity", context do
      root = temporary_directory!(context)
      core = initialize_repository!(Path.join(root, "core"))
      initialize_repository!(Path.join(root, "consumer"))
      declaration = %{"hex" => "~> 1.0"}
      registry = registry(root, declaration)
      head = MixWorkspaceOps.Git.head!(core)

      for opts <- [[mode: "github"], [sources: %{"core" => "github"}]] do
        assert {:ok, decision} = decide(registry, root, "core", declaration, opts)
        assert decision.source == "github"

        assert decision.location == %{
                 repo: "example-org/core",
                 branch: nil,
                 ref: head,
                 tag: nil,
                 subdir: nil
               }
      end
    end

    test "an explicit git request for an absent checkout pins the default branch", context do
      root = temporary_directory!(context)
      initialize_repository!(Path.join(root, "core"))
      initialize_repository!(Path.join(root, "consumer"))
      declaration = %{"hex" => "~> 1.0"}
      registry = registry(root, declaration)
      File.rm_rf!(Path.join(root, "core"))
      registry = bind!(registry, root)

      assert {:ok, decision} = decide(registry, root, "core", declaration, mode: "github")
      assert decision.location.branch == "main"
      assert decision.location.ref == nil
    end

    # An order states the declaration's intent. Falling back there would change
    # how every declaration with no GitHub block resolves in development.
    test "the order walk does not fall back to the catalogued identity", context do
      root = temporary_directory!(context)
      initialize_repository!(Path.join(root, "core"))
      initialize_repository!(Path.join(root, "consumer"))
      declaration = %{"hex" => "~> 1.0"}
      registry = registry(root, declaration)
      File.rm_rf!(Path.join(root, "core"))
      registry = bind!(registry, root)

      assert {:ok, decision} = decide(registry, root, "core", declaration)
      assert decision.source == "hex"

      assert decision.considered == [
               %{source: "local", outcome: :absent_checkout},
               %{source: "github", outcome: :no_github_coordinates},
               %{source: "hex", outcome: :chosen}
             ]
    end

    test "resolve reads the override file from the consuming project root", context do
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

  describe "where the consumer is" do
    # The file this replaces read its override from the Mix project root, and
    # ten of the fifty-two live installs sit in a subproject. Reading from the
    # repository checkout instead means those ten read a file that is not there
    # and silently apply no override.
    test "a project inside a repository reads its own override file", context do
      root = temporary_directory!(context)
      initialize_repository!(Path.join(root, "core"))
      repository = initialize_repository!(Path.join(root, "workspace"))
      leaf = Path.join(repository, "apps/leaf")
      File.mkdir_p!(leaf)
      File.write!(Path.join(leaf, "mix.exs"), "# leaf\n")

      registry =
        root
        |> write_catalog!([
          catalog_repository("core", projects: [catalog_project("core")]),
          catalog_repository("workspace",
            projects: [
              catalog_project("workspace", kind: "workspace_root", app: nil),
              catalog_project("workspace.leaf", app: "leaf", path: "apps/leaf")
            ],
            dependency_sources: %{"core" => %{"hex" => "~> 1.0", "order" => ["hex"]}}
          )
        ])
        |> Registry.load!()
        |> bind!(root)

      reader = fn
        %{id: "workspace.leaf"} -> {:ok, ["core"]}
        _project -> {:ok, []}
      end

      # At the repository root, where the file is not, the override is absent.
      File.write!(
        Path.join(repository, LocalOverrides.filename()),
        ~s|%{deps: %{core: %{source: :path}}}|
      )

      assert {:ok, unread} =
               Resolution.resolve(registry, "workspace.leaf", dependency_reader: reader)

      assert unread.consumer_root == leaf
      assert [%{source: "hex"}] = unread.decisions

      # Beside the project, where a Mix command runs, it is read.
      File.write!(
        Path.join(leaf, LocalOverrides.filename()),
        ~s|%{deps: %{core: %{source: :path}}}|
      )

      assert {:ok, read} =
               Resolution.resolve(registry, "workspace.leaf", dependency_reader: reader)

      assert [%{source: "local", reason: :local_override}] = read.decisions
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
               classification: :managed,
               source: "local",
               reason: :order,
               considered: [
                 %{source: "local", outcome: :chosen},
                 %{source: "github", outcome: :not_reached},
                 %{source: "hex", outcome: :not_reached}
               ],
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

  describe "the generated seam" do
    test "contains exactly the target's direct managed dependencies", context do
      root = temporary_directory!(context)
      for id <- ~w(alpha beta gamma), do: initialize_repository!(Path.join(root, id))

      source = fn requirement ->
        %{"hex" => requirement, "order" => ["hex"], "publish_order" => ["hex"]}
      end

      registry =
        root
        |> write_catalog!([
          catalog_repository("alpha",
            dependency_sources: %{"beta" => source.("~> 1.0")},
            projects: [catalog_project("alpha")]
          ),
          catalog_repository("beta",
            dependency_sources: %{"gamma" => source.("~> 2.0")},
            projects: [catalog_project("beta")]
          ),
          catalog_repository("gamma", projects: [catalog_project("gamma")])
        ])
        |> Registry.load!()
        |> bind!(root)

      reader = fn
        %{id: "alpha"} -> {:ok, ["beta"]}
        %{id: "beta"} -> {:ok, ["gamma"]}
        _project -> {:ok, []}
      end

      assert {:ok, report} =
               Resolution.resolve(registry, "alpha", publish?: true, dependency_reader: reader)

      assert Enum.map(report.decisions, & &1.application) == ["beta", "gamma"]
      assert {:ok, [line]} = Resolution.seam_lines(report)
      assert line =~ "workspace_dep(:beta,"
      refute line =~ ":gamma"
    end
  end

  describe "explaining a refusal" do
    # The message the file this replaces printed for a refused override was a
    # sentence; the tuple that replaced it names the same fact and says nothing
    # about what to do. Both now reach the operator.
    test "every error resolution produces reads as a sentence" do
      sentences = [
        {{:no_available_source, "weld", ["local", "hex"],
          [
            %{source: "local", outcome: :absent_checkout},
            %{source: "hex", outcome: :no_hex_requirement}
          ]},
         "nothing can supply weld. Tried local (the provider's repository has no checkout), " <>
           "hex (the declaration carries no hex requirement). " <>
           "Add a valid `hex` requirement for weld, or remove hex from its order."},
        {{:unavailable_source, "weld", "github", :run_mode},
         "--mode asked for github for weld, and there is nothing to build it from. " <>
           "Add `github: %{}` for weld, or choose a catalogued provider."},
        {{:unavailable_run_mode, "github", ["blitz", "weld"]},
         "--mode git cannot serve blitz, weld. Add that source to each named declaration, " <>
           "or override only the applications that can use it."},
        {{:unpublishable_local_override, "execution_plane", "path"},
         "publish mode follows the declared publish order; " <>
           "the local override for execution_plane requests :path."},
        {{:unpublishable_source_override, "weld", "local"},
         "publish mode follows the declared publish order; " <>
           "--source weld=local requests another source."},
        {{:unpublishable_run_mode, "local"},
         "publish mode follows the declared publish order; --mode local requests another source."},
        {{:absent_required_checkout, "weld", "/checkouts/weld"},
         "the repository weld has no checkout at /checkouts/weld. Clone it there, " <>
           "or record where it is in a binding file."}
      ]

      for {error, sentence} <- sentences, do: assert(Resolution.explain(error) == sentence)

      assert Resolution.explain({:ambiguous_application, "shared", ["fork", "upstream"], "alpha"}) =~
               "fork and upstream both provide shared"

      assert Resolution.explain({
               :ambiguous_application,
               "shared",
               [
                 %{project: "fork", repository: "fork_repo"},
                 %{project: "upstream", repository: "upstream_repo"}
               ]
             }) ==
               "fork (repository fork_repo) and upstream (repository upstream_repo) both provide shared. " <>
                 "Set `shared: %{provider: \"PROJECT_ID\"}` in the consumer's dependency-source " <>
                 "declaration, choosing one of those project ids."

      assert Resolution.explain({:command_failed, :anything}) == nil
    end
  end

  describe "why/4" do
    test "names the identity rule, rejected sources, and both change gestures", context do
      root = temporary_directory!(context)
      initialize_repository!(Path.join(root, "core"))
      initialize_repository!(Path.join(root, "consumer"))
      declaration = %{"github" => %{}, "hex" => "~> 1.0"}
      registry = registry(root, declaration)
      reader = fn project -> {:ok, if(project.id == "consumer", do: ["core"], else: [])} end

      assert {:ok, explanation} =
               Resolution.why(registry, "consumer", "core", dependency_reader: reader)

      assert explanation.identity_rule == :only_provider
      assert explanation.provider == "core"
      assert explanation.source == "local"
      assert explanation.report =~ "identity: only_provider selected core"
      assert explanation.report =~ "mwo use core local|git|hex"
      assert explanation.report =~ ~s(core: %{provider: "PROJECT_ID"})
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
