defmodule MixWorkspaceOps.Release.LocalAdapterTest do
  use MixWorkspaceOps.WorkspaceCase, async: false

  alias MixWorkspaceOps.Release.LocalAdapter

  test "Hex requests identify the release client" do
    assert [{~c"user-agent", user_agent}] = LocalAdapter.hex_request_headers()
    assert List.starts_with?(user_agent, ~c"mix_workspace_ops/")
  end

  test "preflight requires the exact clean pushed package commit", context do
    root = temporary_directory!(context)
    repository = Path.join(root, "sample_package")
    bare = Path.join(root, "remote.git")
    initialize_repository!(repository)
    run!("git", ["init", "--bare", "--quiet", bare], root)
    run!("git", ["remote", "set-url", "origin", bare], repository)
    run!("git", ["push", "--quiet", "--set-upstream", "origin", "main"], repository)

    context = %{
      plan: %{
        repository: repository,
        project_path: ".",
        package: "sample_package",
        version: "0.1.0",
        tag: "v0.1.0",
        default_branch: "main",
        release_status: fn _context -> :absent end
      }
    }

    assert {:ok, evidence} = LocalAdapter.transition(:preflight, context)
    assert evidence.head == git!(repository, ["rev-parse", "HEAD"])

    File.write!(Path.join(repository, "uncommitted.txt"), "dirty\n")
    assert {:error, :dirty_worktree} = LocalAdapter.transition(:preflight, context)
  end

  test "release gates cannot inherit ambient Hex credentials", context do
    root = temporary_directory!(context)
    project = Path.join(root, "package")
    File.mkdir_p!(project)

    previous = System.get_env("HEX_API_KEY")
    System.put_env("HEX_API_KEY", "must-not-reach-gates")

    on_exit(fn ->
      if previous,
        do: System.put_env("HEX_API_KEY", previous),
        else: System.delete_env("HEX_API_KEY")
    end)

    context = %{
      project: project,
      plan: %{gates: [["sh", "-c", "test -z \"$HEX_API_KEY\""]]}
    }

    assert {:ok, %{}} = LocalAdapter.transition(:gates, context)
  end

  defp run!(executable, arguments, cwd) do
    {_output, 0} = System.cmd(executable, arguments, cd: cwd, stderr_to_stdout: true)
  end

  defp git!(repository, arguments) do
    {output, 0} = System.cmd("git", arguments, cd: repository, stderr_to_stdout: true)
    String.trim(output)
  end
end
