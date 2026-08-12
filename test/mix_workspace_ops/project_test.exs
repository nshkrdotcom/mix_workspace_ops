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

  test "rejects non-application workspace roots", context do
    root = temporary_directory!(context)
    repository = initialize_repository!(Path.join(root, "alpha"))
    mix_file = Path.join(repository, "mix.exs")
    File.write!(mix_file, String.replace(File.read!(mix_file), "app: :alpha, ", "app: nil, "))

    assert {:error, :non_application_mix_project} = Project.metadata_at(repository)
  end
end
