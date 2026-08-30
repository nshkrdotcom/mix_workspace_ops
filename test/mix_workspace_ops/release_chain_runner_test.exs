defmodule MixWorkspaceOps.Release.ChainRunnerTest do
  use MixWorkspaceOps.WorkspaceCase, async: true

  alias MixWorkspaceOps.Registry
  alias MixWorkspaceOps.Release.{Chain, Plan}

  defmodule Adapter do
    @behaviour MixWorkspaceOps.Release.Adapter

    @impl true
    def transition(transition, context) do
      options = context.plan.adapter_options
      send(options.owner, {:transition, context.plan.package, transition})

      fail? =
        Agent.get_and_update(options.failure, fn
          {package, ^transition} when package == context.plan.package -> {true, nil}
          current -> {false, current}
        end)

      if fail?, do: {:error, :injected}, else: {:ok, evidence(transition, context)}
    end

    @impl true
    def resume(transition, :completed, context) do
      send(context.plan.adapter_options.owner, {:resumed, context.plan.package, transition})
      {:ok, %{}}
    end

    def resume(_transition, :started, _context), do: :rerun

    defp evidence(:preflight, _context), do: %{head: String.duplicate("a", 40)}
    defp evidence(:checkout, context), do: %{checkout: context.plan.repository}

    defp evidence(:archive, context),
      do: %{archive: "#{context.plan.package}.tar", archive_checksum: String.duplicate("b", 64)}

    defp evidence(:verify, _context), do: %{registry_checksum: String.duplicate("b", 64)}
    defp evidence(:tag, context), do: %{tag: context.plan.tag}
    defp evidence(_transition, _context), do: %{}
  end

  test "mid-chain interruption resumes at the first incomplete package", context do
    root = temporary_directory!(context)
    state_root = Path.join(root, "state")
    {:ok, failure} = Agent.start_link(fn -> {"leaf", :preflight} end)

    registry = registry(root)
    assert {:ok, semantic_plan} = Plan.build(registry, "leaf")
    descriptor = descriptor(semantic_plan, registry)

    options = [
      adapter: Adapter,
      adapter_options: %{owner: self(), failure: failure},
      state_root: state_root
    ]

    assert {:error, {:release_chain, "leaf", _reason, report}} =
             Chain.run(registry, semantic_plan, descriptor, options)

    assert report.completed_packages == ["core"]
    assert report.blocked_package == "leaf"
    first_messages = drain([])
    assert {:transition, "core", :publish} in first_messages
    refute {:transition, "leaf", :publish} in first_messages

    assert {:ok, resumed} =
             Chain.run(
               registry,
               semantic_plan,
               descriptor,
               options ++ [resume: report.transaction_id]
             )

    second_messages = drain([])
    refute {:transition, "core", :publish} in second_messages
    assert {:resumed, "core", :publish} in second_messages
    assert {:transition, "leaf", :publish} in second_messages
    assert resumed.completed_packages == ["core", "leaf"]
  end

  test "descriptor package membership is checked in both directions", context do
    root = temporary_directory!(context)
    registry = registry(root)
    assert {:ok, semantic_plan} = Plan.build(registry, "leaf")
    descriptor = descriptor(semantic_plan, registry)

    missing = update_in(descriptor.packages, &Map.delete(&1, "core"))

    assert Chain.run(registry, semantic_plan, missing, adapter: Adapter) ==
             {:error, {:release_descriptor_packages, ["core", "leaf"], ["leaf"]}}

    invented = put_in(descriptor.packages["invented"], descriptor.packages["core"])

    assert Chain.run(registry, semantic_plan, invented, adapter: Adapter) ==
             {:error,
              {:release_descriptor_packages, ["core", "leaf"], ["core", "invented", "leaf"]}}
  end

  test "a self-digested plan cannot reorder the catalogued chain", context do
    root = temporary_directory!(context)
    registry = registry(root)
    assert {:ok, semantic_plan} = Plan.build(registry, "leaf")
    descriptor = descriptor(semantic_plan, registry)

    reordered = %{
      semantic_plan
      | order: Enum.reverse(semantic_plan.order),
        units: Enum.reverse(semantic_plan.units)
    }

    reordered = %{reordered | digest: Plan.digest(reordered)}
    descriptor = %{descriptor | release_plan_digest: reordered.digest}

    assert Chain.run(registry, reordered, descriptor, adapter: Adapter) ==
             {:error, :release_plan_registry_drift}

    assert drain([]) == []
  end

  defp registry(root) do
    registry =
      root
      |> write_catalog!([
        catalog_repository("core",
          projects: [catalog_project("core")],
          release_chain: %{"core" => []}
        ),
        catalog_repository("leaf",
          projects: [catalog_project("leaf")],
          dependency_sources: %{"core" => %{"hex" => "~> 1.0"}},
          release_chain: %{"leaf" => []}
        )
      ])
      |> Registry.load!()

    %{
      registry
      | bindings: %{"core" => Path.join(root, "core"), "leaf" => Path.join(root, "leaf")}
    }
  end

  defp descriptor(plan, registry) do
    package = fn version ->
      %{version: version, tag: "v#{version}", gates: [["mix", "test"]], prepared_artifact: nil}
    end

    %{
      schema: "mix_workspace_ops.release_descriptor/v2",
      release_plan_digest: plan.digest,
      registry_digest: registry.digest,
      publisher_prefix: ["/operator/publisher"],
      packages: %{"core" => package.("1.0.0"), "leaf" => package.("2.0.0")}
    }
  end

  defp drain(acc) do
    receive do
      message -> drain(acc ++ [message])
    after
      0 -> acc
    end
  end
end
