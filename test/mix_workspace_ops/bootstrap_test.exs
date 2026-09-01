defmodule MixWorkspaceOps.BootstrapTest do
  use MixWorkspaceOps.WorkspaceCase, async: false

  import ExUnit.CaptureIO

  alias MixWorkspaceOps.{Bootstrap, Overlay, Project, Resolution}

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

      assert MixWorkspaceOpsBootstrap.dep({:example_core, "~> 1.0"}, root) ==
               {:example_core, "~> 1.0"}

      assert MixWorkspaceOpsBootstrap.dep({:example_core, "~> 1.0", runtime: false}, root) ==
               {:example_core, "~> 1.0", [runtime: false]}
    end

    test "a keyword list is committed git coordinates", context do
      root = temporary_directory!(context)

      assert MixWorkspaceOpsBootstrap.dep(
               {:example_core, [github: "example-org/example_core", branch: "main"]},
               root
             ) == {:example_core, [github: "example-org/example_core", branch: "main"]}

      assert MixWorkspaceOpsBootstrap.dep(
               {:example_core,
                [github: "example-org/example_core", branch: "main", override: true]},
               root
             ) ==
               {:example_core,
                [github: "example-org/example_core", branch: "main", override: true]}
    end

    test "the inactive seam leaves Mix to validate an ordinary tuple", context do
      root = temporary_directory!(context)

      assert MixWorkspaceOpsBootstrap.dep({:example_core, :whatever}, root) ==
               {:example_core, :whatever}

      assert MixWorkspaceOpsBootstrap.dep(
               {:example_core, git: "https://example.invalid/core.git", depth: 1},
               root
             ) == {:example_core, git: "https://example.invalid/core.git", depth: 1}

      assert_raise RuntimeError, ~r/ordinary Mix dependency tuple/, fn ->
        MixWorkspaceOpsBootstrap.dep(:not_a_tuple, root)
      end
    end

    test "an active overlay removes arbitrary committed source coordinates only", context do
      root = temporary_directory!(context)

      overlay =
        write_overlay!(root, ["example_core\thex\t~> 2.0\t-"], publish: false, mode: "auto")

      System.put_env("MIX_WORKSPACE_OPS_OVERLAY", overlay)

      assert MixWorkspaceOpsBootstrap.dep(
               {:example_core,
                git: "https://example.invalid/core.git",
                ref: "abc",
                depth: 1,
                only: :test,
                runtime: false},
               root
             ) == {:example_core, "~> 2.0", [only: :test, runtime: false]}
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
               assert MixWorkspaceOpsBootstrap.dep({:example_core, "~> 1.0"}, root) ==
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
        assert MixWorkspaceOpsBootstrap.dep({:example_core, "~> 1.0"}, root) ==
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

      assert MixWorkspaceOpsBootstrap.dep({:example_core, "~> 1.0"}, root) ==
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

      assert MixWorkspaceOpsBootstrap.dep({:example_core, "~> 1.0"}, root) ==
               {:example_core, [github: "example-org/example_core"]}
    end

    test "a hex row is two elements without options and three with them", context do
      root = temporary_directory!(context)

      path =
        write_overlay!(root, [
          "example_core\thex\t~> 2.0\t-",
          "example_edge\thex\t~> 0.8.2\tonly=dev|test,runtime=false",
          "example_shape\thex\t~> 3.0\thex=shape_fork"
        ])

      System.put_env("MIX_WORKSPACE_OPS_OVERLAY", path)

      assert MixWorkspaceOpsBootstrap.dep({:example_core, "~> 1.0"}, root) ==
               {:example_core, "~> 2.0"}

      assert MixWorkspaceOpsBootstrap.dep({:example_edge, "~> 1.0"}, root) ==
               {:example_edge, "~> 0.8.2", [only: [:dev, :test], runtime: false]}

      assert MixWorkspaceOpsBootstrap.dep({:example_shape, "~> 1.0"}, root) ==
               {:example_shape, "~> 3.0", [hex: :shape_fork]}
    end

    test "call-site options win over the ones the overlay carries", context do
      root = temporary_directory!(context)
      path = write_overlay!(root, ["example_core\thex\t~> 2.0\truntime=false"])
      System.put_env("MIX_WORKSPACE_OPS_OVERLAY", path)

      assert MixWorkspaceOpsBootstrap.dep({:example_core, "~> 1.0", runtime: true}, root) ==
               {:example_core, "~> 2.0", [runtime: true]}
    end

    test "an application the overlay does not carry keeps its committed default", context do
      root = temporary_directory!(context)
      path = write_overlay!(root, ["example_core\thex\t~> 2.0\t-"])
      System.put_env("MIX_WORKSPACE_OPS_OVERLAY", path)

      assert MixWorkspaceOpsBootstrap.dep(
               {:example_edge, [github: "example-org/example_edge", branch: "main"]},
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

      assert capture_io(fn ->
               MixWorkspaceOpsBootstrap.dep({:example_core, "~> 1.0"}, first)
             end) =~
               "local path source in use for: example_core"

      assert capture_io(fn ->
               MixWorkspaceOpsBootstrap.dep({:example_core, "~> 1.0"}, first)
             end) ==
               ""

      System.argv(["run", "-e", ":ok"])

      assert capture_io(fn ->
               MixWorkspaceOpsBootstrap.dep({:example_core, "~> 1.0"}, second)
             end) ==
               ""
    end

    test "a closure with no local source carries no notice", context do
      root = temporary_directory!(context)
      path = write_overlay!(root, ["example_core\thex\t~> 2.0\t-"])
      System.put_env("MIX_WORKSPACE_OPS_OVERLAY", path)

      assert capture_io(fn ->
               MixWorkspaceOpsBootstrap.dep({:example_core, "~> 1.0"}, root)
             end) ==
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
        MixWorkspaceOpsBootstrap.dep({:example_core, "~> 1.0"}, root)
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

      assert MixWorkspaceOpsBootstrap.dep({:example_core, "~> 1.0"}, root) ==
               {:example_core, [github: "example-org/example_core", branch: "main"]}
    end

    test "reads task position, so an argument is not a publication", context do
      root = temporary_directory!(context)
      path = write_overlay!(root, ["example_core\thex\t~> 2.0\t-"], publish: false)
      System.put_env("MIX_WORKSPACE_OPS_OVERLAY", path)
      System.argv(["run", "--arg", "hex.publish"])

      assert MixWorkspaceOpsBootstrap.dep({:example_core, "~> 1.0"}, root) ==
               {:example_core, "~> 2.0"}
    end
  end

  describe "the overlay it will not read" do
    test "memoizes one verified parse for the invocation and not across VMs", context do
      root = temporary_directory!(context)
      path = write_overlay!(root, ["example_core\thex\t~> 2.0\t-"])
      System.put_env("MIX_WORKSPACE_OPS_OVERLAY", path)

      assert MixWorkspaceOpsBootstrap.dep({:example_core, "~> 1.0"}, root) ==
               {:example_core, "~> 2.0"}

      File.rm!(path)

      assert MixWorkspaceOpsBootstrap.dep({:example_core, "~> 1.0"}, root) ==
               {:example_core, "~> 2.0"}

      assert {:ok, bootstrap} = Bootstrap.materialize(Path.join(root, "operator-state"))

      expression = """
      Code.require_file(#{inspect(bootstrap)})
      MixWorkspaceOpsBootstrap.dep({:example_core, "~> 1.0"}, #{inspect(root)})
      """

      assert {output, exit_code} =
               System.cmd(System.find_executable("elixir"), ["-e", expression],
                 env: [{"MIX_WORKSPACE_OPS_OVERLAY", path}],
                 stderr_to_stdout: true
               )

      refute exit_code == 0
      assert output =~ "points to a missing overlay"
    end

    test "uses no persistent-term write in the dependency path" do
      refute Bootstrap.contents() =~ ":persistent_term.put"
      assert Bootstrap.contents() =~ ":ets.insert"
    end

    test "rejects relative overlay paths", context do
      root = temporary_directory!(context)
      System.put_env("MIX_WORKSPACE_OPS_OVERLAY", "relative.tsv")

      assert_raise RuntimeError, ~r/must contain an absolute path/, fn ->
        MixWorkspaceOpsBootstrap.dep({:example_core, "~> 1.0"}, root)
      end
    end

    test "rejects an overlay whose bytes no longer match its address", context do
      root = temporary_directory!(context)
      path = write_overlay!(root, ["example_core\thex\t~> 2.0\t-"])
      File.write!(path, File.read!(path) <> "example_edge\thex\t~> 1.0\t-\n")
      System.put_env("MIX_WORKSPACE_OPS_OVERLAY", path)

      assert_raise RuntimeError, ~r/digest mismatch/, fn ->
        MixWorkspaceOpsBootstrap.dep({:example_core, "~> 1.0"}, root)
      end
    end

    test "rejects an option it does not know and a list beyond the atom bound", context do
      root = temporary_directory!(context)
      path = write_overlay!(root, ["example_core\thex\t~> 2.0\tsauce=true"])
      System.put_env("MIX_WORKSPACE_OPS_OVERLAY", path)

      assert_raise RuntimeError, ~r/unknown Mix Workspace Ops dependency option/, fn ->
        MixWorkspaceOpsBootstrap.dep({:example_core, "~> 1.0"}, root)
      end

      names = 1..9 |> Enum.map_join("|", &"env_#{&1}")
      long = write_overlay!(root, ["example_core\thex\t~> 2.0\tonly=#{names}"])
      System.put_env("MIX_WORKSPACE_OPS_OVERLAY", long)

      assert_raise RuntimeError, ~r/invalid Mix Workspace Ops option only/, fn ->
        MixWorkspaceOpsBootstrap.dep({:example_core, "~> 1.0"}, root)
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

    # A table of valid values proves the two decoders agree about what they
    # accept and says nothing about what they refuse — which is where they
    # actually drifted: the module's reader bounded the count and the length of
    # an environment list and not its grammar, so `only=DEV` minted an atom from
    # arbitrary bytes on one side and raised inside `mix.exs` on the other.
    @refused [
      "only=DEV",
      "only=Dev",
      "only=1dev",
      "only=de-v",
      "only=dev|",
      "only=|dev",
      "only=dev||test",
      "only=",
      "targets=Host",
      "only=e1|e2|e3|e4|e5|e6|e7|e8|e9",
      "only=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "override=yes",
      "override=1",
      "runtime=",
      "unknown=true",
      "override",
      ""
    ]

    test "every options encoding round-trips through both decoders" do
      for options <- @options do
        encoded = Overlay.encode_options(options)
        assert {:ok, ^options} = Overlay.decode_options(encoded)
        assert MixWorkspaceOpsBootstrap.decode_options(encoded) == options
      end
    end

    test "both decoders refuse the same encodings" do
      for encoded <- @refused do
        assert {:error, _reason} = Overlay.decode_options(encoded),
               "the module accepted #{inspect(encoded)}"

        assert_raise RuntimeError, fn -> MixWorkspaceOpsBootstrap.decode_options(encoded) end
      end
    end
  end

  describe "mix deps.sources" do
    # The file this seam replaces defined this Mix task inside the file a
    # `mix.exs` loaded. This bootstrap is loaded into the same process by path,
    # so it can define it too — at zero cost in repository files, which is what
    # the constraint against installing code into a repository was protecting.
    test "records what the seam emitted and prints it in the settled shape", context do
      root = temporary_directory!(context)
      sibling = Path.join(root, "sibling")
      File.mkdir_p!(sibling)
      File.write!(Path.join(sibling, "mix.exs"), "def project, do: [version: \"4.5.6\"]\n")

      overlay =
        write_overlay!(root, [
          "example_core\tlocal\t#{sibling}\trevision\tdigest\t-",
          "example_edge\tgithub\texample-org/example_edge\tbranch\tmain\t-\t-",
          "example_shape\thex\t~> 2.0\toverride=true"
        ])

      System.put_env("MIX_WORKSPACE_OPS_OVERLAY", overlay)

      for app <- [:example_core, :example_edge, :example_shape],
          do: MixWorkspaceOpsBootstrap.dep({app, "~> 0.1.0"}, root)

      MixWorkspaceOpsBootstrap.dep({:example_committed, "~> 9.9"}, root)

      assert MixWorkspaceOpsBootstrap.recorded_sources(root) == [
               %{
                 app: :example_committed,
                 source: "hex",
                 location: "hex",
                 version: "~> 9.9"
               },
               %{app: :example_core, source: "local", location: sibling, version: "4.5.6"},
               %{
                 app: :example_edge,
                 source: "github",
                 location: "example-org/example_edge",
                 version: "branch main"
               },
               %{app: :example_shape, source: "hex", location: "hex", version: "~> 2.0"}
             ]

      report =
        MixWorkspaceOpsBootstrap.format_sources(MixWorkspaceOpsBootstrap.recorded_sources(root))

      assert String.split(report, "\n") == [
               "dependency sources:",
               "  example_committed -> hex (hex) -> ~> 9.9",
               "  example_core -> local (#{sibling}) -> 4.5.6",
               "  example_edge -> github (example-org/example_edge) -> branch main",
               "  example_shape -> hex (hex) -> ~> 2.0"
             ]

      assert MixWorkspaceOpsBootstrap.format_sources([]) ==
               "dependency sources: (no managed dependencies)"

      # The same shape the escript's own report prints, from the same data.
      assert Resolution.format_sources([
               %{
                 application: "example_core",
                 source: "local",
                 location: sibling,
                 version: "4.5.6"
               }
             ]) == "dependency sources:\n  example_core -> local (#{sibling}) -> 4.5.6"
    end

    test "reads a sibling version the way the escript does", context do
      root = temporary_directory!(context)

      cases = [
        {"literal", ~s|def project, do: [app: :a, version: "1.2.3"]|, "1.2.3"},
        {"attribute", ~s|@version "3.2.1"\ndef project, do: [version: @version]|, "3.2.1"},
        {"none", ~s|def project, do: [app: :a]|, nil},
        {"unparsable", ~s|def project, do: [|, nil}
      ]

      for {name, body, expected} <- cases do
        project = Path.join(root, name)
        File.mkdir_p!(project)
        File.write!(Path.join(project, "mix.exs"), body <> "\n")

        assert MixWorkspaceOpsBootstrap.declared_version(project) == expected

        escript =
          case Project.declared_version(project) do
            {:ok, version} -> version
            {:error, _reason} -> nil
          end

        assert escript == expected
      end

      assert MixWorkspaceOpsBootstrap.declared_version(Path.join(root, "absent")) == nil
    end
  end

  test "installs only an explicit absolute operator lockfile into pending Mix config", context do
    root = temporary_directory!(context)
    lockfile = Path.join(root, "state/mix.lock")
    File.mkdir_p!(Path.dirname(lockfile))
    File.write!(lockfile, "%{}\n")

    assert MixWorkspaceOpsBootstrap.install_project_options!() == :ok
    assert Mix.ProjectStack.pop_post_config(:lockfile) == nil

    System.put_env("MIX_WORKSPACE_OPS_LOCKFILE", lockfile)
    assert MixWorkspaceOpsBootstrap.install_project_options!() == :ok
    assert Mix.ProjectStack.pop_post_config(:lockfile) == lockfile

    System.put_env("MIX_WORKSPACE_OPS_LOCKFILE", "relative.lock")

    assert_raise RuntimeError, ~r/must contain an absolute path/, fn ->
      MixWorkspaceOpsBootstrap.install_project_options!()
    end
  end

  defp write_overlay!(root, rows, opts \\ []) do
    contents =
      Enum.join(
        [
          "mix_workspace_ops.overlay/v3",
          "registry_digest\tdigest",
          "selection_digest\t#{Keyword.get(opts, :selection_digest, "-")}",
          "graph_digest\tgraph",
          "mix_env\t#{Keyword.get(opts, :mix_env, "dev")}",
          "mix_target\t#{Keyword.get(opts, :mix_target, "host")}",
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
