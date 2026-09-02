defmodule MixWorkspaceOps.FanoutTest do
  use MixWorkspaceOps.WorkspaceCase, async: false

  alias MixWorkspaceOps.{Fanout, OperationPlan, Registry, Runtime, View}

  test "portable Mix commands bind to the active toolchain outside the private home", context do
    fixture = project_fixture(context)
    assert {:ok, plan} = OperationPlan.build(fixture.registry, fixture.view, ["mix", "--version"])

    assert {:ok, report} =
             Fanout.run(plan, fixture.registry,
               state_root: fixture.state_root,
               max_concurrency: 2,
               timeout: 10_000
             )

    assert Enum.all?(report.results, &(&1.status == :passed))
    assert Enum.all?(report.results, &Enum.any?(&1.output_tail, fn line -> line =~ "Mix " end))

    for unit <- report.binding.units do
      assert Path.type(unit.command.executable) == :absolute
      refute Path.basename(Path.dirname(unit.command.executable)) == "shims"
    end
  end

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
    assert report.binding.max_concurrency == 2
    assert report.binding.binding_concurrency == 2
    assert report.binding.cache_concurrency == 1
    assert report.binding.beam_schedulers == max(div(System.schedulers_online(), 2), 1)
    assert report.binding.scheduler_budget == System.schedulers_online()

    assert Enum.map(report.results, &{&1.id, &1.status}) == [
             {"alpha", :passed},
             {"beta", :passed}
           ]

    assert Enum.map(report.binding.units, & &1.id) == ["alpha", "beta"]

    for unit <- report.binding.units do
      erl_aflags = Enum.find_value(unit.command.env, &if(&1.name == "ERL_AFLAGS", do: &1.value))

      assert erl_aflags =~
               "+S #{report.binding.beam_schedulers}:#{report.binding.beam_schedulers}"
    end

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

  test "repository commands reuse one unchanged exact runtime context", context do
    fixture = project_fixture(context)

    assert {:ok, first_plan} =
             OperationPlan.build(
               fixture.registry,
               fixture.view,
               ["sh", "-c", ~s|touch "$MIX_BUILD_PATH/reuse-proof"|],
               unit_kind: :repository
             )

    assert {:ok, first} =
             Fanout.run(first_plan, fixture.registry, state_root: fixture.state_root)

    assert {:ok, second_plan} =
             OperationPlan.build(fixture.registry, fixture.view, ["sh", "-c", "true"],
               unit_kind: :repository
             )

    assert {:ok, second} =
             Fanout.run(second_plan, fixture.registry, state_root: fixture.state_root)

    first_runtime = hd(first.binding.units).runtime
    second_runtime = hd(second.binding.units).runtime

    assert first_runtime.deps_path == second_runtime.deps_path
    assert first_runtime.build_path == second_runtime.build_path
    assert second_runtime.build_present
  end

  test "separate runs serialize complete commands that share a build context", context do
    fixture = project_fixture(context)
    entered = Path.join(fixture.root, "first-entered")
    critical = Path.join(fixture.root, "critical")

    first_script =
      ~s|mkdir "#{critical}" && touch "#{entered}" && sleep 2 && rmdir "#{critical}"|

    second_script = ~s|mkdir "#{critical}" && rmdir "#{critical}"|

    assert {:ok, first_plan} =
             OperationPlan.build(fixture.registry, fixture.view, ["sh", "-c", first_script],
               project_ids: ["alpha"]
             )

    assert {:ok, second_plan} =
             OperationPlan.build(fixture.registry, fixture.view, ["sh", "-c", second_script],
               project_ids: ["alpha"]
             )

    first =
      Task.async(fn ->
        Fanout.run(first_plan, fixture.registry, state_root: fixture.state_root)
      end)

    wait_for_file!(entered)

    assert {:ok, second} =
             Fanout.run(second_plan, fixture.registry, state_root: fixture.state_root)

    assert {:ok, first_report} = Task.await(first, 10_000)
    assert first_report.status == :passed
    assert second.status == :passed

    [first_runtime] = first_report.binding.units
    [second_runtime] = second.binding.units
    assert first_runtime.runtime.build_path == second_runtime.runtime.build_path
  end

  test "binding records local paths but no removed credential names or values", context do
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
      refute Enum.any?(unit.command.env, &(&1.name == "HEX_API_KEY"))
      assert unit.runtime.status == "complete"
    end
  end

  test "an explicit child scheduler budget reaches every command", context do
    fixture = project_fixture(context)
    assert {:ok, plan} = OperationPlan.build(fixture.registry, fixture.view, ["true"])

    assert {:ok, report} =
             Fanout.run(plan, fixture.registry,
               state_root: fixture.state_root,
               max_concurrency: 2,
               beam_schedulers: 3
             )

    assert report.binding.beam_schedulers == 3

    for unit <- report.binding.units do
      assert %{value: value} = Enum.find(unit.command.env, &(&1.name == "ERL_AFLAGS"))
      assert value =~ "+S 3:3"
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

  defp wait_for_file!(path, attempts \\ 200)

  defp wait_for_file!(path, attempts) when attempts > 0 do
    if File.exists?(path) do
      :ok
    else
      Process.sleep(25)
      wait_for_file!(path, attempts - 1)
    end
  end

  defp wait_for_file!(path, 0), do: flunk("timed out waiting for #{path}")

  defp git!(root, args) do
    {output, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    output
  end
end
