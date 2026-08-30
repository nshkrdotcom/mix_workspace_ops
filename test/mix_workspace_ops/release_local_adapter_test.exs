defmodule MixWorkspaceOps.Release.LocalAdapterTest do
  use MixWorkspaceOps.WorkspaceCase, async: false

  import ExUnit.CaptureIO

  alias MixWorkspaceOps.Registry
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

  test "the executable preflight reaches catalog blockers", context do
    root = temporary_directory!(context)
    repository = Path.join(root, "sample_package")
    provider = Path.join(root, "provider")
    bare = Path.join(root, "remote.git")

    initialize_repository!(repository, ~s([{:provider, "~> 1.1.0"}]))
    initialize_repository!(provider)
    rewrite_version!(provider, "1.2.3")
    run!("git", ["init", "--bare", "--quiet", bare], root)
    run!("git", ["remote", "set-url", "origin", bare], repository)
    run!("git", ["push", "--quiet", "--set-upstream", "origin", "main"], repository)

    registry =
      root
      |> write_catalog!([
        catalog_repository("provider", projects: [catalog_project("provider")]),
        catalog_repository("sample_package",
          projects: [catalog_project("sample_package")],
          dependency_sources: %{"provider" => %{"hex" => "~> 1.1.0"}},
          release_chain: %{"sample_package" => []}
        )
      ])
      |> Registry.load!()
      |> then(&%{&1 | bindings: %{"provider" => provider, "sample_package" => repository}})

    release_plan = %{
      repository: repository,
      project_path: ".",
      package: "sample_package",
      version: "0.1.0",
      tag: "v0.1.0",
      default_branch: "main",
      registry: registry,
      registry_lookup: fn _package, _version -> :published end,
      release_status: fn _context -> :absent end
    }

    assert {:error, {:publish_preflight, [blocker], message}} =
             LocalAdapter.transition(:preflight, %{plan: release_plan})

    assert blocker.reason == :hex_constraint_stale
    assert message =~ "bump it to \"~> 1.2.0\""
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

  test "the executable preflight refuses an absent provider it cannot verify", context do
    root = temporary_directory!(context)
    repository = Path.join(root, "sample_package")
    bare = Path.join(root, "remote.git")
    initialize_repository!(repository, ~s([{:provider, "~> 1.2"}]))
    run!("git", ["init", "--bare", "--quiet", bare], root)
    run!("git", ["remote", "set-url", "origin", bare], repository)
    run!("git", ["push", "--quiet", "--set-upstream", "origin", "main"], repository)

    registry =
      root
      |> write_catalog!([
        catalog_repository("provider", projects: [catalog_project("provider")]),
        catalog_repository("sample_package",
          projects: [catalog_project("sample_package")],
          dependency_sources: %{"provider" => %{"hex" => "~> 1.2"}},
          release_chain: %{"sample_package" => []}
        )
      ])
      |> Registry.load!()
      |> then(
        &%{
          &1
          | bindings: %{"sample_package" => repository},
            absent_checkouts: %{"provider" => Path.join(root, "provider")}
        }
      )

    release_plan = %{
      repository: repository,
      project_path: ".",
      package: "sample_package",
      version: "0.1.0",
      tag: "v0.1.0",
      default_branch: "main",
      registry: registry,
      release_status: fn _context -> :absent end
    }

    assert {:error, {:dependency_preflight_unverified, [%{app: "provider"}]}} =
             LocalAdapter.transition(:preflight, %{plan: release_plan})
  end

  test "a failed gate reports diagnostics without adding them to the error", context do
    root = temporary_directory!(context)

    context = %{
      project: root,
      plan: %{gates: [["sh", "-c", "printf gate-diagnostic >&2; exit 19"]]}
    }

    output =
      capture_io(:stderr, fn ->
        assert {:error, {:gate_failed, "sh", ["-c", _command], 19}} =
                 LocalAdapter.transition(:gates, context)
      end)

    assert output == "gate-diagnostic"
  end

  defp run!(executable, arguments, cwd) do
    {_output, 0} = System.cmd(executable, arguments, cd: cwd, stderr_to_stdout: true)
  end

  defp git!(repository, arguments) do
    {output, 0} = System.cmd("git", arguments, cd: repository, stderr_to_stdout: true)
    String.trim(output)
  end

  defp rewrite_version!(repository, version) do
    mix_path = Path.join(repository, "mix.exs")
    contents = File.read!(mix_path) |> String.replace("0.1.0", version)
    File.write!(mix_path, contents)
  end
end
