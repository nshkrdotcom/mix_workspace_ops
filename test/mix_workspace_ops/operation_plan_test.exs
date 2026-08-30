defmodule MixWorkspaceOps.OperationPlanTest do
  use MixWorkspaceOps.WorkspaceCase, async: false

  alias MixWorkspaceOps.{OperationPlan, Registry, Report, View}

  test "a semantic plan is portable, self-digested, strict, and executes nothing", context do
    fixture = fixture(context)
    marker = Path.join(fixture.root, "plan-must-not-run")

    assert {:ok, plan} =
             OperationPlan.build(
               fixture.registry,
               fixture.view,
               ["sh", "-c", "touch ../plan-must-not-run"],
               mix_env: "test",
               mix_target: "host"
             )

    refute File.exists?(marker)
    assert plan.schema == "mix_workspace_ops.plan/v1"
    assert plan.digest == digest(Map.delete(plan, :digest))
    assert Enum.map(plan.units, & &1.id) == ["alpha", "beta"]
    assert Enum.all?(plan.units, &(&1.status == :planned))
    assert [%{application: "beta", source: "local"}] = hd(plan.units).sources

    strings = strings(plan)
    refute fixture.root in strings
    refute Enum.any?(strings, &String.contains?(&1, fixture.root))
    refute Enum.any?(strings, &String.contains?(&1, "credential-sentinel"))

    path = Path.join(fixture.root, "plan.json")
    assert :ok = OperationPlan.write(path, plan)
    assert String.trim_trailing(File.read!(path)) == Report.encode(plan)
    assert {:ok, loaded} = OperationPlan.load(path)
    assert loaded["digest"] == plan.digest

    extra = plan |> Map.put(:unexpected, true) |> redigest()
    assert :ok = Report.write(path, extra)

    assert {:error, {:operation_plan, ^path, {:operation_plan_keys, _expected, actual}}} =
             OperationPlan.load(path)

    assert "unexpected" in actual

    duplicated = plan |> Map.put(:units, plan.units ++ [hd(plan.units)]) |> redigest()
    assert :ok = Report.write(path, duplicated)

    assert {:error, {:operation_plan, ^path, :duplicate_operation_units}} =
             OperationPlan.load(path)

    absolute = plan |> put_in([:command, :executable], "/bin/true") |> redigest()
    assert :ok = Report.write(path, absolute)

    assert {:error, {:operation_plan, ^path, {:nonportable_command_segment, "/bin/true"}}} =
             OperationPlan.load(path)
  end

  test "planning rejects absolute command coordinates", context do
    fixture = fixture(context)

    assert OperationPlan.build(fixture.registry, fixture.view, ["/bin/true"]) ==
             {:error, {:nonportable_command_segment, "/bin/true"}}

    assert OperationPlan.build(fixture.registry, fixture.view, ["env", "OUT=/tmp/result"]) ==
             {:error, {:nonportable_command_segment, "OUT=/tmp/result"}}
  end

  test "a local override keeps an alternate checkout portable and binds that identity", context do
    fixture = fixture(context)
    alternate = Path.join([fixture.root, "alternate", "beta"])
    initialize_repository!(alternate, "[]", "example-org/beta")
    File.write!(Path.join(alternate, "alternate.txt"), "alternate checkout\n")
    git!(alternate, ["add", "alternate.txt"])
    git!(alternate, ["commit", "--quiet", "-m", "alternate revision"])

    File.write!(Path.join(fixture.alpha, ".gitignore"), ".dependency_sources.local.exs\n")
    git!(fixture.alpha, ["add", ".gitignore"])
    git!(fixture.alpha, ["commit", "--quiet", "-m", "ignore operator overrides"])

    File.write!(
      Path.join(fixture.alpha, ".dependency_sources.local.exs"),
      inspect(%{
        "deps" => %{
          "beta" => %{"source" => "path", "path" => alternate}
        }
      })
    )

    assert {:ok, plan} =
             OperationPlan.build(fixture.registry, fixture.view, ["true"], project: "alpha")

    assert [unit] = plan.units
    assert [source] = unit.sources
    assert source.source == "local"
    assert source.coordinates.repository.github == "example-org/beta"

    assert source.coordinates.expected.head ==
             alternate |> git!(["rev-parse", "HEAD"]) |> String.trim()

    refute Enum.any?(strings(plan), &String.contains?(&1, alternate))

    path = Path.join(fixture.root, "alternate-checkout-plan.json")
    assert :ok = OperationPlan.write(path, plan)
    assert {:ok, loaded} = OperationPlan.load(path)

    assert {:ok, report} =
             MixWorkspaceOps.Fanout.run(loaded, fixture.registry,
               state_root: Path.join(fixture.root, "alternate-state")
             )

    assert report.status == :passed
    assert [%{id: "alpha", status: :passed}] = report.results
  end

  test "replay names revision, dirty-byte, view, toolchain, and requested-policy drift",
       context do
    fixture = fixture(context)
    assert {:ok, recorded} = OperationPlan.build(fixture.registry, fixture.view, ["true"])

    File.write!(Path.join(fixture.alpha, "revision.txt"), "one\n")
    git!(fixture.alpha, ["add", "revision.txt"])
    git!(fixture.alpha, ["commit", "--quiet", "-m", "advance"])

    assert {:error, {:plan_drift, revision_drifts}} =
             OperationPlan.replay(recorded, fixture.registry, fixture.view, [])

    assert Enum.any?(revision_drifts, &(&1.field == :repository_head and &1.unit == "alpha"))

    assert {:ok, after_commit} =
             OperationPlan.build(fixture.registry, fixture.view, ["true"])

    File.write!(Path.join(fixture.alpha, "revision.txt"), "two\n")

    assert {:error, {:plan_drift, dirty_drifts}} =
             OperationPlan.replay(after_commit, fixture.registry, fixture.view, [])

    assert Enum.any?(dirty_drifts, &(&1.field == :source_digest and &1.unit == "alpha"))
    assert Enum.any?(dirty_drifts, &(&1.field == :dirty_state and &1.unit == "alpha"))

    git!(fixture.alpha, ["add", "revision.txt"])
    git!(fixture.alpha, ["commit", "--quiet", "-m", "second advance"])
    assert {:ok, current} = OperationPlan.build(fixture.registry, fixture.view, ["true"])

    changed_view_path =
      write_catalog_view!(fixture.root, "all_changed", %{
        "repository_ids" => ["alpha", "beta"]
      })

    {:ok, changed_view} = View.load(changed_view_path)
    changed_registry = select_and_bind(fixture.catalog_registry, changed_view, fixture.root)

    assert {:error, {:plan_drift, view_drifts}} =
             OperationPlan.replay(current, changed_registry, changed_view, [])

    assert Enum.any?(view_drifts, &(&1.field == :view))

    changed_tool = current |> put_in([:toolchain, :mix], "changed") |> redigest()
    changed_tool_path = Path.join(fixture.root, "changed-tool-plan.json")
    :ok = Report.write(changed_tool_path, changed_tool)
    assert {:ok, changed_tool} = OperationPlan.load(changed_tool_path)

    assert {:error, {:plan_drift, tool_drifts}} =
             OperationPlan.replay(changed_tool, fixture.registry, fixture.view, [])

    assert Enum.any?(tool_drifts, &(&1.field == :toolchain))

    changed_catalog_path = Path.join(fixture.root, "changed-registry.json")
    changed_catalog = fixture.catalog |> File.read!() |> :json.decode()

    changed_repositories =
      Enum.map(changed_catalog["repositories"], fn
        %{"id" => "alpha"} = repository -> Map.put(repository, "default_branch", "trunk")
        repository -> repository
      end)

    File.write!(
      changed_catalog_path,
      :json.encode(Map.put(changed_catalog, "repositories", changed_repositories))
    )

    changed_catalog_registry =
      changed_catalog_path
      |> Registry.load!()
      |> select_and_bind(fixture.view, fixture.root)

    assert {:error, {:plan_drift, registry_drifts}} =
             OperationPlan.replay(current, changed_catalog_registry, fixture.view, [])

    assert Enum.any?(registry_drifts, &(&1.field == :registry))

    assert {:error, {:plan_drift, policy_drifts}} =
             OperationPlan.replay(current, fixture.registry, fixture.view, [],
               failure_policy: :fail_fast
             )

    assert Enum.any?(policy_drifts, &(&1.field == :failure_policy))
  end

  defp fixture(context) do
    root = temporary_directory!(context)
    initialize_repository!(Path.join(root, "beta"))
    alpha = initialize_repository!(Path.join(root, "alpha"), ~s([{:beta, path: "../beta"}]))

    catalog =
      write_catalog!(root, [
        catalog_repository("alpha",
          projects: [catalog_project("alpha")],
          dependency_sources: %{
            "beta" => %{
              "github" => %{"repo" => "example-org/beta", "branch" => "main"},
              "hex" => "~> 0.1"
            }
          }
        ),
        catalog_repository("beta", projects: [catalog_project("beta")])
      ])

    catalog_registry = Registry.load!(catalog)
    view_path = write_catalog_view!(root, "all", %{})
    {:ok, view} = View.load(view_path)

    %{
      root: root,
      alpha: alpha,
      catalog: catalog,
      catalog_registry: catalog_registry,
      view: view,
      registry: select_and_bind(catalog_registry, view, root)
    }
  end

  defp select_and_bind(registry, view, root) do
    {:ok, repositories} = View.select_repositories(registry, view)
    {:ok, projects} = View.select(registry, view)
    selected = Registry.select(registry, projects, repositories)
    {:ok, bound} = Registry.bind(selected, root)
    bound
  end

  defp redigest(plan) do
    base = Map.delete(plan, :digest)
    Map.put(base, :digest, digest(base))
  end

  defp digest(value) do
    value
    |> Report.encode()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
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
