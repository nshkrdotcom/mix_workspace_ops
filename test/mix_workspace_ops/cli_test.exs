defmodule MixWorkspaceOps.CLITest do
  use MixWorkspaceOps.WorkspaceCase, async: false

  import ExUnit.CaptureIO

  alias MixWorkspaceOps.{CLI, Command, SourcePreferences}

  test "version is the Mix project version" do
    assert MixWorkspaceOps.version() == "0.1.0"
  end

  test "a missing executable is a structured command failure" do
    assert {:error, result} = Command.run("definitely_missing_mix_workspace_ops_command", [])
    assert result.exit_code == 127
    assert result.output != ""
  end

  test "the operator tool has no Hex package metadata" do
    refute Keyword.has_key?(Mix.Project.config(), :package)
    refute Keyword.has_key?(Mix.Project.config(), :description)
  end

  # -- the option surface --------------------------------------------------

  # Every option named in the usage text must reach the command that documents
  # it. `registry chain --package` shipped documented and unaccepted because the
  # option was added to the usage text and the defaults and not to the option
  # table; nothing exercised the path.
  test "every option the usage text documents is accepted by its command" do
    for {command, option} <- documented_options() do
      arguments = command ++ ["--#{option}", "value"] ++ command_terminator(command)

      refute CLI.dispatch(arguments) == {:usage_error, "unknown option --#{option}"},
             "#{Enum.join(command, " ")} does not accept --#{option}"
    end
  end

  # The other direction. A single global option table accepts every option on
  # every command, so a proof that documented options are accepted says nothing
  # about options reaching commands that have no use for them.
  test "no command accepts an option it does not document" do
    documented = documented_options()
    vocabulary = documented |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    for {command, options} <- Enum.group_by(documented, &elem(&1, 0), &elem(&1, 1)),
        option <- vocabulary -- options do
      arguments = command ++ ["--#{option}", "value"] ++ command_terminator(command)

      assert CLI.dispatch(arguments) ==
               {:usage_error, "#{Enum.join(command, " ")} does not accept --#{option}"},
             "#{Enum.join(command, " ")} accepts undocumented --#{option}"
    end
  end

  test "the usage text documents at least one option for every command that takes one" do
    documented = documented_options()

    assert Enum.map(documented, &elem(&1, 0)) |> Enum.uniq() |> Enum.sort() == [
             ["doctor"],
             ["impact"],
             ["plan"],
             ["registry", "chain"],
             ["registry", "discover"],
             ["registry", "drift"],
             ["registry", "select"],
             ["registry", "validate"],
             ["registry", "workspace"],
             ["release", "chain"],
             ["release", "plan"],
             ["run"],
             ["seam"],
             ["sources"],
             ["state", "gc"],
             ["state", "list"],
             ["use"],
             ["why"]
           ]

    assert {["registry", "chain"], "package"} in documented
  end

  test "an unknown option names itself" do
    assert CLI.dispatch(["registry", "validate", "--nonsense", "x"]) ==
             {:usage_error, "unknown option --nonsense"}
  end

  test "an option without a value is refused" do
    assert CLI.dispatch(["registry", "validate", "--registry"]) ==
             {:usage_error, "option --registry requires a value"}

    assert CLI.dispatch(["registry", "validate", "--registry", "--view"]) ==
             {:usage_error, "option --registry requires a value"}
  end

  # -- command shapes ------------------------------------------------------

  test "version prints and succeeds" do
    assert capture_io(fn -> assert CLI.dispatch(["version"]) == {:ok, nil} end) == "0.1.0\n"
  end

  test "help and no arguments both ask for usage" do
    assert CLI.dispatch(["help"]) == :usage
    assert CLI.dispatch([]) == :usage
  end

  test "an unknown command names itself" do
    assert {:usage_error, message} = CLI.dispatch(["nonsense"])
    assert message =~ "unknown command: nonsense"
  end

  test "removed legacy commands are not accepted" do
    for command <- [["inventory"], ["registry", "examples"], ["release", "publish"]] do
      assert {:usage_error, message} = CLI.dispatch(command)
      assert message =~ "unknown command"
    end
  end

  test "registry validate reports the document", context do
    %{catalog: catalog} = workspace!(context)

    assert {:ok, report} = CLI.dispatch(["registry", "validate", "--registry", catalog])
    assert report.schema == "portfolio_registry.registry/v2"
    assert report.repositories == 2
    assert report.projects == 2
    assert report.applications == 3
    assert report.groups == 2
    assert report.languages == ["elixir"]
    assert report.release_packages == 1
  end

  test "registry validate requires a registry" do
    assert CLI.dispatch(["registry", "validate"]) == {:usage_error, "missing --registry"}
  end

  test "registry select reports repositories and projects", context do
    %{catalog: catalog, view: view} = workspace!(context)

    assert {:ok, report} =
             CLI.dispatch(["registry", "select", "--registry", catalog, "--view", view])

    assert report.schema == "mix_workspace_ops.selection/v2"
    assert report.repositories == ["alpha"]
    assert report.projects == ["alpha"]

    # This is the one command whose whole subject is the selection, and it
    # reported neither the selection's own digest nor the three sets.
    assert is_binary(report.selection_digest)
    refute report.selection_digest == report.registry_digest
    assert report.sets.catalogued.repositories == 2
    assert report.sets.selected.repositories == 1
    assert report.sets.selected.digest == report.selection_digest
  end

  test "registry select requires both a registry and a view", context do
    %{catalog: catalog} = workspace!(context)

    assert CLI.dispatch(["registry", "select", "--registry", catalog]) ==
             {:usage_error, "missing --view"}
  end

  test "registry chain returns the whole train", context do
    %{catalog: catalog} = workspace!(context)

    assert {:ok, report} = CLI.dispatch(["registry", "chain", "--registry", catalog])
    assert report.package == nil
    assert report.order == ["plane"]
    assert report.prerequisites == %{"plane" => []}
  end

  test "registry chain accepts the package it documents", context do
    %{catalog: catalog} = workspace!(context)

    assert {:ok, report} =
             CLI.dispatch(["registry", "chain", "--registry", catalog, "--package", "plane"])

    assert report.package == "plane"
    assert report.order == ["plane"]
  end

  test "registry chain refuses a package outside the train", context do
    %{catalog: catalog} = workspace!(context)

    assert CLI.dispatch(["registry", "chain", "--registry", catalog, "--package", "alpha"]) ==
             {:error, {:unknown_release_package, "alpha"}}
  end

  test "registry workspace reports derived members", context do
    %{catalog: catalog} = workspace!(context)

    assert {:ok, report} = CLI.dispatch(["registry", "workspace", "--registry", catalog])
    assert report.schema == "mix_workspace_ops.workspace/v1"
    assert [%{repository: "plane", kind: "blitz", members: ["plane"]}] = report.workspaces
  end

  test "registry workspace accepts the repository it documents", context do
    %{catalog: catalog} = workspace!(context)

    assert {:ok, report} =
             CLI.dispatch([
               "registry",
               "workspace",
               "--registry",
               catalog,
               "--repository",
               "plane"
             ])

    assert report.repository == "plane"
    assert length(report.workspaces) == 1

    assert CLI.dispatch([
             "registry",
             "workspace",
             "--registry",
             catalog,
             "--repository",
             "absent"
           ]) ==
             {:error, {:unknown_repository, "absent"}}
  end

  test "registry discover inventories checkouts and writes its report", context do
    %{root: root} = workspace!(context)
    output = Path.join(root, "discovery.json")

    assert {:ok, report} =
             CLI.dispatch([
               "registry",
               "discover",
               "--checkout-root",
               root,
               "--github-owner",
               "example-org",
               "--output",
               output
             ])

    assert Enum.map(report.registry.repositories, & &1["id"]) == ["alpha", "plane"]
    assert report.snapshot.github_owner == "example-org"
    assert report.snapshot.repositories == 2
    assert File.regular?(output)
  end

  test "registry discover requires a checkout root and an owner", context do
    %{root: root} = workspace!(context)

    assert CLI.dispatch(["registry", "discover", "--checkout-root", root]) ==
             {:usage_error, "missing --github-owner"}
  end

  test "doctor reports a healthy workspace", context do
    %{root: root, catalog: catalog} = workspace!(context)

    assert {:ok, report} =
             CLI.dispatch(["doctor", "--registry", catalog, "--checkout-root", root])

    assert report.schema == "mix_workspace_ops.doctor/v1"
    assert report.healthy
  end

  test "doctor does not pre-warm projects whose repository is absent", context do
    %{root: root, catalog: catalog} = workspace!(context)
    File.rm_rf!(Path.join(root, "plane"))

    assert {:ok, report} =
             CLI.dispatch(["doctor", "--registry", catalog, "--checkout-root", root])

    assert %{status: "absent", projects: []} =
             Enum.find(report.repositories, &(&1.id == "plane"))
  end

  test "doctor accepts a view and a binding file", context do
    %{root: root, catalog: catalog, view: view, binding: binding} = workspace!(context)

    assert {:ok, report} =
             CLI.dispatch([
               "doctor",
               "--registry",
               catalog,
               "--checkout-root",
               root,
               "--view",
               view,
               "--binding",
               binding
             ])

    assert Enum.map(report.repositories, & &1.id) == ["alpha"]
  end

  test "plan emits a closure with no execution", context do
    %{root: root, catalog: catalog} = workspace!(context)

    assert {:ok, report} =
             CLI.dispatch([
               "plan",
               "--project",
               "alpha",
               "--registry",
               catalog,
               "--checkout-root",
               root,
               "--",
               "true"
             ])

    assert report.schema == "mix_workspace_ops.plan/v2"
    assert report.command == %{executable: "true", args: []}
    assert report.policy.unit_kind == :project
    assert report.policy.source_mode == :auto
    assert Enum.map(report.units, & &1.id) == ["alpha"]

    # A direct project gesture narrows units, not the providers resolution may use.
    assert report.sets.catalogued.repositories == 2
    assert report.sets.selected.repositories == 2
    assert report.sets.selected.digest == nil
    assert report.sets.materialized.repositories == 2
    assert report.sets.materialized.absent_repositories == []
  end

  test "view planning reports present and absent projects without local state", context do
    root = temporary_directory!(context)
    alpha = initialize_repository!(Path.join(root, "alpha"))

    catalog =
      write_catalog!(root, [
        catalog_repository("alpha", projects: [catalog_project("alpha")]),
        catalog_repository("missing", projects: [catalog_project("missing")])
      ])

    view = write_catalog_view!(root, "all", %{})
    marker = Path.join(alpha, "plan-marker")
    previous = System.get_env("HEX_API_KEY")
    System.put_env("HEX_API_KEY", "credential-sentinel")

    on_exit(fn ->
      if previous,
        do: System.put_env("HEX_API_KEY", previous),
        else: System.delete_env("HEX_API_KEY")
    end)

    assert {:ok, plan} =
             CLI.dispatch([
               "plan",
               "--registry",
               catalog,
               "--checkout-root",
               root,
               "--view",
               view,
               "--",
               "sh",
               "-c",
               "touch plan-marker"
             ])

    assert Enum.map(plan.units, &{&1.id, &1.status}) == [
             {"alpha", :planned},
             {"missing", :absent}
           ]

    refute File.exists?(marker)
    refute Enum.any?(strings(plan), &String.contains?(&1, root))
    refute "credential-sentinel" in strings(plan)
  end

  test "the three sets stay apart under a view", context do
    %{root: root, catalog: catalog, view: view, binding: binding} = workspace!(context)

    assert {:ok, report} =
             CLI.dispatch([
               "plan",
               "--project",
               "alpha",
               "--registry",
               catalog,
               "--checkout-root",
               root,
               "--view",
               view,
               "--binding",
               binding,
               "--",
               "true"
             ])

    assert report.sets.catalogued.repositories == 2
    assert report.sets.selected.repositories == 1
    assert is_binary(report.sets.selected.digest)
    assert report.sets.materialized.repositories == 1
    assert report.sets.materialized.absent == 0
    assert report.sets.catalogued.digest == report.registry.digest
    assert report.sets.selected.unselected_applications == ["plane", "plane_legacy"]
    assert report.selection_digest == report.sets.selected.digest
  end

  test "plan output is replayed without accepting semantic overrides", context do
    %{root: root, catalog: catalog, view: view, state_root: state_root} = workspace!(context)
    plan_path = Path.join(root, "portable-plan.json")

    assert {:ok, plan} =
             CLI.dispatch([
               "plan",
               "--registry",
               catalog,
               "--checkout-root",
               root,
               "--view",
               view,
               "--output",
               plan_path,
               "--",
               "true"
             ])

    assert String.trim_trailing(File.read!(plan_path)) == MixWorkspaceOps.Report.encode(plan)

    replay = [
      "run",
      "--plan",
      plan_path,
      "--registry",
      catalog,
      "--checkout-root",
      root,
      "--view",
      view,
      "--state-root",
      state_root
    ]

    assert {:ok, report} = CLI.dispatch(replay)
    assert report.plan.digest == plan.digest
    assert [%{id: "alpha", status: :passed}] = report.results

    assert CLI.dispatch(replay ++ ["--fail-fast"]) ==
             {:usage_error, "replay takes semantic policy from the plan; remove --fail-fast"}

    assert CLI.dispatch(replay ++ ["--", "false"]) ==
             {:usage_error, "--plan cannot be combined with a command"}
  end

  test "a project-scoped plan replays without inventing a view", context do
    %{root: root, catalog: catalog, state_root: state_root} = workspace!(context)
    plan_path = Path.join(root, "project-plan.json")

    assert {:ok, plan} =
             CLI.dispatch([
               "plan",
               "--registry",
               catalog,
               "--checkout-root",
               root,
               "--project",
               "alpha",
               "--output",
               plan_path,
               "--",
               "true"
             ])

    assert plan.view == nil
    assert plan.policy.project == "alpha"

    assert {:ok, report} =
             CLI.dispatch([
               "run",
               "--plan",
               plan_path,
               "--registry",
               catalog,
               "--checkout-root",
               root,
               "--state-root",
               state_root
             ])

    assert report.plan.digest == plan.digest
    assert [%{id: "alpha", status: :passed}] = report.results
  end

  test "replay refuses changed source state before launching the child", context do
    %{root: root, catalog: catalog, view: view, state_root: state_root} = workspace!(context)
    plan_path = Path.join(root, "drift-plan.json")
    marker = Path.join(root, "alpha/replay-marker")

    assert {:ok, _plan} =
             CLI.dispatch([
               "plan",
               "--registry",
               catalog,
               "--checkout-root",
               root,
               "--view",
               view,
               "--output",
               plan_path,
               "--",
               "sh",
               "-c",
               "touch replay-marker"
             ])

    File.write!(Path.join(root, "alpha/advance"), "advanced\n")
    {_, 0} = System.cmd("git", ["add", "advance"], cd: Path.join(root, "alpha"))

    {_, 0} =
      System.cmd("git", ["commit", "--quiet", "-m", "advance"], cd: Path.join(root, "alpha"))

    assert {:error, {:plan_drift, drifts}} =
             CLI.dispatch([
               "run",
               "--plan",
               plan_path,
               "--registry",
               catalog,
               "--checkout-root",
               root,
               "--view",
               view,
               "--state-root",
               state_root
             ])

    assert Enum.any?(drifts, &(&1.field == :repository_head and &1.unit == "alpha"))
    refute File.exists?(marker)
    refute File.exists?(state_root)
  end

  test "sources reports where every dependency resolves from", context do
    %{root: root, catalog: catalog} = workspace!(context)

    assert {:ok, report} =
             CLI.dispatch([
               "sources",
               "--project",
               "alpha",
               "--registry",
               catalog,
               "--checkout-root",
               root
             ])

    assert report.schema == "mix_workspace_ops.sources/v1"
    assert report.sources == []
    assert report.report == "dependency sources: (no managed dependencies)"
    assert report.sets.catalogued.repositories == 2
  end

  # The committed default and the catalog both name a source coordinate and a
  # published requirement, and nothing compared them. The rule is that the
  # committed default is the tuple publish resolution produces, and this is what
  # makes the rule mechanical instead of something to remember.
  test "seam prints the call sites publish resolution implies", context do
    %{root: root, catalog: catalog} = seam_workspace!(context)

    assert {:ok, report} =
             CLI.dispatch([
               "seam",
               "--project",
               "alpha",
               "--registry",
               catalog,
               "--checkout-root",
               root
             ])

    assert report.schema == "mix_workspace_ops.seam/v1"

    assert report.lines == [
             ~s|workspace_dep({:core, "~> 1.0", only: [:dev, :test], runtime: false})|,
             ~s|workspace_dep({:third_party, [github: "example-org/third-party", | <>
               ~s|branch: "main", subdir: "core"]})|
           ]

    assert String.split(report.report, "\n") == [
             "defp deps do",
             "  [",
             "    " <> Enum.at(report.lines, 0) <> ",",
             "    " <> Enum.at(report.lines, 1),
             "  ]",
             "end"
           ]
  end

  test "the printed seam executes as the tuples publish resolution implies", context do
    %{root: root, catalog: catalog} = seam_workspace!(context)

    assert {:ok, report} =
             CLI.dispatch([
               "seam",
               "--project",
               "alpha",
               "--registry",
               catalog,
               "--checkout-root",
               root
             ])

    module = Module.concat(__MODULE__, "GeneratedSeam#{System.unique_integer([:positive])}")

    source = """
    defmodule #{inspect(module)} do
      def workspace_dep(committed), do: committed
      #{String.replace(report.report, "defp deps", "def deps")}
    end
    """

    Code.compile_string(source)

    assert module.deps() == [
             {:core, "~> 1.0", [only: [:dev, :test], runtime: false]},
             {:third_party, [github: "example-org/third-party", branch: "main", subdir: "core"]}
           ]
  end

  test "a report projects publish resolution rather than asserting it", context do
    %{root: root, catalog: catalog} = seam_workspace!(context)

    for command <- ["sources"] do
      assert CLI.dispatch([
               command,
               "--project",
               "alpha",
               "--registry",
               catalog,
               "--checkout-root",
               root,
               "--as-publish",
               "maybe"
             ]) == {:usage_error, "--as-publish expects true or false, got maybe"}

      assert {:ok, development} =
               CLI.dispatch([
                 command,
                 "--project",
                 "alpha",
                 "--registry",
                 catalog,
                 "--checkout-root",
                 root
               ])

      assert {:ok, publishing} =
               CLI.dispatch([
                 command,
                 "--project",
                 "alpha",
                 "--registry",
                 catalog,
                 "--checkout-root",
                 root,
                 "--as-publish",
                 "true"
               ])

      refute development.publish
      assert publishing.publish
      assert Enum.map(development.sources, & &1.source) == ["local", "github"]
      assert Enum.map(publishing.sources, & &1.source) == ["hex", "github"]
    end
  end

  test "impact uses real Mix dependencies and collapses equivalent target namespaces", context do
    %{root: root, catalog: catalog, view: view} = affected_workspace!(context)

    assert {:ok, report} =
             CLI.dispatch([
               "impact",
               "core",
               "--registry",
               catalog,
               "--checkout-root",
               root,
               "--view",
               view
             ])

    assert report.schema == "mix_workspace_ops.impact/v1"
    assert report.target.id == "core"
    assert report.target.seed_projects == ["core"]
    assert report.target.matched_kinds == [:application, :project, :repository]
    assert report.direct_dependents == ["alpha"]
    assert report.transitive_dependents == []
    assert report.selected_affected_projects == ["alpha", "core"]
    assert report.coverage.complete
    assert report.safe_affected_only
  end

  test "affected plan uses only the reverse closure when coverage is complete", context do
    %{root: root, catalog: catalog, view: view} = affected_workspace!(context)

    assert {:ok, plan} =
             CLI.dispatch([
               "plan",
               "--affected",
               "core",
               "--registry",
               catalog,
               "--checkout-root",
               root,
               "--view",
               view,
               "--",
               "true"
             ])

    assert plan.schema == "mix_workspace_ops.plan/v2"
    assert plan.scope.kind == :affected
    assert plan.scope.impact_complete
    refute plan.scope.fallback_to_full_scope
    assert plan.scope.base_projects == ["alpha", "core", "missing"]
    assert plan.scope.selected_projects == ["alpha", "core"]
    assert Enum.map(plan.units, & &1.id) == ["alpha", "core"]
    assert plan.dependency_index.complete
  end

  test "affected plan widens to the full base scope when coverage is incomplete", context do
    %{root: root, catalog: catalog, view: view, missing: missing} = affected_workspace!(context)
    File.rm_rf!(missing)

    assert {:ok, plan} =
             CLI.dispatch([
               "plan",
               "--affected",
               "core",
               "--registry",
               catalog,
               "--checkout-root",
               root,
               "--view",
               view,
               "--",
               "true"
             ])

    refute plan.scope.impact_complete
    assert plan.scope.fallback_to_full_scope
    assert plan.scope.fallback_reason == :dependency_index_incomplete
    assert plan.scope.coverage.absent_projects == ["missing"]
    assert plan.scope.selected_projects == ["alpha", "core", "missing"]
    assert Enum.map(plan.units, & &1.id) == ["alpha", "core", "missing"]
    assert %{status: :absent} = Enum.find(plan.units, &(&1.id == "missing"))
  end

  test "affected scope requires a view and conflicts with an explicit project" do
    assert CLI.dispatch(["plan", "--affected", "core", "--", "true"]) ==
             {:usage_error, "--affected requires --view PATH"}

    assert CLI.dispatch([
             "plan",
             "--affected",
             "core",
             "--project",
             "alpha",
             "--view",
             "view.json",
             "--",
             "true"
           ]) == {:usage_error, "--affected cannot be combined with --project"}
  end

  test "use persists only an XDG source mode and resolution consumes it", context do
    %{root: root, catalog: catalog} = sibling_workspace!(context)
    xdg = Path.join(root, "operator-config")
    previous = System.get_env("XDG_CONFIG_HOME")
    System.put_env("XDG_CONFIG_HOME", xdg)

    on_exit(fn ->
      if previous,
        do: System.put_env("XDG_CONFIG_HOME", previous),
        else: System.delete_env("XDG_CONFIG_HOME")
    end)

    assert {:ok, use_report} =
             CLI.dispatch([
               "use",
               "core",
               "git",
               "--project",
               "alpha",
               "--registry",
               catalog,
               "--checkout-root",
               root
             ])

    expected_preferences = Path.join([xdg, "mix_workspace_ops", "source_preferences.json"])
    assert use_report.path == expected_preferences

    decoded = expected_preferences |> File.read!() |> :json.decode()
    assert decoded == %{
             "schema" => "mix_workspace_ops.source_preferences/v1",
             "projects" => %{"alpha" => %{"core" => "git"}}
           }

    assert {:ok, sources} =
             CLI.dispatch([
               "sources",
               "--project",
               "alpha",
               "--registry",
               catalog,
               "--checkout-root",
               root
             ])

    assert [%{application: "core", source: "github", reason: :source_preference}] =
             sources.sources

    {status, 0} = System.cmd("git", ["status", "--porcelain"], cd: Path.join(root, "alpha"))
    assert status == ""

    assert {:ok, _clear_report} =
             CLI.dispatch([
               "use",
               "--clear",
               "core",
               "--project",
               "alpha",
               "--registry",
               catalog,
               "--checkout-root",
               root
             ])

    assert {:ok, sources} =
             CLI.dispatch([
               "sources",
               "--project",
               "alpha",
               "--registry",
               catalog,
               "--checkout-root",
               root
             ])

    assert [%{application: "core", source: "local"}] = sources.sources
  end

  test "use stores only XDG source preferences and leaves the consumer checkout unchanged", context do
    %{root: root, catalog: catalog} = sibling_workspace!(context)
    xdg = Path.join(root, "xdg-config")
    previous = System.get_env("XDG_CONFIG_HOME")
    System.put_env("XDG_CONFIG_HOME", xdg)

    on_exit(fn ->
      if previous, do: System.put_env("XDG_CONFIG_HOME", previous), else: System.delete_env("XDG_CONFIG_HOME")
    end)

    {before_status, 0} = System.cmd("git", ["status", "--porcelain"], cd: Path.join(root, "alpha"))

    assert {:ok, report} =
             CLI.dispatch([
               "use",
               "core",
               "local",
               "--project",
               "alpha",
               "--registry",
               catalog,
               "--checkout-root",
               root
             ])

    assert report.path == SourcePreferences.default_path()
    assert {:ok, preferences} = SourcePreferences.load(report.path)
    assert SourcePreferences.get(preferences, "alpha", "core") == "local"

    {after_status, 0} = System.cmd("git", ["status", "--porcelain"], cd: Path.join(root, "alpha"))
    assert after_status == before_status
  end

  test "use rejects undeclared or ineligible source preferences", context do
    %{root: root, catalog: catalog} = seam_workspace!(context)
    xdg = Path.join(root, "xdg-config")
    previous = System.get_env("XDG_CONFIG_HOME")
    System.put_env("XDG_CONFIG_HOME", xdg)

    on_exit(fn ->
      if previous, do: System.put_env("XDG_CONFIG_HOME", previous), else: System.delete_env("XDG_CONFIG_HOME")
    end)

    assert {:error, {:undeclared_source_preference, "alpha", "unknown_app"}} =
             CLI.dispatch([
               "use",
               "unknown_app",
               "hex",
               "--project",
               "alpha",
               "--registry",
               catalog,
               "--checkout-root",
               root
             ])

    assert {:error, {:ineligible_source_preference, "alpha", "third_party", "hex"}} =
             CLI.dispatch([
               "use",
               "third_party",
               "hex",
               "--project",
               "alpha",
               "--registry",
               catalog,
               "--checkout-root",
               root
             ])
  end

  test "plan refuses a project the view excludes", context do
    %{root: root, catalog: catalog, view: view} = workspace!(context)

    assert CLI.dispatch([
             "plan",
             "--project",
             "plane",
             "--registry",
             catalog,
             "--checkout-root",
             root,
             "--view",
             view,
             "--",
             "true"
           ]) == {:error, {:project_outside_view, "plane", view}}
  end

  test "plan requires a view or project scope" do
    assert CLI.dispatch(["plan", "--", "true"]) ==
             {:usage_error, "plan and run require --view PATH or --project ID"}
  end

  # The acceptance item names a gesture, not a rule: remove the sibling and it
  # resolves GitHub. It was true of `Resolution.decide/4` and false of every
  # command, because deriving the closure evaluated the absent checkout's own
  # `mix.exs`.
  test "removing a sibling checkout makes every command resolve GitHub", context do
    %{root: root, catalog: catalog, core: core} = sibling_workspace!(context)

    for command <- ["sources"] do
      assert {:ok, report} =
               CLI.dispatch([
                 command,
                 "--project",
                 "alpha",
                 "--registry",
                 catalog,
                 "--checkout-root",
                 root
               ])

      assert [%{application: "core", source: "local"}] = report.sources
    end

    assert {:ok, local_plan} =
             CLI.dispatch([
               "plan",
               "--project",
               "alpha",
               "--registry",
               catalog,
               "--checkout-root",
               root,
               "--",
               "true"
             ])

    assert [%{sources: [%{application: "core", source: "local"}]}] = local_plan.units

    File.rm_rf!(core)

    for command <- ["sources"] do
      assert {:ok, report} =
               CLI.dispatch([
                 command,
                 "--project",
                 "alpha",
                 "--registry",
                 catalog,
                 "--checkout-root",
                 root
               ])

      assert [%{application: "core", source: "github", location: "example-org/core"}] =
               report.sources
    end

    assert {:ok, github_plan} =
             CLI.dispatch([
               "plan",
               "--project",
               "alpha",
               "--registry",
               catalog,
               "--checkout-root",
               root,
               "--",
               "true"
             ])

    assert [%{sources: [%{application: "core", source: "github"} = source]}] =
             github_plan.units

    assert source.coordinates.repo == "example-org/core"
  end

  test "an absent target checkout is a non-fatal plan unit", context do
    %{root: root, catalog: catalog, core: core} = sibling_workspace!(context)
    File.rm_rf!(core)

    assert {:ok, plan} =
             CLI.dispatch([
               "plan",
               "--project",
               "core",
               "--registry",
               catalog,
               "--checkout-root",
               root,
               "--",
               "true"
             ])

    assert [%{id: "core", status: :absent}] = plan.units
  end

  test "run executes the command in the project root", context do
    %{root: root, catalog: catalog, state_root: state_root} = workspace!(context)

    assert {:ok, report} =
             CLI.dispatch([
               "run",
               "--project",
               "alpha",
               "--registry",
               catalog,
               "--checkout-root",
               root,
               "--mode",
               "hex",
               "--state-root",
               state_root,
               "--",
               "pwd"
             ])

    assert [%{status: :passed, exit_code: 0, output_tail: output}] = report.results
    assert output == [Path.join(root, "alpha")]
    assert report.plan.policy.source_mode == :hex
  end

  test "run resolves through the catalog's own order unless a mode is named", context do
    %{root: root, catalog: catalog, state_root: state_root} = workspace!(context)

    assert {:ok, report} =
             CLI.dispatch([
               "run",
               "--project",
               "alpha",
               "--registry",
               catalog,
               "--checkout-root",
               root,
               "--state-root",
               state_root,
               "--",
               "pwd"
             ])

    assert report.plan.policy.source_mode == :auto
    assert report.status == :passed
  end

  test "ordinary run reaches an unnamed publish-shaped child without credentials", context do
    %{root: root, catalog: catalog, state_root: state_root} = workspace!(context)

    fixture = """
    if System.get_env("HEX_API_KEY") do
      IO.puts("unexpected publication capability")
      System.halt(0)
    else
      IO.puts(:stderr, "publication credentials unavailable")
      System.halt(77)
    end
    """

    assert {:error, {:fanout_failed, report}} =
             CLI.dispatch([
               "run",
               "--project",
               "alpha",
               "--registry",
               catalog,
               "--checkout-root",
               root,
               "--state-root",
               state_root,
               "--",
               "elixir",
               "-e",
               fixture
             ])

    assert [result] = report.results
    assert result.exit_code == 77
    assert "publication credentials unavailable" in result.output_tail
    refute "unexpected publication capability" in result.output_tail
  end

  test "state list and gc expose the same completed run", context do
    %{root: root, catalog: catalog, state_root: state_root} = workspace!(context)

    assert {:ok, _report} =
             CLI.dispatch([
               "run",
               "--project",
               "alpha",
               "--registry",
               catalog,
               "--checkout-root",
               root,
               "--state-root",
               state_root,
               "--",
               "true"
             ])

    assert {:ok, %{runs: [run]}} =
             CLI.dispatch(["state", "list", "--state-root", state_root])

    refute run.leased
    assert run.status == "complete"

    assert {:ok, dry} =
             CLI.dispatch([
               "state",
               "gc",
               "--older-than",
               "0s",
               "--dry-run",
               "--state-root",
               state_root
             ])

    assert {:ok, removed} =
             CLI.dispatch([
               "state",
               "gc",
               "--older-than",
               "0s",
               "--state-root",
               state_root
             ])

    assert Enum.map(dry.runs, & &1.run_id) == [run.run_id]
    assert Enum.map(removed.runs, & &1.run_id) == [run.run_id]
    assert {:ok, %{runs: []}} = CLI.dispatch(["state", "list", "--state-root", state_root])
  end

  test "state commands reject positional arguments" do
    assert CLI.dispatch(["state", "list", "extra"]) ==
             {:usage_error, ~s|state list expects no arguments, got ["extra"]|}

    assert CLI.dispatch(["state", "gc", "--older-than", "1h", "extra"]) ==
             {:usage_error, ~s|state gc expects no arguments, got ["extra"]|}
  end

  test "run requires an explicit flag before a child may mutate its copied lock", context do
    %{root: root, catalog: catalog, state_root: state_root} = workspace!(context)
    project_lock = Path.join(root, "alpha/mix.lock")
    File.write!(project_lock, "%{}\n")

    command = [
      "--",
      "elixir",
      "-e",
      ~s|File.write!(System.fetch_env!("MIX_WORKSPACE_OPS_LOCKFILE"), "changed\\n")|
    ]

    options = [
      "run",
      "--project",
      "alpha",
      "--registry",
      catalog,
      "--checkout-root",
      root,
      "--dirty-policy",
      "allow-recorded",
      "--state-root",
      state_root
    ]

    assert {:error, {:fanout_failed, rejected}} = CLI.dispatch(options ++ command)
    assert [%{status: :failed, finalize_error: error}] = rejected.results
    assert error =~ "lock_mutation_not_allowed"

    assert {:ok, report} =
             CLI.dispatch(options ++ ["--allow-lock-mutation"] ++ command)

    assert [binding] = report.binding.units
    assert binding.runtime.lock_mutated
    assert binding.runtime.allow_lock_mutation
    assert File.read!(project_lock) == "%{}\n"
  end

  test "run refuses a source override that does not name an application", context do
    %{root: root, catalog: catalog} = workspace!(context)

    base = [
      "run",
      "--project",
      "alpha",
      "--registry",
      catalog,
      "--checkout-root",
      root
    ]

    assert CLI.dispatch(base ++ ["--source", "plane", "--", "pwd"]) ==
             {:usage_error, "--source expects APP=SOURCE, got \"plane\""}

    assert CLI.dispatch(base ++ ["--source", "plane=svn", "--", "pwd"]) ==
             {:usage_error, "invalid source \"svn\""}
  end

  test "run refuses an unknown mode, unit kind, and dirty policy", context do
    %{root: root, catalog: catalog} = workspace!(context)

    base = [
      "run",
      "--project",
      "alpha",
      "--registry",
      catalog,
      "--checkout-root",
      root
    ]

    assert CLI.dispatch(base ++ ["--mode", "nonsense", "--", "pwd"]) ==
             {:usage_error, "invalid source mode \"nonsense\""}

    assert CLI.dispatch(base ++ ["--unit", "nonsense", "--", "pwd"]) ==
             {:usage_error, "invalid unit kind \"nonsense\""}

    assert CLI.dispatch(base ++ ["--dirty-policy", "nonsense", "--", "pwd"]) ==
             {:usage_error, "invalid dirty policy \"nonsense\""}

    assert CLI.dispatch(base ++ ["--beam-schedulers", "0", "--", "pwd"]) ==
             {:usage_error, "--beam-schedulers expects a positive integer"}
  end

  test "run requires a command after the separator" do
    assert CLI.dispatch(["run", "--project", "alpha"]) ==
             {:usage_error, "run requires -- followed by a command, or --plan PATH"}

    assert CLI.dispatch(["run", "--project", "alpha", "--"]) == {:usage_error, "empty command"}
  end

  # The guard read argv position 2 while the parser beside it read task position,
  # so the two disagreed about what "the publish task" is. Every shape the parser
  # calls a publication is refused here, and every shape it does not is allowed.
  test "run refuses a publishing task in every shape that names one", context do
    %{root: root, catalog: catalog} = workspace!(context)

    refused = [
      {["mix", "hex.publish"], "hex.publish"},
      {["mix", "do", "compile,", "hex.publish"], "hex.publish"},
      {["mix", "do", "compile", "+", "hex.publish"], "hex.publish"},
      {["elixir", "-S", "mix", "hex.publish"], "hex.publish"},
      {["/usr/bin/env", "mix", "hex.publish"], "hex.publish"},
      {["env", "MIX_ENV=prod", "mix", "hex.publish"], "hex.publish"},
      {["mix", "deps.publish_preflight"], "deps.publish_preflight"}
    ]

    for {command, task} <- refused do
      assert run(root, catalog, command) ==
               {:usage_error, "#{task} publishes; run it through the release transaction"},
             "#{Enum.join(command, " ")} was not refused"
    end

    # Reading the registry is not publishing, and a task name in an argument is
    # not a task.
    for command <- [
          ["mix", "hex.info"],
          ["mix", "run", "--arg", "hex.publish"],
          ["mix", "run", "--arg", "value,hex.publish"],
          ["mix", "run", "--arg", "value", "+", "hex.publish"],
          ["mix", "do", "compile,hex.publish"]
        ] do
      refute match?({:usage_error, _reason}, run(root, catalog, command)),
             "#{Enum.join(command, " ")} was refused"
    end
  end

  defp run(root, catalog, command) do
    CLI.dispatch(
      ["run", "--project", "alpha", "--registry", catalog, "--checkout-root", root, "--"] ++
        command
    )
  end

  test "release plan exposes the catalog-derived semantic plan", context do
    %{catalog: catalog} = workspace!(context)

    assert {:ok, plan} =
             CLI.dispatch([
               "release",
               "plan",
               "--registry",
               catalog,
               "--package",
               "plane"
             ])

    assert plan.schema == "mix_workspace_ops.release_plan/v1"
    assert plan.package == "plane"
    assert plan.order == ["plane"]
    assert [%{package: "plane", project: %{id: "plane"}}] = plan.units
  end

  test "release plan requires its registry and package" do
    assert CLI.dispatch(["release", "plan"]) == {:usage_error, "missing --registry"}

    assert CLI.dispatch(["release", "plan", "--registry", "missing.json"]) ==
             {:usage_error, "missing --package"}
  end

  test "release chain requires catalog, package and descriptor" do
    assert CLI.dispatch(["release", "chain"]) == {:usage_error, "missing --registry"}

    assert CLI.dispatch(["release", "chain", "--registry", "registry.json"]) ==
             {:usage_error, "missing --package"}

    assert CLI.dispatch([
             "release",
             "chain",
             "--registry",
             "registry.json",
             "--checkout-root",
             ".",
             "--package",
             "sample_package"
           ]) == {:usage_error, "missing --descriptor"}
  end

  # -- fixtures ------------------------------------------------------------

  defp workspace!(context) do
    root = temporary_directory!(context)

    for name <- ~w(alpha plane) do
      checkout = initialize_repository!(Path.join(root, name))
      File.mkdir_p!(Path.join(checkout, "build_support"))
      File.write!(Path.join(checkout, "build_support/dependency_sources.exs"), "helper\n")
      System.cmd("git", ["add", "build_support"], cd: checkout)
      System.cmd("git", ["commit", "--quiet", "-m", "helper"], cd: checkout)
    end

    catalog =
      write_catalog!(root, [
        catalog_repository("alpha",
          groups: ["family.alpha"],
          projects: [catalog_project("alpha")]
        ),
        catalog_repository("plane",
          groups: ["family.plane"],
          workspace: %{"kind" => "blitz", "include_project_ids" => ["plane"]},
          release_chain: %{"plane" => []},
          projects: [catalog_project("plane", provides: ["plane", "plane_legacy"])]
        )
      ])

    view = write_catalog_view!(root, "consumer", %{"repository_ids" => ["alpha"]})
    binding = Path.join(root, "binding.json")
    File.write!(binding, :json.encode(%{"alpha" => Path.join(root, "alpha")}))

    %{
      root: root,
      catalog: catalog,
      view: view,
      binding: binding,
      state_root: Path.join(root, "state")
    }
  end

  defp seam_workspace!(context) do
    root = temporary_directory!(context)
    initialize_repository!(Path.join(root, "core"))

    initialize_repository!(
      Path.join(root, "alpha"),
      ~s([{:core, path: "../core"}, {:third_party, "~> 1.0"}])
    )

    catalog =
      write_catalog!(
        root,
        [
          catalog_repository("core", projects: [catalog_project("core")]),
          catalog_repository("alpha",
            projects: [catalog_project("alpha")],
            dependency_sources: %{
              "core" => %{
                "hex" => "~> 1.0",
                "opts" => %{"only" => ["dev", "test"], "runtime" => false, "override" => true}
              },
              "third_party" => %{
                "github" => %{
                  "repo" => "example-org/third-party",
                  "branch" => "main",
                  "subdir" => "core"
                },
                "order" => ["github"],
                "publish_order" => ["github"]
              }
            }
          )
        ],
        name: "seam_registry.json"
      )

    %{root: root, catalog: catalog}
  end

  defp affected_workspace!(context) do
    root = temporary_directory!(context)
    initialize_repository!(Path.join(root, "core"))
    initialize_repository!(Path.join(root, "alpha"), ~s([{:core, path: "../core"}]))
    missing = initialize_repository!(Path.join(root, "missing"))

    catalog =
      write_catalog!(
        root,
        [
          catalog_repository("core", projects: [catalog_project("core")]),
          catalog_repository("alpha",
            projects: [catalog_project("alpha")],
            dependency_sources: %{
              "core" => %{
                "github" => %{"repo" => "example-org/core", "branch" => "main"},
                "hex" => "~> 1.0"
              }
            }
          ),
          catalog_repository("missing", projects: [catalog_project("missing")])
        ],
        name: "affected_registry.json"
      )

    view = write_catalog_view!(root, "affected_all", %{})
    %{root: root, catalog: catalog, view: view, missing: missing}
  end

  defp sibling_workspace!(context) do
    root = temporary_directory!(context)
    core = initialize_repository!(Path.join(root, "core"))
    initialize_repository!(Path.join(root, "alpha"), ~s([{:core, path: "../core"}]))

    catalog =
      write_catalog!(
        root,
        [
          catalog_repository("core", projects: [catalog_project("core")]),
          catalog_repository("alpha",
            projects: [catalog_project("alpha")],
            dependency_sources: %{
              "core" => %{
                "github" => %{"repo" => "example-org/core", "branch" => "main"},
                "hex" => "~> 1.0"
              }
            }
          )
        ],
        name: "sibling_registry.json"
      )

    %{root: root, catalog: catalog, core: core}
  end

  defp documented_options do
    CLI.usage_text()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> join_continuations()
    |> Enum.flat_map(&command_options/1)
  end

  defp join_continuations(lines) do
    lines
    |> Enum.reduce([], &join_continuation/2)
    |> Enum.reverse()
  end

  defp join_continuation(line, []), do: [line]

  defp join_continuation(line, [previous | rest] = acc) do
    if String.ends_with?(previous, "\\"),
      do: [String.trim_trailing(previous, "\\") <> " " <> line | rest],
      else: [line | acc]
  end

  defp command_options(line) do
    tokens = String.split(line, ~r/\s+/, trim: true)
    command = Enum.take_while(tokens, &Regex.match?(~r/^[a-z][a-z_]*$/, &1))
    options = Regex.scan(~r/--([a-z][a-z-]*)/, line) |> Enum.map(&Enum.at(&1, 1)) |> Enum.uniq()

    if command == [] or options == [], do: [], else: Enum.map(options, &{command, &1})
  end

  defp command_terminator(["run"]), do: ["--", "true"]
  defp command_terminator(["plan"]), do: ["--", "true"]
  defp command_terminator(_command), do: []

  defp strings(value) when is_binary(value), do: [value]
  defp strings(value) when is_list(value), do: Enum.flat_map(value, &strings/1)
  defp strings(value) when is_map(value), do: value |> Map.values() |> Enum.flat_map(&strings/1)
  defp strings(_value), do: []
end