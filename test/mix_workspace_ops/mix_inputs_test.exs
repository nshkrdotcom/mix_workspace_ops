defmodule MixWorkspaceOps.MixInputsTest do
  use MixWorkspaceOps.WorkspaceCase, async: false

  alias MixWorkspaceOps.{CLI, Graph, Overlay, Project, Registry, Resolution}
  alias MixWorkspaceOps.Project.ProbeMemo

  setup context do
    previous_env = System.get_env("MIX_ENV")
    previous_target = System.get_env("MIX_TARGET")

    on_exit(fn ->
      restore_env("MIX_ENV", previous_env)
      restore_env("MIX_TARGET", previous_target)
    end)

    root = temporary_directory!(context)

    for repository <- ~w(alpha beta gamma delta equal) do
      initialize_repository!(Path.join(root, repository))
    end

    consumer = initialize_repository!(Path.join(root, "consumer"))

    File.write!(Path.join(consumer, "mix.exs"), conditional_mix())
    commit_all!(consumer)

    declarations =
      Map.new(~w(alpha beta gamma delta), fn app ->
        {app, %{"github" => %{}, "hex" => "~> 1.0"}}
      end)

    registry_path =
      write_catalog!(root, [
        catalog_repository("consumer",
          projects: [catalog_project("consumer")],
          dependency_sources: declarations
        ),
        catalog_repository("alpha", projects: [catalog_project("alpha")]),
        catalog_repository("beta", projects: [catalog_project("beta")]),
        catalog_repository("gamma", projects: [catalog_project("gamma")]),
        catalog_repository("delta", projects: [catalog_project("delta")]),
        catalog_repository("equal", projects: [catalog_project("equal")])
      ])

    registry = registry_path |> Registry.load!() |> bind!(root)
    {:ok, root: root, registry: registry, registry_path: registry_path}
  end

  test "environment and target choose dependencies and always identify the graph", context do
    assert {:ok, dev_host} =
             Graph.resolve(context.registry, "consumer", mix_env: "dev", mix_target: "host")

    assert dependency_apps(dev_host) == ["alpha"]

    assert {:ok, test_host} =
             Graph.resolve(context.registry, "consumer", mix_env: "test", mix_target: "host")

    assert dependency_apps(test_host) == ["beta"]

    assert {:ok, dev_embedded} =
             Graph.resolve(context.registry, "consumer",
               mix_env: "dev",
               mix_target: "embedded"
             )

    assert dependency_apps(dev_embedded) == ["gamma"]

    assert {:ok, test_embedded} =
             Graph.resolve(context.registry, "consumer",
               mix_env: "test",
               mix_target: "embedded"
             )

    assert dependency_apps(test_embedded) == ["delta"]

    digests = Enum.map([dev_host, test_host, dev_embedded, test_embedded], & &1.digest)
    assert length(Enum.uniq(digests)) == 4

    reader = fn _project -> {:ok, []} end

    assert {:ok, equal_dev} =
             Graph.resolve(context.registry, "equal",
               mix_env: "dev",
               mix_target: "host",
               dependency_reader: reader
             )

    assert {:ok, equal_test} =
             Graph.resolve(context.registry, "equal",
               mix_env: "test",
               mix_target: "host",
               dependency_reader: reader
             )

    assert equal_dev.projects == equal_test.projects
    assert equal_dev.dependency_applications == equal_test.dependency_applications
    refute equal_dev.digest == equal_test.digest
  end

  test "explicit inputs beat ambient values through metadata, resolution, overlay, and CLI",
       context do
    System.put_env("MIX_ENV", "test")
    System.put_env("MIX_TARGET", "embedded")
    memo = ProbeMemo.new()

    assert {:ok, metadata} =
             Project.metadata(context.registry, Registry.project!(context.registry, "consumer"),
               mix_env: "dev",
               mix_target: "host",
               probe_memo: memo
             )

    assert metadata.dependencies == ["alpha"]

    assert {:ok, decided} =
             Resolution.resolve(context.registry, "consumer",
               mix_env: "dev",
               mix_target: "host",
               probe_memo: memo
             )

    assert decided.mix_env == "dev"
    assert decided.mix_target == "host"
    assert Enum.map(decided.decisions, & &1.application) == ["alpha"]

    assert {:ok, activation} =
             Overlay.activate(context.registry, "consumer",
               mix_env: "dev",
               mix_target: "host",
               state_root: Path.join(context.root, "state")
             )

    assert activation.report.mix_env == "dev"
    assert activation.report.mix_target == "host"
    assert {"MIX_ENV", "dev"} in activation.env
    assert {"MIX_TARGET", "host"} in activation.env
    assert {:ok, overlay} = Overlay.read(activation.path)
    assert overlay.mix_env == "dev"
    assert overlay.mix_target == "host"

    assert {:ok, embedded_activation} =
             Overlay.activate(context.registry, "consumer",
               mix_env: "dev",
               mix_target: "embedded",
               state_root: Path.join(context.root, "embedded-state")
             )

    assert embedded_activation.report.mix_target == "embedded"
    assert Enum.map(embedded_activation.report.decisions, & &1.application) == ["gamma"]
    refute embedded_activation.report.graph_digest == activation.report.graph_digest
    refute embedded_activation.report.context_digest == activation.report.context_digest

    assert {:ok, plan} =
             CLI.dispatch([
               "plan",
               "--project",
               "consumer",
               "--registry",
               context.registry_path,
               "--checkout-root",
               context.root,
               "--mix-env",
               "dev",
               "--mix-target",
               "host"
             ])

    assert plan.mix_env == "dev"
    assert plan.mix_target == "host"
    assert Enum.map(plan.sources, & &1.application) == ["alpha"]
  end

  test "only and targets are classified under the explicit inputs", context do
    project = Path.join(context.root, "filtered")
    initialize_repository!(project)

    File.write!(Path.join(project, "mix.exs"), """
    defmodule Filtered.MixProject do
      use Mix.Project

      def project do
        [
          app: :filtered,
          version: "0.1.0",
          deps: [
            {:always, "~> 1.0"},
            {:dev_only, "~> 1.0", only: :dev},
            {:test_only, "~> 1.0", only: [:test]},
            {:embedded_only, "~> 1.0", targets: :embedded}
          ]
        ]
      end
    end
    """)

    registry_path =
      write_catalog!(
        context.root,
        [
          catalog_repository("filtered", projects: [catalog_project("filtered")])
        ],
        name: "filtered-registry.json"
      )

    registry = registry_path |> Registry.load!() |> bind!(context.root)

    assert {:ok, dev_host} =
             Graph.resolve(registry, "filtered", mix_env: "dev", mix_target: "host")

    assert dependency_apps(dev_host) == ["always", "dev_only"]

    assert {:ok, test_embedded} =
             Graph.resolve(registry, "filtered", mix_env: "test", mix_target: "embedded")

    assert dependency_apps(test_embedded) == ["always", "embedded_only", "test_only"]
  end

  defp dependency_apps(graph),
    do: Enum.map(graph.dependency_applications, & &1.application)

  defp conditional_mix do
    """
    defmodule Consumer.MixProject do
      use Mix.Project

      def project do
        dependency =
          case {Mix.env(), Mix.target()} do
            {:dev, :host} -> :alpha
            {:test, :host} -> :beta
            {:dev, :embedded} -> :gamma
            {:test, :embedded} -> :delta
          end

        [app: :consumer, version: "0.1.0", deps: [{dependency, "~> 1.0"}]]
      end
    end
    """
  end

  defp commit_all!(repository) do
    {_, 0} = System.cmd("git", ["add", "mix.exs"], cd: repository)
    {_, 0} = System.cmd("git", ["commit", "--quiet", "-m", "conditional fixture"], cd: repository)
    :ok
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
