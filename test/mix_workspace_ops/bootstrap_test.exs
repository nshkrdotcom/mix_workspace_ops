defmodule MixWorkspaceOps.BootstrapTest do
  use MixWorkspaceOps.WorkspaceCase, async: false

  import ExUnit.CaptureIO

  alias MixWorkspaceOps.{Bootstrap, Overlay}

  setup do
    previous = System.get_env("MIX_WORKSPACE_OPS_OVERLAY")
    previous_lock = System.get_env("MIX_WORKSPACE_OPS_LOCKFILE")
    argv = System.argv()

    on_exit(fn ->
      System.argv(argv)

      if previous,
        do: System.put_env("MIX_WORKSPACE_OPS_OVERLAY", previous),
        else: System.delete_env("MIX_WORKSPACE_OPS_OVERLAY")

      if previous_lock,
        do: System.put_env("MIX_WORKSPACE_OPS_LOCKFILE", previous_lock),
        else: System.delete_env("MIX_WORKSPACE_OPS_LOCKFILE")
    end)

    System.delete_env("MIX_WORKSPACE_OPS_OVERLAY")
    :ok
  end

  test "materializes one exact bootstrap outside managed repositories", context do
    root = temporary_directory!(context)
    project = Path.join(root, "project")
    File.mkdir_p!(project)

    assert {:ok, path} = Bootstrap.materialize(Path.join(root, "state"))
    assert String.starts_with?(path, Path.join(root, "state/bootstrap"))
    assert File.read!(path) == Bootstrap.contents()
    assert {:ok, ^path} = Bootstrap.materialize(Path.join(root, "state"))
    refute File.exists?(Path.join(project, "build_support"))
  end

  describe "the committed default, with no overlay" do
    test "a binary is a Hex requirement", context do
      root = temporary_directory!(context)

      assert MixWorkspaceOpsBootstrap.dep(:example_core, "~> 1.0", root) ==
               {:example_core, "~> 1.0"}

      assert MixWorkspaceOpsBootstrap.dep(:example_core, "~> 1.0", root, runtime: false) ==
               {:example_core, "~> 1.0", [runtime: false]}
    end

    test "a keyword list is committed git coordinates", context do
      root = temporary_directory!(context)

      assert MixWorkspaceOpsBootstrap.dep(
               :example_core,
               [github: "example-org/example_core", branch: "main"],
               root
             ) == {:example_core, [github: "example-org/example_core", branch: "main"]}

      assert MixWorkspaceOpsBootstrap.dep(
               :example_core,
               [github: "example-org/example_core", branch: "main"],
               root,
               override: true
             ) ==
               {:example_core,
                [github: "example-org/example_core", branch: "main", override: true]}
    end

    test "a committed default that is neither is refused by name", context do
      root = temporary_directory!(context)

      assert_raise RuntimeError, ~r/must be a Hex requirement or git coordinates/, fn ->
        MixWorkspaceOpsBootstrap.dep(:example_core, :whatever, root)
      end

      assert_raise RuntimeError, ~r/must be a keyword list carrying :github/, fn ->
        MixWorkspaceOpsBootstrap.dep(:example_core, [branch: "main"], root)
      end
    end
  end

  describe "an overlay row decides" do
    test "a local row emits a path dependency with no requirement", context do
      root = temporary_directory!(context)
      dependency = Path.join(root, "example_core")
      initialize_repository!(dependency)

      path =
        write_overlay!(root, ["example_core\tlocal\t#{dependency}\trevision\tsource\t-"])

      System.put_env("MIX_WORKSPACE_OPS_OVERLAY", path)

      assert capture_io(fn ->
               assert MixWorkspaceOpsBootstrap.dep(:example_core, "~> 1.0", root) ==
                        {:example_core, [path: dependency]}
             end) =~ "local path source in use for: example_core"
    end

    test "a local row carries the declared options", context do
      root = temporary_directory!(context)
      dependency = Path.join(root, "example_core")
      initialize_repository!(dependency)

      path =
        write_overlay!(root, [
          "example_core\tlocal\t#{dependency}\trevision\tsource\toverride=true"
        ])

      System.put_env("MIX_WORKSPACE_OPS_OVERLAY", path)

      capture_io(fn ->
        assert MixWorkspaceOpsBootstrap.dep(:example_core, "~> 1.0", root) ==
                 {:example_core, [path: dependency, override: true]}
      end)
    end

    test "a github row emits the coordinates the catalog carries", context do
      root = temporary_directory!(context)

      path =
        write_overlay!(root, [
          "example_core\tgithub\texample-org/example_core\tbranch\tmain\tcore/example\toverride=true"
        ])

      System.put_env("MIX_WORKSPACE_OPS_OVERLAY", path)

      assert MixWorkspaceOpsBootstrap.dep(:example_core, "~> 1.0", root) ==
               {:example_core,
                [
                  github: "example-org/example_core",
                  branch: "main",
                  subdir: "core/example",
                  override: true
                ]}
    end

    test "a github row with no revision and no subdirectory carries neither", context do
      root = temporary_directory!(context)
      path = write_overlay!(root, ["example_core\tgithub\texample-org/example_core\t-\t-\t-\t-"])
      System.put_env("MIX_WORKSPACE_OPS_OVERLAY", path)

      assert MixWorkspaceOpsBootstrap.dep(:example_core, "~> 1.0", root) ==
               {:example_core, [github: "example-org/example_core"]}
    end

    test "a hex row is two elements without options and three with them", context do
      root = temporary_directory!(context)

      path =
        write_overlay!(root, [
          "example_core\thex\t~> 2.0\t-",
          "example_edge\thex\t~> 0.8.2\tonly=dev|test,runtime=false"
        ])

      System.put_env("MIX_WORKSPACE_OPS_OVERLAY", path)

      assert MixWorkspaceOpsBootstrap.dep(:example_core, "~> 1.0", root) ==
               {:example_core, "~> 2.0"}

      assert MixWorkspaceOpsBootstrap.dep(:example_edge, "~> 1.0", root) ==
               {:example_edge, "~> 0.8.2", [only: [:dev, :test], runtime: false]}
    end

    test "call-site options win over the ones the overlay carries", context do
      root = temporary_directory!(context)
      path = write_overlay!(root, ["example_core\thex\t~> 2.0\truntime=false"])
      System.put_env("MIX_WORKSPACE_OPS_OVERLAY", path)

      assert MixWorkspaceOpsBootstrap.dep(:example_core, "~> 1.0", root, runtime: true) ==
               {:example_core, "~> 2.0", [runtime: true]}
    end

    test "an application the overlay does not carry keeps its committed default", context do
      root = temporary_directory!(context)
      path = write_overlay!(root, ["example_core\thex\t~> 2.0\t-"])
      System.put_env("MIX_WORKSPACE_OPS_OVERLAY", path)

      assert MixWorkspaceOpsBootstrap.dep(
               :example_edge,
               [github: "example-org/example_edge", branch: "main"],
               root
             ) == {:example_edge, [github: "example-org/example_edge", branch: "main"]}
    end
  end

  describe "the local path notice" do
    test "is emitted once per repository root and never for a quiet task", context do
      root = temporary_directory!(context)
      dependency = Path.join(root, "example_core")
      initialize_repository!(dependency)
      path = write_overlay!(root, ["example_core\tlocal\t#{dependency}\trevision\tsource\t-"])
      System.put_env("MIX_WORKSPACE_OPS_OVERLAY", path)

      first = Path.join(root, "first")
      second = Path.join(root, "second")

      assert capture_io(fn -> MixWorkspaceOpsBootstrap.dep(:example_core, "~> 1.0", first) end) =~
               "local path source in use for: example_core"

      assert capture_io(fn -> MixWorkspaceOpsBootstrap.dep(:example_core, "~> 1.0", first) end) ==
               ""

      System.argv(["run", "-e", ":ok"])

      assert capture_io(fn -> MixWorkspaceOpsBootstrap.dep(:example_core, "~> 1.0", second) end) ==
               ""
    end

    test "a closure with no local source carries no notice", context do
      root = temporary_directory!(context)
      path = write_overlay!(root, ["example_core\thex\t~> 2.0\t-"])
      System.put_env("MIX_WORKSPACE_OPS_OVERLAY", path)

      assert capture_io(fn -> MixWorkspaceOpsBootstrap.dep(:example_core, "~> 1.0", root) end) ==
               ""
    end
  end

  describe "publishing" do
    test "refuses an overlay decided for development", context do
      root = temporary_directory!(context)
      path = write_overlay!(root, ["example_core\thex\t~> 2.0\t-"], publish: false)
      System.put_env("MIX_WORKSPACE_OPS_OVERLAY", path)
      System.argv(["hex.publish"])

      assert_raise RuntimeError, ~r/decided for development/, fn ->
        MixWorkspaceOpsBootstrap.dep(:example_core, "~> 1.0", root)
      end
    end

    test "uses an overlay decided under publish resolution", context do
      root = temporary_directory!(context)

      path =
        write_overlay!(
          root,
          ["example_core\tgithub\texample-org/example_core\tbranch\tmain\t-\t-"],
          publish: true,
          mode: "hex"
        )

      System.put_env("MIX_WORKSPACE_OPS_OVERLAY", path)
      System.argv(["hex.publish"])

      assert MixWorkspaceOpsBootstrap.dep(:example_core, "~> 1.0", root) ==
               {:example_core, [github: "example-org/example_core", branch: "main"]}
    end

    test "reads task position, so an argument is not a publication", context do
      root = temporary_directory!(context)
      path = write_overlay!(root, ["example_core\thex\t~> 2.0\t-"], publish: false)
      System.put_env("MIX_WORKSPACE_OPS_OVERLAY", path)
      System.argv(["run", "--arg", "hex.publish"])

      assert MixWorkspaceOpsBootstrap.dep(:example_core, "~> 1.0", root) ==
               {:example_core, "~> 2.0"}
    end
  end

  describe "the overlay it will not read" do
    test "rejects relative overlay paths", context do
      root = temporary_directory!(context)
      System.put_env("MIX_WORKSPACE_OPS_OVERLAY", "relative.tsv")

      assert_raise RuntimeError, ~r/must contain an absolute path/, fn ->
        MixWorkspaceOpsBootstrap.dep(:example_core, "~> 1.0", root)
      end
    end

    test "rejects an overlay whose bytes no longer match its address", context do
      root = temporary_directory!(context)
      path = write_overlay!(root, ["example_core\thex\t~> 2.0\t-"])
      File.write!(path, File.read!(path) <> "example_edge\thex\t~> 1.0\t-\n")
      System.put_env("MIX_WORKSPACE_OPS_OVERLAY", path)

      assert_raise RuntimeError, ~r/digest mismatch/, fn ->
        MixWorkspaceOpsBootstrap.dep(:example_core, "~> 1.0", root)
      end
    end

    test "rejects an option it does not know and a list beyond the atom bound", context do
      root = temporary_directory!(context)
      path = write_overlay!(root, ["example_core\thex\t~> 2.0\tsauce=true"])
      System.put_env("MIX_WORKSPACE_OPS_OVERLAY", path)

      assert_raise RuntimeError, ~r/unknown Mix Workspace Ops dependency option/, fn ->
        MixWorkspaceOpsBootstrap.dep(:example_core, "~> 1.0", root)
      end

      names = 1..9 |> Enum.map_join("|", &"env_#{&1}")
      long = write_overlay!(root, ["example_core\thex\t~> 2.0\tonly=#{names}"])
      System.put_env("MIX_WORKSPACE_OPS_OVERLAY", long)

      assert_raise RuntimeError, ~r/invalid Mix Workspace Ops option only/, fn ->
        MixWorkspaceOpsBootstrap.dep(:example_core, "~> 1.0", root)
      end
    end
  end

  describe "the seam and the module agree" do
    @options [
      [],
      [override: true],
      [runtime: false],
      [optional: true],
      [only: [:dev, :test]],
      [targets: [:host]],
      [only: [:dev, :test], optional: true, override: true, runtime: false, targets: [:host]]
    ]

    test "every options encoding round-trips through both decoders" do
      for options <- @options do
        encoded = Overlay.encode_options(options)
        assert {:ok, ^options} = Overlay.decode_options(encoded)
        assert MixWorkspaceOpsBootstrap.decode_options(encoded) == options
      end
    end
  end

  test "supplies only an explicit absolute operator lockfile", context do
    root = temporary_directory!(context)
    lockfile = Path.join(root, "state/mix.lock")
    File.mkdir_p!(Path.dirname(lockfile))
    File.write!(lockfile, "%{}\n")

    assert MixWorkspaceOpsBootstrap.project_options(root) == []
    System.put_env("MIX_WORKSPACE_OPS_LOCKFILE", lockfile)
    assert MixWorkspaceOpsBootstrap.project_options(root) == [lockfile: lockfile]

    System.put_env("MIX_WORKSPACE_OPS_LOCKFILE", "relative.lock")

    assert_raise RuntimeError, ~r/must contain an absolute path/, fn ->
      MixWorkspaceOpsBootstrap.project_options(root)
    end
  end

  defp write_overlay!(root, rows, opts \\ []) do
    contents =
      Enum.join(
        [
          "mix_workspace_ops.overlay/v2",
          "registry_digest\tdigest",
          "selection_digest\t#{Keyword.get(opts, :selection_digest, "-")}",
          "graph_digest\tgraph",
          "context_digest\tcontext",
          "target\texample_consumer",
          "mode\t#{Keyword.get(opts, :mode, "auto")}",
          "publish\t#{Keyword.get(opts, :publish, false)}",
          "target_head\trevision",
          "target_source_digest\tsource",
          "lock_digest\tlock",
          "toolchain\telixir-test-otp-test"
        ] ++ rows,
        "\n"
      ) <> "\n"

    digest = :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
    path = Path.join(root, "state/#{digest}.tsv")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end
end
