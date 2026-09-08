defmodule MixWorkspaceOps.Integration.TransitiveSourceProjectionTest do
  use MixWorkspaceOps.WorkspaceCase, async: false

  alias MixWorkspaceOps.{Bootstrap, Overlay, Registry, Runtime, Toolchain, View}

  test "an unmodified transitive declaration receives the catalog-selected root source" do
    root = temporary_directory!()
    state_root = Path.join(root, "state")
    consumer = Path.join(root, "consumer")
    middle = Path.join(root, "middle")
    leaf = Path.join(root, "leaf")

    write_project!(leaf, "leaf", "[]")
    write_project!(middle, "middle", ~s([{:leaf, path: "../missing_leaf"}]))
    write_project!(consumer, "consumer", ~s([{:middle, path: #{inspect(middle)}}]))

    {unmanaged, unmanaged_status} =
      System.cmd(
        Toolchain.executable("mix"),
        [
          "run",
          "--no-start",
          "--no-deps-check",
          "--no-compile",
          "-e",
          "IO.puts(inspect(Mix.Project.config()[:deps]))"
        ],
        cd: consumer,
        env: unmanaged_environment(),
        stderr_to_stdout: true
      )

    assert unmanaged_status == 0
    assert unmanaged =~ inspect(middle)
    refute unmanaged =~ "leaf"
    File.rm_rf!(Path.join(consumer, "_build"))
    File.rm_rf!(Path.join(consumer, "deps"))

    overlay =
      write_overlay!(root, [
        ["middle", "local", middle, "revision", digest("middle"), "-"],
        ["leaf", "local", leaf, "revision", digest("leaf"), "-"]
      ])

    {:ok, bootstrap} = Bootstrap.materialize(state_root)

    assert {:ok, runtime} =
             Runtime.prepare(state_root, digest("consumer-context"), "%{}\n",
               ownership: :managed,
               target_head: String.duplicate("a", 40),
               target_source_digest: digest("consumer-source"),
               binding_root: consumer,
               project_identity: "consumer",
               mix_env: "dev",
               mix_target: "host"
             )

    env =
      [
        {"MIX_WORKSPACE_OPS_BOOTSTRAP", bootstrap},
        {"MIX_WORKSPACE_OPS_OVERLAY", overlay}
        | runtime.env
      ]
      |> Enum.reject(&(elem(&1, 1) == nil))

    {output, exit_code} =
      System.cmd(Toolchain.executable("mix"), ["deps.get"],
        cd: consumer,
        env: env,
        stderr_to_stdout: true
      )

    assert exit_code == 0, output

    {deps, deps_status} =
      System.cmd(Toolchain.executable("mix"), ["deps"],
        cd: consumer,
        env: env,
        stderr_to_stdout: true
      )

    assert deps_status == 0, deps
    assert deps =~ "* leaf (#{leaf})"

    refute File.exists?(Path.join(root, "missing_leaf"))
    refute File.exists?(Path.join(consumer, "deps"))
    refute File.exists?(Path.join(consumer, "_build"))
    assert {:ok, _report} = Runtime.finish(runtime.handle)
    assert :ok = Runtime.release(runtime.handle)
  end

  test "an inherited source cannot hide an incompatible transitive requirement", context do
    root = temporary_directory!(context)
    state_root = Path.join(root, "state")
    consumer = Path.join(root, "consumer")
    middle = Path.join(root, "middle")
    leaf = Path.join(root, "leaf")

    initialize_repository!(leaf)
    initialize_repository!(middle)
    initialize_repository!(consumer)
    rewrite_project!(leaf, "leaf", "[]", "1.0.0")
    rewrite_project!(middle, "middle", ~s([{:leaf, "~> 2.0", path: "../missing_leaf"}]))
    rewrite_project!(consumer, "consumer", ~s([{:middle, path: #{inspect(middle)}}]))

    catalog =
      write_catalog!(root, [
        catalog_repository("leaf", projects: [catalog_project("leaf")]),
        catalog_repository("middle",
          projects: [
            catalog_project("middle",
              dependency_sources: %{"leaf" => %{"hex" => "~> 2.0"}}
            )
          ]
        ),
        catalog_repository("consumer",
          projects: [
            catalog_project("consumer",
              dependency_sources: %{"middle" => %{"hex" => "~> 0.1"}}
            )
          ]
        )
      ])

    view_path = write_catalog_view!(root, "all", %{})
    registry = Registry.load!(catalog)
    {:ok, view} = View.load(view_path)
    {:ok, repositories} = View.select_repositories(registry, view)
    {:ok, projects} = View.select(registry, view)
    registry = Registry.select(registry, projects, repositories)
    {:ok, registry} = Registry.bind(registry, root)

    assert {:error,
            {:dependency_requirement_mismatch, "leaf", "middle", "~> 2.0", "leaf", "1.0.0"}} =
             Overlay.activate(registry, "consumer", state_root: state_root)
  end

  test "the root projection does not fulfill an otherwise unfulfilled transitive optional",
       context do
    root = temporary_directory!(context)
    state_root = Path.join(root, "state")
    consumer = Path.join(root, "consumer")
    middle = Path.join(root, "middle")
    leaf = Path.join(root, "leaf")

    initialize_repository!(leaf)
    initialize_repository!(middle)
    initialize_repository!(consumer)
    rewrite_project!(leaf, "leaf", "[]", "1.0.0")

    rewrite_project!(
      middle,
      "middle",
      ~s([{:leaf, "~> 1.0", path: "../missing_leaf", optional: true}])
    )

    rewrite_project!(consumer, "consumer", ~s([{:middle, path: #{inspect(middle)}}]))

    catalog =
      write_catalog!(root, [
        catalog_repository("leaf", projects: [catalog_project("leaf")]),
        catalog_repository("middle",
          projects: [
            catalog_project("middle",
              dependency_sources: %{"leaf" => %{"hex" => "~> 1.0"}}
            )
          ]
        ),
        catalog_repository("consumer",
          projects: [
            catalog_project("consumer",
              dependency_sources: %{"middle" => %{"hex" => "~> 0.1"}}
            )
          ]
        )
      ])

    view_path = write_catalog_view!(root, "all", %{})
    registry = Registry.load!(catalog)
    {:ok, view} = View.load(view_path)
    {:ok, repositories} = View.select_repositories(registry, view)
    {:ok, projects} = View.select(registry, view)
    registry = Registry.select(registry, projects, repositories)
    {:ok, registry} = Registry.bind(registry, root)

    assert {:ok, activation} = Overlay.activate(registry, "consumer", state_root: state_root)
    assert Enum.map(activation.report.decisions, & &1.application) == ["middle"]

    {output, status} =
      System.cmd(Toolchain.executable("mix"), ["deps.get"],
        cd: consumer,
        env: activation.env,
        stderr_to_stdout: true
      )

    assert status == 0, output
    refute File.exists?(Path.join(activation.report.runtime.deps_path, "leaf"))
    assert {:ok, _runtime} = Overlay.deactivate(activation)
  end

  defp write_project!(path, app, deps, version \\ "0.1.0") do
    File.mkdir_p!(Path.join(path, "lib"))

    File.write!(Path.join(path, "mix.exs"), """
    defmodule #{Macro.camelize(app)}.MixProject do
      use Mix.Project
      def project, do: [app: :#{app}, version: #{inspect(version)}, deps: #{deps}]
    end
    """)

    File.write!(Path.join(path, "lib/#{app}.ex"), "defmodule #{Macro.camelize(app)}, do: nil\n")
  end

  defp rewrite_project!(path, app, deps, version \\ "0.1.0") do
    write_project!(path, app, deps, version)
    {_, 0} = System.cmd("git", ["add", "mix.exs", "lib"], cd: path, stderr_to_stdout: true)

    {_, 0} =
      System.cmd("git", ["commit", "--quiet", "-m", "rewrite fixture"],
        cd: path,
        stderr_to_stdout: true
      )
  end

  defp write_overlay!(root, rows) do
    contents =
      ([
         "mix_workspace_ops.overlay/v3",
         "registry_digest\t#{digest("registry")}",
         "selection_digest\t#{digest("selection")}",
         "graph_digest\t#{digest("graph")}",
         "mix_env\tdev",
         "mix_target\thost",
         "context_digest\t#{digest("context")}",
         "target\tconsumer",
         "mode\tlocal",
         "publish\tfalse",
         "target_head\t#{String.duplicate("a", 40)}",
         "target_source_digest\t#{digest("source")}",
         "lock_digest\t#{digest("lock")}",
         "toolchain\ttest"
       ] ++ Enum.map(rows, &Enum.join(&1, "\t")))
      |> Enum.join("\n")
      |> Kernel.<>("\n")

    path = Path.join(root, digest(contents) <> ".tsv")
    File.write!(path, contents)
    path
  end

  defp temporary_directory! do
    path = Path.join(System.tmp_dir!(), "mwo_transitive_#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp unmanaged_environment do
    [
      {"MIX_WORKSPACE_OPS_BOOTSTRAP", nil},
      {"MIX_WORKSPACE_OPS_OVERLAY", nil},
      {"MIX_WORKSPACE_OPS_LOCKFILE", nil},
      {"MIX_DEPS_PATH", nil},
      {"MIX_BUILD_PATH", nil}
    ]
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
