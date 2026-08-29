defmodule MixWorkspaceOps.CLITest do
  use MixWorkspaceOps.WorkspaceCase, async: true

  import ExUnit.CaptureIO

  alias MixWorkspaceOps.{CLI, Command}

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
             ["inventory"],
             ["plan"],
             ["registry", "chain"],
             ["registry", "discover"],
             ["registry", "examples"],
             ["registry", "select"],
             ["registry", "validate"],
             ["registry", "workspace"],
             ["release", "publish"],
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

  test "inventory reports every bound repository and writes its report", context do
    %{root: root, catalog: catalog} = workspace!(context)
    output = Path.join(root, "inventory.json")

    assert {:ok, report} =
             CLI.dispatch([
               "inventory",
               "--registry",
               catalog,
               "--checkout-root",
               root,
               "--output",
               output
             ])

    assert report.helper_files == 2
    assert report.unique_git_repositories == 2
    assert Enum.map(report.rows, & &1.application) == ["alpha", "plane"]
    assert File.regular?(output)
  end

  test "inventory accepts a view and a binding file", context do
    %{root: root, catalog: catalog, view: view, binding: binding} = workspace!(context)

    assert {:ok, report} =
             CLI.dispatch([
               "inventory",
               "--registry",
               catalog,
               "--checkout-root",
               root,
               "--view",
               view,
               "--binding",
               binding
             ])

    assert report.helper_files == 1
    assert Enum.map(report.rows, & &1.application) == ["alpha"]
  end

  test "inventory requires a registry and a checkout root", context do
    %{root: root} = workspace!(context)

    assert CLI.dispatch(["inventory", "--checkout-root", root]) ==
             {:usage_error, "missing --registry"}
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
               root
             ])

    assert report.schema == "mix_workspace_ops.plan/v2"
    assert report.target == "alpha"
    assert report.projects == ["alpha"]
    assert report.known_unselected == []
    assert report.mode == "auto"
    refute report.publish

    # The three sets, named apart. With no view the catalog and the selection
    # agree, and what is materialized is a fact about this disk.
    assert report.sets.catalogued.repositories == 2
    assert report.sets.selected.repositories == 2
    assert report.sets.selected.digest == nil
    assert report.sets.materialized.repositories == 2
    assert report.sets.materialized.absent_repositories == []
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
               binding
             ])

    assert report.sets.catalogued.repositories == 2
    assert report.sets.selected.repositories == 1
    assert is_binary(report.sets.selected.digest)
    assert report.sets.materialized.repositories == 1
    assert report.sets.materialized.absent == 0
    assert report.sets.catalogued.digest == report.registry_digest
    assert report.sets.selected.unselected_applications == ["plane", "plane_legacy"]
    assert report.selection_digest == report.sets.selected.digest
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
             ~s|workspace_dep(:core, "~> 1.0", only: [:dev, :test], runtime: false)|,
             ~s|workspace_dep(:third_party, [github: "example-org/third-party", | <>
               ~s|branch: "main", subdir: "core"])|
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
      def workspace_dep(app, default), do: {app, default}
      def workspace_dep(app, default, opts) when is_binary(default), do: {app, default, opts}
      def workspace_dep(app, default, opts), do: {app, Keyword.merge(default, opts)}
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

    for command <- ["sources", "plan"] do
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
             view
           ]) == {:error, {:project_outside_view, "plane", view}}
  end

  test "plan requires a project" do
    assert CLI.dispatch(["plan"]) == {:usage_error, "missing --project"}
  end

  # The acceptance item names a gesture, not a rule: remove the sibling and it
  # resolves GitHub. It was true of `Resolution.decide/4` and false of every
  # command, because deriving the closure evaluated the absent checkout's own
  # `mix.exs`.
  test "removing a sibling checkout makes every command resolve GitHub", context do
    %{root: root, catalog: catalog, core: core} = sibling_workspace!(context)

    for command <- ["sources", "plan"] do
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

    File.rm_rf!(core)

    for command <- ["sources", "plan"] do
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
  end

  test "an absent target checkout is a typed error naming its path", context do
    %{root: root, catalog: catalog, core: core} = sibling_workspace!(context)
    File.rm_rf!(core)

    assert CLI.dispatch([
             "plan",
             "--project",
             "core",
             "--registry",
             catalog,
             "--checkout-root",
             root
           ]) ==
             {:error, {:absent_required_checkout, "core", core}}
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
               "--mix-state",
               "delegated",
               "--state-root",
               state_root,
               "--",
               "pwd"
             ])

    assert report.command.exit_code == 0
    assert String.trim(report.command.output) == Path.join(root, "alpha")
    assert report.source.mode == :hex
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
               "--mix-state",
               "delegated",
               "--state-root",
               state_root,
               "--",
               "pwd"
             ])

    assert report.source.mode == :auto
    refute report.source.publish
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

    assert {:error, {:command_failed, result}} =
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
               System.find_executable("elixir"),
               "-e",
               fixture
             ])

    assert result.exit_code == 77
    assert result.output =~ "publication credentials unavailable"
    refute result.output =~ "unexpected publication capability"
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
      System.find_executable("elixir"),
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
      "--state-root",
      state_root
    ]

    assert {:error, {:lock_mutation_not_allowed, _run_id, initial, final}} =
             CLI.dispatch(options ++ command)

    refute initial == final

    assert {:ok, report} =
             CLI.dispatch(options ++ ["--allow-lock-mutation"] ++ command)

    assert report.source.runtime.lock_mutated
    assert report.source.runtime.allow_lock_mutation
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

  test "run refuses an unknown mode and an unknown Mix-state owner", context do
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

    assert CLI.dispatch(base ++ ["--mix-state", "nonsense", "--", "pwd"]) ==
             {:usage_error, "invalid Mix-state ownership \"nonsense\""}
  end

  test "run requires a command after the separator" do
    assert CLI.dispatch(["run", "--project", "alpha"]) ==
             {:usage_error, "run requires -- followed by a command"}

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

  test "release publish requires a descriptor" do
    assert CLI.dispatch(["release", "publish"]) == {:usage_error, "missing --descriptor"}
  end

  test "release publish reports an unreadable descriptor", context do
    %{root: root, state_root: state_root} = workspace!(context)

    assert {:error, _reason} =
             CLI.dispatch([
               "release",
               "publish",
               "--descriptor",
               Path.join(root, "absent.json"),
               "--state-root",
               state_root
             ])
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
  defp command_terminator(_command), do: []
end
