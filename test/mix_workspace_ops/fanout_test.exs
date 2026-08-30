defmodule MixWorkspaceOps.FanoutTest do
  use MixWorkspaceOps.WorkspaceCase, async: false

  alias MixWorkspaceOps.{Fanout, OperationPlan, Registry, Runtime, View}

  test "project units overlap through Blitz and results retain plan order", context do
    fixture = project_fixture(context)

    script = """
    touch started
    for attempt in $(seq 1 100); do
      if [ -f ../alpha/started ] && [ -f ../beta/started ]; then exit 0; fi
      sleep 0.05
    done
    exit 42
    """

    assert {:ok, plan} =
             OperationPlan.build(fixture.registry, fixture.view, ["sh", "-c", script])

    assert {:ok, report} =
             Fanout.run(plan, fixture.registry,
               state_root: fixture.state_root,
               max_concurrency: 2,
               timeout: 10_000
             )

    assert report.status == :passed

    assert Enum.map(report.results, &{&1.id, &1.status}) == [
             {"alpha", :passed},
             {"beta", :passed}
           ]

    assert Enum.map(report.binding.units, & &1.id) == ["alpha", "beta"]
    assert {:ok, state} = Runtime.list(fixture.state_root)
    assert length(state.runs) == 2
    refute Enum.any?(state.runs, & &1.leased)
  end

  test "continue starts unaffected units and fail-fast leaves them not run", context do
    continuing = project_fixture(context)

    command = [
      "sh",
      "-c",
      "if [ \"$(basename \"$PWD\")\" = alpha ]; then exit 7; else touch continued; fi"
    ]

    assert {:ok, continue_plan} =
             OperationPlan.build(continuing.registry, continuing.view, command)

    assert {:error, {:fanout_failed, continued}} =
             Fanout.run(continue_plan, continuing.registry,
               state_root: continuing.state_root,
               max_concurrency: 2
             )

    assert Enum.map(continued.results, &{&1.id, &1.status}) == [
             {"alpha", :failed},
             {"beta", :passed}
           ]

    assert File.exists?(Path.join(continuing.beta, "continued"))

    fail_fast = project_fixture(%{context | test: "#{context.test}_fail_fast"})

    assert {:ok, fail_fast_plan} =
             OperationPlan.build(fail_fast.registry, fail_fast.view, command,
               failure_policy: :fail_fast
             )

    assert {:error, {:fanout_failed, stopped}} =
             Fanout.run(fail_fast_plan, fail_fast.registry,
               state_root: fail_fast.state_root,
               max_concurrency: 2
             )

    assert Enum.map(stopped.results, &{&1.id, &1.status}) == [
             {"alpha", :failed},
             {"beta", :not_run}
           ]

    refute File.exists?(Path.join(fail_fast.beta, "continued"))
    assert {:ok, state} = Runtime.list(fail_fast.state_root)
    refute Enum.any?(state.runs, & &1.leased)
  end

  test "repository units include no-Mix and absent repositories", context do
    root = temporary_directory!(context)
    plain = initialize_repository!(Path.join(root, "plain"))
    File.rm!(Path.join(plain, "mix.exs"))
    File.write!(Path.join(plain, "README.md"), "plain repository\n")
    git!(plain, ["add", "-A"])
    git!(plain, ["commit", "--quiet", "-m", "remove Mix project"])

    catalog =
      write_catalog!(root, [
        catalog_repository("plain", languages: ["shell"]),
        catalog_repository("missing", languages: ["shell"])
      ])

    view_path = write_catalog_view!(root, "all_repositories", %{})
    catalog_registry = Registry.load!(catalog)
    {:ok, view} = View.load(view_path)
    registry = select_and_bind(catalog_registry, view, root)

    assert Enum.map(Registry.selected_repositories(registry), & &1.id) == ["missing", "plain"]
    assert Registry.selected_projects(registry) == []

    assert {:ok, plan} =
             OperationPlan.build(registry, view, ["sh", "-c", "touch repository-ran"],
               unit_kind: :repository
             )

    assert Enum.map(plan.units, &{&1.id, &1.status}) == [
             {"missing", :absent},
             {"plain", :planned}
           ]

    refute File.exists?(Path.join(plain, "repository-ran"))

    assert {:ok, report} =
             Fanout.run(plan, registry, state_root: Path.join(root, "state"))

    assert Enum.map(report.results, &{&1.id, &1.status}) == [
             {"missing", :absent},
             {"plain", :passed}
           ]

    assert File.exists?(Path.join(plain, "repository-ran"))

    absent_view_path =
      write_catalog_view!(root, "absent_only", %{"repository_ids" => ["missing"]})

    {:ok, absent_view} = View.load(absent_view_path)
    absent_registry = select_and_bind(catalog_registry, absent_view, root)

    assert {:ok, absent_plan} =
             OperationPlan.build(absent_registry, absent_view, ["true"], unit_kind: :repository)

    assert {:ok, absent_report} =
             Fanout.run(absent_plan, absent_registry, state_root: Path.join(root, "absent-state"))

    assert absent_report.status == :passed
    assert absent_report.binding.units == []
    assert absent_report.results == [%{id: "missing", status: :absent}]
  end

  test "binding records local paths and removals but no credential values", context do
    fixture = project_fixture(context)
    previous = System.get_env("HEX_API_KEY")
    System.put_env("HEX_API_KEY", "credential-sentinel")

    on_exit(fn ->
      if previous,
        do: System.put_env("HEX_API_KEY", previous),
        else: System.delete_env("HEX_API_KEY")
    end)

    assert {:ok, plan} = OperationPlan.build(fixture.registry, fixture.view, ["true"])

    assert {:ok, report} =
             Fanout.run(plan, fixture.registry, state_root: fixture.state_root)

    strings = strings(report.binding)
    assert Enum.any?(strings, &String.starts_with?(&1, fixture.root))
    refute "credential-sentinel" in strings

    for unit <- report.binding.units do
      credential = Enum.find(unit.command.env, &(&1.name == "HEX_API_KEY"))
      assert credential.value == nil
      assert unit.runtime.status == "complete"
    end
  end

  test "a partial binding failure finalizes every lease already allocated", context do
    fixture = project_fixture(context)
    File.mkdir_p!(Path.join(fixture.beta, "mix.lock"))

    assert {:ok, plan} =
             OperationPlan.build(fixture.registry, fixture.view, ["true"],
               dirty_policy: :allow_recorded
             )

    assert {:error, {:fanout_failed, report}} =
             Fanout.run(plan, fixture.registry, state_root: fixture.state_root)

    assert report.status == :failed
    assert report.failure.kind == :binding
    assert {:ok, state} = Runtime.list(fixture.state_root)
    assert length(state.runs) == 1
    refute Enum.any?(state.runs, & &1.leased)
  end

  defp project_fixture(context) do
    root = temporary_directory!(context)
    alpha = initialize_repository!(Path.join(root, "alpha"))
    beta = initialize_repository!(Path.join(root, "beta"))

    catalog =
      write_catalog!(root, [
        catalog_repository("alpha", projects: [catalog_project("alpha")]),
        catalog_repository("beta", projects: [catalog_project("beta")])
      ])

    view_path = write_catalog_view!(root, "all", %{})
    registry = Registry.load!(catalog)
    {:ok, view} = View.load(view_path)

    %{
      root: root,
      alpha: alpha,
      beta: beta,
      view: view,
      registry: select_and_bind(registry, view, root),
      state_root: Path.join(root, "state")
    }
  end

  defp select_and_bind(registry, view, root) do
    {:ok, repositories} = View.select_repositories(registry, view)
    {:ok, projects} = View.select(registry, view)
    selected = Registry.select(registry, projects, repositories)
    {:ok, bound} = Registry.bind(selected, root)
    bound
  end

  defp strings(value) when is_binary(value), do: [value]
  defp strings(value) when is_list(value), do: Enum.flat_map(value, &strings/1)
  defp strings(value) when is_map(value), do: value |> Map.values() |> Enum.flat_map(&strings/1)
  defp strings(_value), do: []

  defp git!(root, args) do
    {output, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    output
  end
end
