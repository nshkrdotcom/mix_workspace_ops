defmodule MixWorkspaceOps.BootstrapTest do
  use MixWorkspaceOps.WorkspaceCase, async: false

  alias MixWorkspaceOps.Bootstrap

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

  test "the standalone bootstrap reads an ancestor overlay", context do
    root = temporary_directory!(context)
    dependency = Path.join(root, "dependency")
    project = Path.join(root, "apps/consumer")
    initialize_repository!(dependency)
    File.mkdir_p!(project)
    path = Path.join(root, ".mix_workspace_ops/sources.tsv")
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      "mix_workspace_ops\t1\n" <>
        "catalog_digest\tdigest\ntarget\tconsumer\nmode\tlocal\n" <>
        "dependency\tpath\t#{dependency}\trevision\n"
    )

    assert {:dependency, "~> 1.0", options} =
             MixWorkspaceOpsBootstrap.dep(:dependency, "~> 1.0", project)

    assert options[:path] == dependency
    assert options[:override]
  end
end
