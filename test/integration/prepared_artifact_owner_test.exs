defmodule MixWorkspaceOps.Integration.PreparedArtifactOwnerTest do
  use MixWorkspaceOps.WorkspaceCase, async: false

  @moduletag timeout: 600_000

  alias MixWorkspaceOps.Release.{LocalAdapter, PreparedArtifact, Receipt, Transaction}

  @source_environment "MWO_PREPARED_ARTIFACT_SOURCE"
  @manifest "test/fixtures/library_bundle/packaging/weld/fixture_bundle.exs"

  if System.get_env(@source_environment) do
    test "rebuilds a real owner projection and completes through a fake registry", context do
      root = temporary_directory!(context)
      upstream = System.fetch_env!(@source_environment) |> Path.expand()
      repository = Path.join(root, "source")
      remote = Path.join(root, "remote.git")
      state_root = Path.join(root, "state")
      expected = Path.join(root, "expected-release.json")
      published = Path.join(root, "published")
      publisher = Path.join(root, "publisher")

      run!("git", ["clone", "--quiet", "--shared", upstream, repository], root)
      run!("git", ["init", "--bare", "--quiet", remote], root)
      run!("git", ["remote", "set-url", "origin", remote], repository)
      run!("git", ["config", "user.email", "release-proof@example.invalid"], repository)
      run!("git", ["config", "user.name", "Release Proof"], repository)

      manifest = Path.join(repository, @manifest)

      File.write!(
        manifest,
        manifest
        |> File.read!()
        |> String.replace("verify: [\n", "verify: [\n        hex_publish: false,\n",
          global: false
        )
      )

      run!("git", ["add", @manifest], repository)

      run!(
        "git",
        ["commit", "--quiet", "-m", "Disable authenticated fixture dry-run"],
        repository
      )

      run!("git", ["push", "--quiet", "--set-upstream", "origin", "main"], repository)

      run!(
        "mix",
        ["do", "deps.get,", "weld.release.prepare", @manifest],
        repository,
        300_000
      )

      [release_json] =
        Path.wildcard(
          Path.join([
            repository,
            "test/fixtures/library_bundle/dist/release_bundles/fixture_bundle/*/release.json"
          ])
        )

      File.cp!(release_json, expected)

      File.write!(
        publisher,
        """
        #!/bin/sh
        test "$HEX_API_KEY" = "integration-publication-sentinel"
        touch #{shell_quote(published)}
        """
      )

      File.chmod!(publisher, 0o700)

      previous_key = System.get_env("HEX_API_KEY")
      System.put_env("HEX_API_KEY", "integration-publication-sentinel")

      on_exit(fn ->
        if previous_key,
          do: System.put_env("HEX_API_KEY", previous_key),
          else: System.delete_env("HEX_API_KEY")
      end)

      checkout =
        Path.join([state_root, "releases", "prepared-owner", "checkout"])

      lookup = fn _package, _version ->
        if File.regular?(published) do
          [archive] =
            Path.wildcard(
              Path.join([
                checkout,
                "test/fixtures/library_bundle/dist/release_bundles/fixture_bundle/*",
                "fixture_bundle-0.1.0.tar"
              ])
            )

          {:published, sha256_file(archive)}
        else
          :missing
        end
      end

      plan = %{
        repository: repository,
        project_path: ".",
        package: "fixture_bundle",
        version: "0.1.0",
        tag: "fixture_bundle-v0.1.0",
        default_branch: "main",
        gates: [["/usr/bin/true"]],
        publisher_prefix: [publisher],
        prepared_artifact: %{
          expected_handoff: expected,
          prepare: ["mix", "do", "deps.get,", "weld.release.prepare", @manifest],
          rebuilt_handoff:
            "test/fixtures/library_bundle/dist/release_bundles/fixture_bundle/" <>
              Path.basename(Path.dirname(release_json)) <> "/release.json"
        },
        registry_lookup: lookup
      }

      descriptor = %{
        package: plan.package,
        version: plan.version,
        tag: plan.tag,
        repository: plan.repository,
        gates: plan.gates,
        prepared_artifact: plan.prepared_artifact
      }

      release_plan_digest = String.duplicate("a", 64)
      registry_digest = String.duplicate("b", 64)

      result =
        case Transaction.run(plan, LocalAdapter,
               state_root: state_root,
               transaction_id: "prepared-owner",
               descriptor: descriptor,
               release_plan_digest: release_plan_digest,
               registry_digest: registry_digest
             ) do
          {:ok, result} ->
            result

          {:error, reason} ->
            rebuilt_project =
              checkout
              |> Path.join(plan.prepared_artifact.rebuilt_handoff)
              |> Path.dirname()
              |> Path.join("project")

            flunk(
              "release failed: #{inspect(reason)}\n" <>
                prepared_tree_diff(
                  Path.join(Path.dirname(release_json), "project"),
                  rebuilt_project
                )
            )
        end

      receipt = File.read!(result.receipt)
      refute receipt =~ "integration-publication-sentinel"
      assert File.regular?(published)

      assert {:ok, expected_artifact} = PreparedArtifact.load(expected)
      assert {:ok, events} = Receipt.read(result.receipt)

      assert %{
               "evidence" => %{
                 "descriptor" => stored_descriptor,
                 "descriptor_digest" => descriptor_digest,
                 "release_plan_digest" => ^release_plan_digest,
                 "registry_digest" => ^registry_digest
               }
             } = hd(events)

      assert stored_descriptor["prepared_artifact"]["expected_handoff"] == expected
      assert descriptor_digest =~ ~r/^[0-9a-f]{64}$/

      checkout_evidence = succeeded_evidence(events, "checkout")
      assert checkout_evidence["source_revision"] == expected_artifact.source_revision
      assert checkout_evidence["manifest_sha256"] == expected_artifact.manifest_sha256
      assert checkout_evidence["project_sha256"] == expected_artifact.project_sha256
      assert checkout_evidence["archive_checksum"] == expected_artifact.archive_sha256

      assert succeeded_evidence(events, "gates")["gate_results"] == [
               %{"argv" => ["/usr/bin/true"], "exit_code" => 0}
             ]

      assert succeeded_evidence(events, "verify")["registry_checksum"] ==
               expected_artifact.archive_sha256

      assert git!(repository, ["rev-parse", "refs/tags/fixture_bundle-v0.1.0"]) ==
               git!(repository, ["rev-parse", "HEAD"])

      assert git!(repository, [
               "ls-remote",
               "--tags",
               "origin",
               "refs/tags/fixture_bundle-v0.1.0"
             ]) =~ "refs/tags/fixture_bundle-v0.1.0"
    end
  else
    @tag skip: "set #{@source_environment} to run the cross-repository projection proof"
    test "prepared-artifact owner integration source is explicitly supplied", do: :ok
  end

  defp run!(executable, arguments, cwd, timeout \\ 120_000) do
    task =
      Task.async(fn -> System.cmd(executable, arguments, cd: cwd, stderr_to_stdout: true) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> output
      {:ok, {output, status}} -> flunk("#{executable} exited #{status}:\n#{output}")
      nil -> flunk("#{executable} timed out")
    end
  end

  defp git!(repository, arguments) do
    {output, 0} = System.cmd("git", arguments, cd: repository, stderr_to_stdout: true)
    String.trim(output)
  end

  defp sha256_file(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp succeeded_evidence(events, transition) do
    events
    |> Enum.find(&(&1["transition"] == transition and &1["status"] == "succeeded"))
    |> Map.fetch!("evidence")
  end

  defp prepared_tree_diff(expected, rebuilt) do
    expected_files = tree_files(expected)
    rebuilt_files = tree_files(rebuilt)

    expected_files
    |> Map.keys()
    |> Enum.concat(Map.keys(rebuilt_files))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.filter(&(Map.get(expected_files, &1) != Map.get(rebuilt_files, &1)))
    |> Enum.map_join("\n", fn path ->
      "#{path}: expected=#{inspect(Map.get(expected_files, path))} " <>
        "rebuilt=#{inspect(Map.get(rebuilt_files, path))}"
    end)
  end

  defp tree_files(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Map.new(fn path -> {Path.relative_to(path, root), sha256_file(path)} end)
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
