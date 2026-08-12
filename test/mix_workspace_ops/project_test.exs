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
end
