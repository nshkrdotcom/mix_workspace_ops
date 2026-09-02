defmodule MixWorkspaceOps.Integration.TransitiveSourceProjectionTest do
  use ExUnit.Case, async: false

  alias MixWorkspaceOps.{Bootstrap, Runtime, Toolchain}

  test "an unmodified transitive declaration receives the catalog-selected root source" do
    root = temporary_directory!()
    state_root = Path.join(root, "state")
    consumer = Path.join(root, "consumer")
    middle = Path.join(root, "middle")
    leaf = Path.join(root, "leaf")

    write_project!(leaf, "leaf", "[]")
    write_project!(middle, "middle", ~s([{:leaf, path: "../missing_leaf"}]))
    write_project!(consumer, "consumer", ~s([{:middle, path: #{inspect(middle)}}]))

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

  defp write_project!(path, app, deps) do
    File.mkdir_p!(Path.join(path, "lib"))

    File.write!(Path.join(path, "mix.exs"), """
    defmodule #{Macro.camelize(app)}.MixProject do
      use Mix.Project
      def project, do: [app: :#{app}, version: "0.1.0", deps: #{deps}]
    end
    """)

    File.write!(Path.join(path, "lib/#{app}.ex"), "defmodule #{Macro.camelize(app)}, do: nil\n")
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

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
