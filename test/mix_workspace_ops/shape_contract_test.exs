defmodule MixWorkspaceOps.ShapeContractTest do
  use MixWorkspaceOps.WorkspaceCase, async: true

  alias MixWorkspaceOps.{Overlay, Registry}

  test "an ordinary umbrella with no switchable cross-repo deps needs zero MWO code", context do
    root = temporary_directory!(context)
    repository = initialize_repository!(Path.join(root, "umbrella"))
    state_root = Path.join(root, "operator-state")

    write_umbrella!(repository)
    commit_all!(repository, "create umbrella")

    registry =
      root
      |> write_catalog!([
        catalog_repository("umbrella",
          workspace: %{"kind" => "umbrella"},
          projects: [
            catalog_project("umbrella", kind: "workspace_root", app: nil),
            catalog_project("umbrella.core",
              app: "umbrella_core",
              path: "apps/umbrella_core",
              kind: "package"
            ),
            catalog_project("umbrella.web",
              app: "umbrella_web",
              path: "apps/umbrella_web",
              kind: "package"
            )
          ]
        )
      ])
      |> Registry.load!()
      |> bind!(root)

    assert {:ok, activation} =
             Overlay.activate(registry, "umbrella", state_root: state_root)

    assert MapSet.new(activation.report.projects) ==
             MapSet.new(["umbrella.core", "umbrella.web"])

    assert activation.report.runtime.ownership == :managed

    assert {output, 0} =
             System.cmd("mix", ["compile", "--warnings-as-errors"],
               cd: repository,
               env: activation.env,
               stderr_to_stdout: true
             )

    assert output =~ "Generated umbrella_core app"
    refute repository_contains_mwo?(repository)
    refute File.exists?(Path.join(repository, "deps"))
    refute File.exists?(Path.join(repository, "_build"))
  end

  defp write_umbrella!(repository) do
    File.mkdir_p!(Path.join(repository, "apps/umbrella_core/lib"))
    File.mkdir_p!(Path.join(repository, "apps/umbrella_web/lib"))

    File.write!(Path.join(repository, "mix.exs"), """
    defmodule Umbrella.MixProject do
      use Mix.Project
      def project, do: [apps_path: "apps", version: "0.1.0"]
    end
    """)

    File.write!(Path.join(repository, "apps/umbrella_core/mix.exs"), """
    defmodule UmbrellaCore.MixProject do
      use Mix.Project
      def project, do: [app: :umbrella_core, version: "0.1.0"]
    end
    """)

    File.write!(Path.join(repository, "apps/umbrella_core/lib/core.ex"), """
    defmodule UmbrellaCore do
      def value, do: :ok
    end
    """)

    File.write!(Path.join(repository, "apps/umbrella_web/mix.exs"), """
    defmodule UmbrellaWeb.MixProject do
      use Mix.Project
      def project, do: [app: :umbrella_web, version: "0.1.0", deps: [{:umbrella_core, in_umbrella: true}]]
    end
    """)

    File.write!(Path.join(repository, "apps/umbrella_web/lib/web.ex"), """
    defmodule UmbrellaWeb do
      def value, do: UmbrellaCore.value()
    end
    """)
  end

  defp repository_contains_mwo?(repository) do
    repository
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.any?(fn path -> path |> File.read!() |> String.contains?("MIX_WORKSPACE_OPS") end)
  end

  defp commit_all!(repository, message) do
    {_, 0} = System.cmd("git", ["add", "."], cd: repository)
    {_, 0} = System.cmd("git", ["commit", "--quiet", "-m", message], cd: repository)
  end
end
