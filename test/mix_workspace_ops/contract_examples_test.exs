defmodule MixWorkspaceOps.ContractExamplesTest do
  use MixWorkspaceOps.WorkspaceCase, async: true

  alias MixWorkspaceOps.{Overlay, Registry}

  @runner Path.expand("../../examples/delegated_runner.exs", __DIR__)

  test "a delegated runner inherits sources and reuses state without caching command results",
       context do
    root = temporary_directory!(context)
    core = initialize_repository!(Path.join(root, "core"))
    consumer = initialize_repository!(Path.join(root, "consumer"))
    state_root = Path.join(root, "operator-state")
    runner_state = Path.join(root, "runner-state")

    File.mkdir_p!(Path.join(core, "lib"))
    File.write!(Path.join(core, "lib/core.ex"), "defmodule Core, do: def(value, do: :local)\n")
    commit_all!(core, "add core module")

    File.write!(Path.join(consumer, "mix.exs"), managed_consumer_mixfile())
    commit_all!(consumer, "use managed dependency")

    registry =
      root
      |> write_catalog!([
        catalog_repository("core", projects: [catalog_project("core")]),
        catalog_repository("consumer",
          projects: [catalog_project("consumer")],
          dependency_sources: %{"core" => %{"hex" => "~> 0.1.0"}}
        )
      ])
      |> Registry.load!()
      |> bind!(root)

    assert {:ok, first} =
             Overlay.activate(registry, "consumer",
               state_root: state_root,
               mix_state: :delegated
             )

    assert {first_output, 0} = run_example(consumer, runner_state, first.env)
    assert first_output =~ ":local"
    assert first_output =~ "NEW_CONTEXT"

    assert {second_output, 0} = run_example(consumer, runner_state, first.env)
    assert second_output =~ "REUSED_CONTEXT"

    File.write!(Path.join(core, "lib/core.ex"), "defmodule Core, do: def(value, do: :changed)\n")

    assert {:ok, changed} =
             Overlay.activate(registry, "consumer",
               state_root: state_root,
               mix_state: :delegated
             )

    assert changed.report.context_digest == first.report.context_digest
    assert {changed_output, 0} = run_example(consumer, runner_state, changed.env)
    assert changed_output =~ ":changed"
    assert changed_output =~ "REUSED_CONTEXT"

    refute File.exists?(Path.join(consumer, "deps"))
    refute File.exists?(Path.join(consumer, "_build"))
    assert File.dir?(Path.join(runner_state, "contexts"))
    refute File.exists?(Path.join(runner_state, "children"))
  end

  defp run_example(project, state_root, environment) do
    System.cmd(
      "elixir",
      [@runner, project, state_root, "mix", "run", "-e", "IO.inspect(Core.value())"],
      env: environment,
      stderr_to_stdout: true
    )
  end

  defp managed_consumer_mixfile do
    """
    if bootstrap = System.get_env("MIX_WORKSPACE_OPS_BOOTSTRAP") do
      Code.require_file(bootstrap)
    end

    defmodule Consumer.MixProject do
      use Mix.Project

      def project do
        [app: :consumer, version: "0.1.0", deps: [workspace_dep({:core, ">= 0.0.0"})]]
      end

      defp workspace_dep(committed) do
        if function_exported?(MixWorkspaceOpsBootstrap, :dep, 2),
          do: apply(MixWorkspaceOpsBootstrap, :dep, [committed, __DIR__]),
          else: committed
      end
    end
    """
  end

  defp commit_all!(repository, message) do
    {_, 0} = System.cmd("git", ["add", "."], cd: repository)
    {_, 0} = System.cmd("git", ["commit", "--quiet", "-m", message], cd: repository)
  end
end
