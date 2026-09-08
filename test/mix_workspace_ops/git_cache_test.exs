defmodule MixWorkspaceOps.GitCacheTest do
  use MixWorkspaceOps.WorkspaceCase, async: true

  alias MixWorkspaceOps.GitCache

  test "a mirror retains commits while a moving branch adds another", context do
    root = temporary_directory!(context)
    source = Path.join(root, "source")
    origin = Path.join(root, "origin.git")
    state_root = Path.join(root, "state")
    File.mkdir_p!(source)
    git!(source, ["init", "--quiet"])
    git!(source, ["config", "user.name", "P9Pre"])
    git!(source, ["config", "user.email", "p9pre@example.invalid"])

    first = commit!(source, "value.txt", "one\n", "one")
    second = commit!(source, "value.txt", "two\n", "two")
    git!(source, ["branch", "-M", "main"])
    git!(root, ["clone", "--quiet", "--bare", source, origin])

    assert {:ok, first_report} = GitCache.ensure(state_root, object(origin, first))
    assert first_report.status == :miss
    assert first_report.network
    assert is_integer(first_report.duration_ms)
    assert {:ok, second_report} = GitCache.ensure(state_root, object(origin, second))
    assert second_report.status == :hit
    refute second_report.network
    assert first_report.mirror == second_report.mirror

    git!(source, ["checkout", "--quiet", "--orphan", "rewritten"])
    git!(source, ["rm", "--quiet", "-rf", "."])
    third = commit!(source, "value.txt", "three\n", "rewritten history")
    git!(source, ["branch", "-M", "main"])
    git!(source, ["push", "--quiet", "--force", origin, "main"])

    assert {:ok, third_report} = GitCache.ensure(state_root, object(origin, third))
    assert third_report.status == :refreshed
    git!(root, ["--git-dir", third_report.mirror, "gc", "--prune=now"])

    for commit <- [first, second, third] do
      assert {_output, 0} =
               System.cmd("git", ["--git-dir", third_report.mirror, "cat-file", "-e", commit])

      assert String.trim(
               git!(root, [
                 "--git-dir",
                 third_report.mirror,
                 "rev-parse",
                 "refs/mix-workspace-ops/commits/#{commit}"
               ])
             ) == commit
    end
  end

  test "parallel consumers create one missing mirror", context do
    root = temporary_directory!(context)
    source = Path.join(root, "source")
    origin = Path.join(root, "origin.git")
    state_root = Path.join(root, "state")
    File.mkdir_p!(source)
    git!(source, ["init", "--quiet"])
    git!(source, ["config", "user.name", "P9Pre"])
    git!(source, ["config", "user.email", "p9pre@example.invalid"])
    commit = commit!(source, "value.txt", "one\n", "one")
    git!(root, ["clone", "--quiet", "--bare", source, origin])
    object = object(origin, commit)

    tasks = for _index <- 1..6, do: Task.async(fn -> GitCache.ensure(state_root, object) end)
    reports = Enum.map(tasks, &Task.await(&1, 10_000))

    assert Enum.count(reports, &match?({:ok, %{status: :miss}}, &1)) == 1
    assert Enum.count(reports, &match?({:ok, %{status: :hit}}, &1)) == 5
  end

  test "an unlocked branch source is resolved and mirrored before Mix receives it", context do
    root = temporary_directory!(context)
    source = Path.join(root, "source")
    origin = Path.join(root, "origin.git")
    state_root = Path.join(root, "state")
    memo = :ets.new(__MODULE__, [:set, :public])
    File.mkdir_p!(source)
    git!(source, ["init", "--quiet"])
    git!(source, ["config", "user.name", "P9"])
    git!(source, ["config", "user.email", "p9@example.invalid"])
    commit = commit!(source, "value.txt", "one\n", "one")
    git!(source, ["branch", "-M", "main"])
    git!(root, ["clone", "--quiet", "--bare", source, origin])

    assert {:ok, report} =
             GitCache.ensure_source(
               state_root,
               %{
                 app: "private_dep",
                 remote: origin,
                 revision: {"branch", "main"}
               },
               memo: memo
             )

    assert report.commit == commit
    assert report.status == :miss

    assert GitCache.environment([report]) |> Map.new() |> Map.fetch!("GIT_CONFIG_VALUE_0") ==
             origin

    offline = origin <> ".offline"
    File.rename!(origin, offline)

    assert {:ok, cached} =
             GitCache.ensure_source(
               state_root,
               %{
                 app: "private_dep",
                 remote: origin,
                 revision: {"branch", "main"}
               },
               memo: memo
             )

    assert cached.status == :hit
    assert cached.network == false
    assert cached.duration_ms == 0
  end

  test "URL rewriting points at the mirror without changing the declared remote" do
    reports = [
      %{
        remote: "https://example.invalid/owner/repo.git",
        mirror: "/operator/cache/repo.git"
      }
    ]

    assert GitCache.environment(reports) == [
             {"GIT_CONFIG_COUNT", "1"},
             {"GIT_CONFIG_KEY_0", "url.file:///operator/cache/repo.git.insteadOf"},
             {"GIT_CONFIG_VALUE_0", "https://example.invalid/owner/repo.git"}
           ]
  end

  test "a malformed mirror is quarantined and rebuilt", context do
    root = temporary_directory!(context)
    source = Path.join(root, "source")
    origin = Path.join(root, "origin.git")
    state_root = Path.join(root, "state")
    File.mkdir_p!(source)
    git!(source, ["init", "--quiet"])
    git!(source, ["config", "user.name", "P9Pre"])
    git!(source, ["config", "user.email", "p9pre@example.invalid"])
    commit = commit!(source, "value.txt", "one\n", "one")
    git!(root, ["clone", "--quiet", "--bare", source, origin])
    object = object(origin, commit)

    assert {:ok, report} = GitCache.ensure(state_root, object)
    File.write!(Path.join(report.mirror, "mwo-mirror.json"), "not json")

    assert {:ok, repaired} = GitCache.ensure(state_root, object)
    assert repaired.status == :repaired
    assert File.dir?(repaired.quarantine.path)
  end

  test "broken Git internals are quarantined rather than mistaken for a missing commit",
       context do
    root = temporary_directory!(context)
    source = Path.join(root, "source")
    origin = Path.join(root, "origin.git")
    state_root = Path.join(root, "state")
    File.mkdir_p!(source)
    git!(source, ["init", "--quiet"])
    git!(source, ["config", "user.name", "P9Pre"])
    git!(source, ["config", "user.email", "p9pre@example.invalid"])
    commit = commit!(source, "value.txt", "one\n", "one")
    git!(root, ["clone", "--quiet", "--bare", source, origin])
    object = object(origin, commit)

    assert {:ok, report} = GitCache.ensure(state_root, object)
    File.write!(Path.join(report.mirror, "config"), "[invalid\n")

    assert {:ok, repaired} = GitCache.ensure(state_root, object)
    assert repaired.status == :repaired
    assert repaired.quarantine.reason |> inspect() =~ "git_mirror_inspection"
    assert File.dir?(repaired.quarantine.path)
  end

  test "a commit absent after refresh is refused by remote and commit", context do
    root = temporary_directory!(context)
    source = Path.join(root, "source")
    origin = Path.join(root, "origin.git")
    state_root = Path.join(root, "state")
    File.mkdir_p!(source)
    git!(source, ["init", "--quiet"])
    git!(source, ["config", "user.name", "P9Pre"])
    git!(source, ["config", "user.email", "p9pre@example.invalid"])
    present = commit!(source, "value.txt", "one\n", "one")
    git!(root, ["clone", "--quiet", "--bare", source, origin])
    assert {:ok, _report} = GitCache.ensure(state_root, object(origin, present))

    missing = String.duplicate("f", 40)

    assert GitCache.ensure(state_root, object(origin, missing)) ==
             {:error, {:git_commit_unavailable, origin, missing}}
  end

  test "one failed exact request is not retried within an invocation", context do
    root = temporary_directory!(context)
    state_root = Path.join(root, "state")
    missing_origin = Path.join(root, "missing.git")
    missing_commit = String.duplicate("f", 40)
    memo = :ets.new(__MODULE__, [:set, :public])
    request = object(missing_origin, missing_commit)

    first = GitCache.ensure(state_root, request, memo: memo)
    File.mkdir_p!(missing_origin)
    second = GitCache.ensure(state_root, request, memo: memo)

    assert match?({:error, _reason}, first)
    assert second == first
  end

  test "a mirror manifest cannot be swapped to another remote identity", context do
    root = temporary_directory!(context)
    source = Path.join(root, "source")
    origin = Path.join(root, "origin.git")
    state_root = Path.join(root, "state")
    File.mkdir_p!(source)
    git!(source, ["init", "--quiet"])
    git!(source, ["config", "user.name", "P9Pre"])
    git!(source, ["config", "user.email", "p9pre@example.invalid"])
    commit = commit!(source, "value.txt", "one\n", "one")
    git!(root, ["clone", "--quiet", "--bare", source, origin])
    object = object(origin, commit)

    assert {:ok, report} = GitCache.ensure(state_root, object)

    File.write!(
      Path.join(report.mirror, "mwo-mirror.json"),
      :json.encode(%{
        schema: "mix_workspace_ops.git_mirror/v1",
        remote_identity: String.duplicate("0", 64)
      })
    )

    assert {:ok, repaired} = GitCache.ensure(state_root, object)
    assert repaired.status == :repaired
    assert repaired.quarantine.reason |> inspect() =~ "git_mirror_identity"
  end

  test "equivalent local URL spellings share one mirror identity", context do
    root = temporary_directory!(context)
    source = Path.join(root, "source")
    origin = Path.join(root, "origin.git")
    state_root = Path.join(root, "state")
    File.mkdir_p!(source)
    git!(source, ["init", "--quiet"])
    git!(source, ["config", "user.name", "P9Pre"])
    git!(source, ["config", "user.email", "p9pre@example.invalid"])
    commit = commit!(source, "value.txt", "one\n", "one")
    git!(root, ["clone", "--quiet", "--bare", source, origin])

    assert {:ok, path_report} = GitCache.ensure(state_root, object(origin, commit))

    assert {:ok, url_report} =
             GitCache.ensure(state_root, object("file://" <> origin, commit))

    assert path_report.remote_identity == url_report.remote_identity
    assert path_report.mirror == url_report.mirror
    assert url_report.status == :hit
  end

  test "transport credentials are neither repository identity nor report content", context do
    root = temporary_directory!(context)
    source = Path.join(root, "source")
    origin = Path.join(root, "origin.git")
    state = Path.join(root, "state")
    memo = :ets.new(__MODULE__, [:set, :public])
    initialize_repository!(source)
    commit = commit!(source, "value", "one", "first")
    git!(root, ["clone", "--quiet", "--bare", source, origin])

    first_remote = "https://first-credential@example.invalid/owner/repo.git?access=one"
    second_remote = "https://second-credential@example.invalid/owner/repo.git?access=two"

    transport_env = [
      {"GIT_CONFIG_COUNT", "1"},
      {"GIT_CONFIG_KEY_0", "url.file://#{origin}.insteadOf"},
      {"GIT_CONFIG_VALUE_0", first_remote}
    ]

    assert {:ok, first} =
             GitCache.ensure(state, object(first_remote, commit), env: transport_env, memo: memo)

    assert {:ok, second} = GitCache.ensure(state, object(second_remote, commit), memo: memo)

    assert first.remote == "https://example.invalid/owner/repo.git"
    assert second.remote == first.remote
    assert second.mirror == first.mirror
    refute first.remote =~ "credential"

    persisted_origin =
      git!(root, ["--git-dir", first.mirror, "config", "--get", "remote.origin.url"])

    assert String.trim(persisted_origin) == first.remote
    refute persisted_origin =~ "credential"
    refute persisted_origin =~ "access="

    assert GitCache.environment([second])
           |> Map.new()
           |> Map.fetch!("GIT_CONFIG_VALUE_0") == second_remote
  end

  test "Git failures redact URI and SCP-style transport credentials", context do
    root = temporary_directory!(context)
    state = Path.join(root, "state")
    command = Path.join(root, "failing-git")
    File.write!(command, "#!/bin/sh\nprintf '%s\\n' \"$*\" >&2\nexit 2\n")
    File.chmod!(command, 0o700)

    for remote <- [
          "https://secret-token@example.invalid/repo.git?access=hidden",
          "secret-token@example.invalid:private/repo.git"
        ] do
      assert {:error, reason} =
               GitCache.ensure_source(
                 state,
                 %{app: "sample", remote: remote, revision: {"branch", "main"}},
                 command: command
               )

      rendered = inspect(reason)
      refute rendered =~ "secret-token"
      refute rendered =~ "access=hidden"
    end
  end

  defp object(remote, commit), do: %{remote: remote, commit: commit, options: []}

  defp commit!(repository, path, contents, message) do
    File.write!(Path.join(repository, path), contents)
    git!(repository, ["add", path])
    git!(repository, ["commit", "--quiet", "-m", message])
    git!(repository, ["rev-parse", "HEAD"]) |> String.trim()
  end

  defp git!(directory, args) do
    case System.cmd("git", args, cd: directory, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> flunk("git #{inspect(args)} exited #{status}: #{output}")
    end
  end
end
