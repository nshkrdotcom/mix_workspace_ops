defmodule MixWorkspaceOps.Integration.SharedRuntimeCacheTest do
  use MixWorkspaceOps.WorkspaceCase, async: false

  alias MixWorkspaceOps.{Bootstrap, GitCache, Runtime}

  test "Mix obtains a Git dependency from the retained transport mirror after origin disappears",
       context do
    root = temporary_directory!(context)
    state_root = Path.join(root, "state")
    source = Path.join(root, "git_source")
    origin = Path.join(root, "git_origin.git")
    consumer = Path.join(root, "git_consumer")

    File.mkdir_p!(Path.join(source, "lib"))
    File.write!(Path.join(source, "mix.exs"), project_file("git_dep", "[]"))
    File.write!(Path.join(source, "lib/git_dep.ex"), "defmodule GitDep, do: def(value, do: :git)\n")
    git!(source, ["init", "--quiet", "--initial-branch=main"])
    git!(source, ["config", "user.name", "MWO Test"])
    git!(source, ["config", "user.email", "mwo@example.invalid"])
    git!(source, ["add", "."])
    git!(source, ["commit", "--quiet", "-m", "git dependency"])
    commit = git!(source, ["rev-parse", "HEAD"]) |> String.trim()
    git!(root, ["clone", "--quiet", "--bare", source, origin])

    object = %{app: "git_dep", remote: origin, commit: commit, options: [ref: commit]}
    assert {:ok, %{status: :miss}} = GitCache.ensure(state_root, object)
    File.rename!(origin, origin <> ".offline")

    File.mkdir_p!(Path.join(consumer, "lib"))

    File.write!(
      Path.join(consumer, "mix.exs"),
      """
      if bootstrap = System.get_env("MIX_WORKSPACE_OPS_BOOTSTRAP"), do: Code.require_file(bootstrap)

      defmodule GitConsumer.MixProject do
        use Mix.Project
        def project do
          [
            app: :git_consumer,
            version: "0.1.0",
            deps: [{:git_dep, git: #{inspect(origin)}, ref: #{inspect(commit)}}]
          ]
        end
      end
      """
    )

    lock = inspect(%{git_dep: {:git, origin, commit, [ref: commit]}}) <> "\n"
    File.write!(Path.join(consumer, "mix.lock"), lock)
    {:ok, bootstrap} = Bootstrap.materialize(state_root)

    assert {:ok, runtime} =
             Runtime.prepare(
               state_root,
               digest("git-consumer"),
               lock,
               runtime_opts(consumer, project_identity: "git_consumer", prepare_objects: true)
             )

    assert [%{status: :hit, network: false}] = runtime.report.cache_objects.git

    output =
      mix!(consumer, ["deps.get"], [
        {"MIX_WORKSPACE_OPS_BOOTSTRAP", bootstrap},
        {"ERL_AFLAGS", "+S 2:2"} | runtime.env
      ])

    assert output =~ "* Getting git_dep"
    checkout = Path.join(runtime.report.deps_path, "git_dep")
    assert File.dir?(Path.join(checkout, ".git"))
    assert String.trim(git!(checkout, ["remote", "get-url", "origin"])) == origin
    assert String.trim(git!(checkout, ["rev-parse", "HEAD"])) == commit
    refute File.exists?(Path.join(consumer, "deps"))
    refute File.exists?(Path.join(consumer, "_build"))
    assert File.read!(Path.join(consumer, "mix.lock")) == lock
    assert {:ok, %{lock_mutated: false}} = Runtime.finish(runtime.handle)
    assert :ok = Runtime.release(runtime.handle)
  end

  test "ordinary Mix remains standalone when no MWO environment is present", context do
    root = temporary_directory!(context)
    dependency = Path.join(root, "standalone_dep")
    consumer = Path.join(root, "standalone_consumer")
    File.mkdir_p!(Path.join(dependency, "lib"))
    File.mkdir_p!(Path.join(consumer, "lib"))

    File.write!(Path.join(dependency, "mix.exs"), project_file("standalone_dep", "[]"))
    File.write!(Path.join(dependency, "lib/standalone_dep.ex"), "defmodule StandaloneDep, do: :ok\n")

    File.write!(
      Path.join(consumer, "mix.exs"),
      project_file("standalone_consumer", ~s|[{:standalone_dep, path: "../standalone_dep"}]|)
    )

    output = mix!(consumer, ["compile"], unmanaged_environment())
    assert output =~ "Generated standalone_consumer app"
    assert File.dir?(Path.join(consumer, "_build"))
  end

  defp project_file(app, deps) do
    module = app |> String.split("_") |> Enum.map_join(&String.capitalize/1)

    """
    defmodule #{module}.MixProject do
      use Mix.Project
      def project, do: [app: :#{app}, version: "0.1.0", deps: #{deps}]
    end
    """
  end

  defp runtime_opts(root, extra) do
    Keyword.merge(
      [
        ownership: :managed,
        target_head: String.duplicate("1", 40),
        target_source_digest: digest("source"),
        binding_root: root,
        mix_env: "dev",
        mix_target: "host",
        archives_source: nil
      ],
      extra
    )
  end

  defp unmanaged_environment do
    for name <- [
          "MIX_WORKSPACE_OPS_BOOTSTRAP",
          "MIX_WORKSPACE_OPS_OVERLAY",
          "MIX_WORKSPACE_OPS_LOCKFILE",
          "MIX_DEPS_PATH",
          "MIX_BUILD_PATH"
        ],
        do: {name, nil}
  end

  defp mix!(root, args, env) do
    case System.cmd("mix", args, cd: root, env: env, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> flunk("mix #{Enum.join(args, " ")} exited #{status}:\n#{output}")
    end
  end

  defp git!(root, args) do
    case System.cmd("git", args, cd: root, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> flunk("git #{inspect(args)} exited #{status}:\n#{output}")
    end
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
