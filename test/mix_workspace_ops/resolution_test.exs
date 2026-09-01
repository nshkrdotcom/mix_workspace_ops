defmodule MixWorkspaceOps.ResolutionTest do
  use MixWorkspaceOps.WorkspaceCase, async: true

  alias MixWorkspaceOps.{Registry, Resolution, SourcePreferences}
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

  describe "operator source preferences" do
    test "command source, run mode, preference, then declared order define precedence", context do
      root = temporary_directory!(context)
      initialize_repository!(Path.join(root, "core"))
      initialize_repository!(Path.join(root, "consumer"))

      declaration = %{
        "github" => %{"repo" => "example-org/core", "branch" => "main"},
        "hex" => "~> 1.0"
      }

      registry = registry(root, declaration)

      assert {:ok, ordered} = decide(registry, root, "core", declaration)
      assert {ordered.source, ordered.reason} == {"local", :order}

      assert {:ok, preferred} =
               decide(registry, root, "core", declaration, preferences: %{"core" => "git"})

      assert {preferred.source, preferred.reason} == {"github", :source_preference}

      assert {:ok, run_mode} =
               decide(registry, root, "core", declaration,
                 preferences: %{"core" => "git"},
                 mode: "hex"
               )

      assert {run_mode.source, run_mode.reason} == {"hex", :run_mode}

      assert {:ok, per_dependency} =
               decide(registry, root, "core", declaration,
                 preferences: %{"core" => "git"},
                 mode: "hex",
                 sources: %{"core" => "local"}
               )

      assert {per_dependency.source, per_dependency.reason} == {"local", :dependency_override}
    end

    test "a persisted preference names only an eligible registry-declared source", context do
      root = temporary_directory!(context)
      initialize_repository!(Path.join(root, "core"))
      initialize_repository!(Path.join(root, "consumer"))
      declaration = %{"hex" => "~> 1.0", "order" => ["hex"]}
      registry = registry(root, declaration)

      assert {:error, {:ineligible_source, "core", "local", :source_preference}} =
               decide(registry, root, "core", declaration, preferences: %{"core" => "local"})

      assert {:ok, decision} =
               decide(registry, root, "core", declaration, preferences: %{"core" => "hex"})

      assert decision.location == "~> 1.0"
      assert decision.reason == :source_preference
    end

    test "resolve loads XDG SourcePreferences and never reads managed-repository override files", context do
      root = temporary_directory!(context)
      initialize_repository!(Path.join(root, "core"))
      initialize_repository!(Path.join(root, "consumer"))
      preferences = Path.join(root, "operator/source_preferences.json")

      registry =
        root
        |> write_catalog!([
          catalog_repository("core", projects: [catalog_project("core")]),
          catalog_repository("consumer",
            projects: [catalog_project("consumer")],
            dependency_sources: %{
              "core" => %{
                "github" => %{"repo" => "example-org/core"},
                "hex" => "~> 1.0"
              }
            }
          )
        ])
        |> Registry.load!()
        |> bind!(root)

      assert {:ok, ^preferences} = SourcePreferences.put(preferences, "consumer", "core", "git")

      assert {:ok, report} =
               Resolution.resolve(registry, "consumer",
                 dependency_reader: &reader/1,
                 source_preferences: preferences
               )

      assert report.preferences == %{"core" => "github"}
      assert [%{source: "github", reason: :source_preference}] = report.decisions
    end

    test "publish policy ignores operator preferences and follows publish_order", context do
      root = temporary_directory!(context)
      initialize_repository!(Path.join(root, "core"))
      initialize_repository!(Path.join(root, "consumer"))
      declaration = %{"github" => %{"repo" => "example-org/core"}, "hex" => "~> 1.0"}
      registry = registry(root, declaration)

      assert {:ok, decision} =
               decide(registry, root, "core", declaration,
                 publish?: true,
                 preferences: %{"core" => "local"}
               )

      assert decision.source == "hex"
      assert decision.reason == :publish
    end

    test "explicit git source still uses only registry coordinates", context do
      root = temporary_directory!(context)
      initialize_repository!(Path.join(root, "core"))
      initialize_repository!(Path.join(root, "consumer"))
      declaration = %{
        "github" => %{"repo" => "example-org/core", "branch" => "stable"},
        "hex" => "~> 1.0"
      }
      registry = registry(root, declaration)

      assert {:ok, decision} =
               decide(registry, root, "core", declaration, preferences: %{"core" => "git"})

      assert decision.location.repo == "example-org/core"
      assert decision.location.branch == "stable"
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
      assert line == ~s|workspace_dep({:beta, "~> 1.0"})|
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