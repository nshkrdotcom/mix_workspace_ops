defmodule MixWorkspaceOps.BootstrapTest do
  use MixWorkspaceOps.WorkspaceCase, async: false

  alias MixWorkspaceOps.Bootstrap

  setup do
    previous = System.get_env("MIX_WORKSPACE_OPS_OVERLAY")

    on_exit(fn ->
      if previous,
        do: System.put_env("MIX_WORKSPACE_OPS_OVERLAY", previous),
        else: System.delete_env("MIX_WORKSPACE_OPS_OVERLAY")
    end)

    :ok
  end

  test "installs an exact minimal bootstrap and refuses drift", context do
    root = temporary_directory!(context)

    assert {:ok, path} = Bootstrap.install(root)
    assert path == Path.join(root, Bootstrap.relative_path())
    assert File.read!(path) == Bootstrap.contents()
    assert Bootstrap.status(root) == :current

    File.write!(path, "operator edit\n")
    assert {:drifted, digest} = Bootstrap.status(root)
    assert {:error, {:bootstrap_drift, ^path, ^digest}} = Bootstrap.install(root)
  end

  test "the standalone bootstrap reads only the explicit absolute overlay", context do
    root = temporary_directory!(context)
    dependency = Path.join(root, "dependency")
    project_root = Path.join(root, "consumer")
    initialize_repository!(dependency)
    File.mkdir_p!(project_root)
    path = Path.join(root, "state/overlay.tsv")
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      "mix_workspace_ops.overlay/v1\n" <>
        "registry_digest\tdigest\ngraph_digest\tgraph\ntarget\tconsumer\nmode\tlocal\n" <>
        "dependency\tpath\t#{dependency}\trevision\n"
    )

    assert {:dependency, "~> 1.0"} =
             MixWorkspaceOpsBootstrap.dep(:dependency, "~> 1.0", project_root)

    System.put_env("MIX_WORKSPACE_OPS_OVERLAY", path)

    assert {:dependency, "~> 1.0", options} =
             MixWorkspaceOpsBootstrap.dep(:dependency, "~> 1.0", project_root)

    assert options[:path] == dependency
    assert options[:override]
  end

  test "rejects relative overlay paths", context do
    root = temporary_directory!(context)
    System.put_env("MIX_WORKSPACE_OPS_OVERLAY", "relative.tsv")

    assert_raise RuntimeError, ~r/must contain an absolute path/, fn ->
      MixWorkspaceOpsBootstrap.dep(:dependency, "~> 1.0", root)
    end
  end
end
