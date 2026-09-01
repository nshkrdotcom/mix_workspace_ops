defmodule MixWorkspaceOps.ProjectTest do
  use MixWorkspaceOps.WorkspaceCase, async: true

  alias MixWorkspaceOps.Project
  alias MixWorkspaceOps.Project.ProbeMemo

  test "reads mix metadata without evaluating runtime configuration", context do
    root = temporary_directory!(context)
    repository = initialize_repository!(Path.join(root, "alpha"))
    config = Path.join(repository, "config")
    File.mkdir_p!(config)
    File.write!(Path.join(config, "runtime.exs"), "raise \"runtime config was evaluated\"\n")

    assert {:ok, metadata} = Project.metadata_at(repository)
    assert metadata.app == "alpha"
    assert metadata.version == "0.1.0"
    assert metadata.dependency_fingerprint =~ ~r/^[0-9a-f]{64}$/
  end

  test "loads dependency metadata from a non-application umbrella root", context do
    root = temporary_directory!(context)
    repository = initialize_repository!(Path.join(root, "alpha"))

    File.write!(Path.join(repository, "mix.exs"), """
    defmodule Umbrella.MixProject do
      use Mix.Project

      def project, do: [apps_path: "apps", version: "0.1.0", deps: [{:jason, "~> 1.4"}]]
    end
    """)

    assert {:ok, metadata} = Project.metadata_at(repository)
    assert metadata.app == nil
    assert metadata.version == "0.1.0"
    assert metadata.dependencies == ["jason"]
  end

  test "uses the running toolchain when a project has a partial version file", context do
    root = temporary_directory!(context)
    repository = initialize_repository!(Path.join(root, "alpha"))
    File.write!(Path.join(repository, ".tool-versions"), "erlang 29.0.5\n")

    assert {:ok, %{app: "alpha"}} = Project.metadata_at(repository)
  end

  test "one invocation evaluates an unchanged metadata question once", context do
    root = temporary_directory!(context)
    repository = Path.join(root, "alpha")
    counter = Path.join(root, "probes")
    File.mkdir_p!(repository)

    File.write!(Path.join(repository, "mix.exs"), instrumented_mix(counter, "0.1.0"))
    memo = ProbeMemo.new()

    assert {:ok, _metadata} = Project.metadata_at(repository, probe_memo: memo)
    assert {:ok, _metadata} = Project.metadata_at(repository, probe_memo: memo)
    assert File.read!(counter) == "x"

    File.write!(Path.join(repository, "mix.exs"), instrumented_mix(counter, "0.2.0"))
    assert {:ok, %{version: "0.2.0"}} = Project.metadata_at(repository, probe_memo: memo)
    assert File.read!(counter) == "xx"
  end

  test "environment, target, and toolchain are part of the probe key", context do
    root = temporary_directory!(context)
    repository = Path.join(root, "alpha")
    counter = Path.join(root, "probes")
    File.mkdir_p!(repository)
    File.write!(Path.join(repository, "mix.exs"), instrumented_mix(counter, "0.1.0"))
    memo = ProbeMemo.new()

    assert {:ok, _base} =
             Project.metadata_at(repository, probe_memo: memo, mix_env: "dev", mix_target: "host")

    assert {:ok, _env} =
             Project.metadata_at(repository,
               probe_memo: memo,
               mix_env: "test",
               mix_target: "host"
             )

    assert {:ok, _target} =
             Project.metadata_at(repository,
               probe_memo: memo,
               mix_env: "dev",
               mix_target: "embedded"
             )

    assert {:ok, _toolchain} =
             Project.metadata_at(repository,
               probe_memo: memo,
               mix_env: "dev",
               mix_target: "host",
               toolchain: {"future", "otp", "mix"}
             )

    assert File.read!(counter) == "xxxx"

    assert {:ok, _base_again} =
             Project.metadata_at(repository, probe_memo: memo, mix_env: "dev", mix_target: "host")

    assert File.read!(counter) == "xxxx"
  end

  test "a later invocation owns no answers from the earlier one", context do
    root = temporary_directory!(context)
    repository = Path.join(root, "alpha")
    counter = Path.join(root, "probes")
    File.mkdir_p!(repository)
    File.write!(Path.join(repository, "mix.exs"), instrumented_mix(counter, "0.1.0"))

    assert {:ok, _metadata} =
             Project.metadata_at(repository, probe_memo: ProbeMemo.new())

    assert {:ok, _metadata} =
             Project.metadata_at(repository, probe_memo: ProbeMemo.new())

    assert File.read!(counter) == "xx"
  end

  test "bounded concurrent pre-warm shares one question", context do
    root = temporary_directory!(context)
    repository = initialize_repository!(Path.join(root, "alpha"))
    counter = Path.join(root, "probes")
    File.write!(Path.join(repository, "mix.exs"), instrumented_mix(counter, "0.1.0"))
    registry = load_fixture_registry!(root)
    project = registry.projects["alpha"]
    memo = ProbeMemo.new()

    assert [{"alpha", {:ok, _first}}, {"alpha", {:ok, _second}}] =
             registry
             |> Project.prewarm([project, project], memo, max_concurrency: 2)
             |> Enum.sort()

    assert File.read!(counter) == "x"
  end

  describe "declared_version/1" do
    test "reads a literal version by parsing", context do
      root = temporary_directory!(context)
      repository = initialize_repository!(Path.join(root, "alpha"))

      assert Project.declared_version(repository) == {:ok, "0.1.0"}
    end

    test "resolves the module attribute a version usually names", context do
      root = temporary_directory!(context)
      repository = Path.join(root, "alpha")
      File.mkdir_p!(repository)

      File.write!(Path.join(repository, "mix.exs"), """
      defmodule Alpha.MixProject do
        use Mix.Project

        @version "2.3.4"

        def project, do: [app: :alpha, version: @version, deps: []]
      end
      """)

      assert Project.declared_version(repository) == {:ok, "2.3.4"}
    end

    test "parses and never evaluates", context do
      root = temporary_directory!(context)
      repository = Path.join(root, "alpha")
      File.mkdir_p!(repository)

      File.write!(Path.join(repository, "mix.exs"), """
      raise "mix.exs was evaluated"

      defmodule Alpha.MixProject do
        use Mix.Project

        @version "9.9.9"

        def project, do: [app: :alpha, version: @version]
      end
      """)

      assert Project.declared_version(repository) == {:ok, "9.9.9"}
    end

    test "says so where there is no version and where there is no file", context do
      root = temporary_directory!(context)
      repository = Path.join(root, "alpha")
      File.mkdir_p!(repository)
      File.write!(Path.join(repository, "mix.exs"), "defmodule Alpha do\nend\n")

      assert {:error, {:version_not_found, _path}} = Project.declared_version(repository)

      assert {:error, {:missing_mix_exs, _path, :enoent}} =
               Project.declared_version(Path.join(root, "absent"))

      File.write!(Path.join(repository, "mix.exs"), "defmodule Alpha do\n")
      assert {:error, {:unparsable_mix_exs, _path}} = Project.declared_version(repository)
    end
  end

  defp instrumented_mix(counter, version) do
    """
    File.write!(#{inspect(counter)}, "x", [:append])

    defmodule Alpha.MixProject do
      use Mix.Project
      def project, do: [app: :alpha, version: #{inspect(version)}, deps: []]
    end
    """
  end

  defp load_fixture_registry!(root) do
    registry_path = write_registry!(root, [repository("alpha", [project("alpha")])])
    {:ok, registry} = MixWorkspaceOps.Registry.load(registry_path)
    {:ok, registry} = MixWorkspaceOps.Registry.bind(registry, root)
    registry
  end
end
