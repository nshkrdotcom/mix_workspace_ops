defmodule MixWorkspaceOps.Release.LocalAdapterTest do
  use MixWorkspaceOps.WorkspaceCase, async: false

  import ExUnit.CaptureIO

  alias MixWorkspaceOps.Registry
  alias MixWorkspaceOps.Release.{LocalAdapter, Transaction}

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

    assert {:ok, %{gate_results: [%{argv: ["sh", "-c", _], exit_code: 0}]}} =
             LocalAdapter.transition(:gates, context)
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

  test "resume verifies a published checksum and never requests a republish" do
    checksum = String.duplicate("a", 64)

    context = %{
      archive_checksum: checksum,
      plan: %{
        package: "sample_package",
        version: "1.2.3",
        registry_lookup: fn "sample_package", "1.2.3" -> {:published, checksum} end
      }
    }

    assert {:ok, %{registry_checksum: ^checksum}} =
             LocalAdapter.resume(:publish, :completed, context)

    missing = put_in(context.plan.registry_lookup, fn _package, _version -> :missing end)
    assert LocalAdapter.resume(:publish, :started, missing) == :rerun

    assert {:error, :published_release_missing} =
             LocalAdapter.resume(:publish, :completed, missing)
  end

  test "a prepared artifact is rebuilt in the detached checkout and digest-matched", context do
    root = temporary_directory!(context)
    repository = Path.join(root, "source")
    bare = Path.join(root, "remote.git")
    expected = Path.join(root, "expected-release.json")
    receipt_directory = Path.join(root, "receipt")

    initialize_prepared_repository!(repository)
    run!("git", ["init", "--bare", "--quiet", bare], root)
    run!("git", ["remote", "add", "origin", bare], repository)
    run!("git", ["push", "--quiet", "--set-upstream", "origin", "main"], repository)
    run!("elixir", ["prepare.exs"], repository)
    File.cp!(Path.join([repository, "dist", "release.json"]), expected)
    File.mkdir_p!(receipt_directory)

    plan = %{
      repository: repository,
      project_path: ".",
      package: "projected_package",
      version: "1.2.3",
      tag: "v1.2.3",
      default_branch: "main",
      gates: [["mix", "compile", "--warnings-as-errors"]],
      publisher_prefix: ["/operator/publisher"],
      prepared_artifact: %{
        expected_handoff: expected,
        prepare: ["elixir", "prepare.exs"],
        rebuilt_handoff: "dist/release.json"
      },
      release_status: fn _context -> :absent end
    }

    assert {:ok, preflight} = LocalAdapter.transition(:preflight, %{plan: plan})
    checkout_context = Map.merge(preflight, %{plan: plan, receipt_directory: receipt_directory})

    assert {:ok, rebuilt} = LocalAdapter.transition(:checkout, checkout_context)
    assert rebuilt.checkout == Path.join(receipt_directory, "checkout")
    assert rebuilt.project == Path.join([rebuilt.checkout, "dist", "project"])
    assert File.regular?(rebuilt.archive)
    assert rebuilt.source_revision == preflight.head

    assert {:ok, archive} =
             LocalAdapter.transition(:archive, Map.merge(checkout_context, rebuilt))

    assert archive.archive_checksum == rebuilt.archive_checksum
    assert archive.manifest_sha256 == rebuilt.manifest_sha256
    assert archive.project_sha256 == rebuilt.project_sha256
  end

  test "only the publisher child receives the publication credential", context do
    root = temporary_directory!(context)
    repository = Path.join(root, "sample_package")
    bare = Path.join(root, "remote.git")
    state_root = Path.join(root, "state")
    fake_bin = Path.join(root, "bin")
    log = Path.join(root, "environment.log")
    published = Path.join(root, "published")
    actual_git = System.find_executable("git")
    previous_path = System.get_env("PATH")
    previous_key = System.get_env("HEX_API_KEY")

    initialize_repository!(repository)
    run!("git", ["init", "--bare", "--quiet", bare], root)
    run!("git", ["remote", "set-url", "origin", bare], repository)
    run!("git", ["push", "--quiet", "--set-upstream", "origin", "main"], repository)
    File.mkdir_p!(fake_bin)

    executable!(
      Path.join(fake_bin, "git"),
      """
      #!/bin/sh
      printf 'git|%s|%s\\n' "$HEX_API_KEY" "$*" >> #{shell_quote(log)}
      exec #{shell_quote(actual_git)} "$@"
      """
    )

    executable!(
      Path.join(fake_bin, "mix"),
      """
      #!/bin/sh
      printf 'archive|%s|%s\\n' "$HEX_API_KEY" "$*" >> #{shell_quote(log)}
      printf 'archive bytes\\n' > sample_package-0.1.0.tar
      """
    )

    gate = Path.join(fake_bin, "gate")

    executable!(
      gate,
      """
      #!/bin/sh
      printf 'gate|%s|%s\\n' "$HEX_API_KEY" "$*" >> #{shell_quote(log)}
      """
    )

    publisher = Path.join(fake_bin, "publisher")

    executable!(
      publisher,
      """
      #!/bin/sh
      printf 'publish|%s|%s\\n' "$HEX_API_KEY" "$*" >> #{shell_quote(log)}
      touch #{shell_quote(published)}
      """
    )

    System.put_env("PATH", fake_bin <> ":" <> previous_path)
    System.put_env("HEX_API_KEY", "publication-sentinel")

    on_exit(fn ->
      System.put_env("PATH", previous_path)

      if previous_key,
        do: System.put_env("HEX_API_KEY", previous_key),
        else: System.delete_env("HEX_API_KEY")
    end)

    archive =
      Path.join([
        state_root,
        "releases",
        "credential-boundary",
        "checkout",
        "sample_package-0.1.0.tar"
      ])

    lookup = fn _package, _version ->
      if File.regular?(published) do
        checksum =
          archive
          |> File.read!()
          |> then(&:crypto.hash(:sha256, &1))
          |> Base.encode16(case: :lower)

        {:published, checksum}
      else
        :missing
      end
    end

    plan = %{
      repository: repository,
      project_path: ".",
      package: "sample_package",
      version: "0.1.0",
      tag: "v0.1.0",
      default_branch: "main",
      gates: [[gate]],
      publisher_prefix: [publisher],
      registry_lookup: lookup
    }

    assert {:ok, _result} =
             Transaction.run(plan, LocalAdapter,
               state_root: state_root,
               transaction_id: "credential-boundary"
             )

    lines = log |> File.read!() |> String.split("\n", trim: true)
    assert Enum.count(lines, &String.starts_with?(&1, "publish|publication-sentinel|")) == 1

    refute Enum.any?(lines, fn line ->
             not String.starts_with?(line, "publish|") and
               String.contains?(line, "publication-sentinel")
           end)
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

  defp initialize_prepared_repository!(repository) do
    File.mkdir_p!(repository)

    File.write!(
      Path.join(repository, "mix.exs"),
      """
      defmodule Source.MixProject do
        use Mix.Project
        def project, do: [app: :source, version: "0.1.0"]
      end
      """
    )

    File.write!(Path.join(repository, "manifest.txt"), "projection contract\n")
    File.write!(Path.join(repository, ".gitignore"), "/dist/\n")

    File.cp!(
      Path.expand("../fixtures/release/prepare.fixture", __DIR__),
      Path.join(repository, "prepare.exs")
    )

    run!("git", ["init", "--quiet", "--initial-branch=main"], repository)
    run!("git", ["config", "user.email", "test@example.invalid"], repository)
    run!("git", ["config", "user.name", "Test"], repository)
    run!("git", ["add", "."], repository)
    run!("git", ["commit", "--quiet", "-m", "prepared source"], repository)
  end

  defp executable!(path, contents) do
    File.write!(path, contents)
    File.chmod!(path, 0o700)
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
