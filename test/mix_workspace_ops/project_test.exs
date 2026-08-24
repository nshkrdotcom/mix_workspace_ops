defmodule MixWorkspaceOps.ProjectTest do
  use MixWorkspaceOps.WorkspaceCase, async: true

  alias MixWorkspaceOps.Project

  test "reads mix metadata without evaluating runtime configuration", context do
    root = temporary_directory!(context)
    repository = initialize_repository!(Path.join(root, "alpha"))
    config = Path.join(repository, "config")
    File.mkdir_p!(config)
    File.write!(Path.join(config, "runtime.exs"), "raise \"runtime config was evaluated\"\n")

    assert {:ok, metadata} = Project.metadata_at(repository)
    assert metadata.app == "alpha"
    assert metadata.version == "0.1.0"
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
end
