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

    File.write!(
      Path.join(source, "lib/git_dep.ex"),
      "defmodule GitDep, do: def(value, do: :git)\n"
    )

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

  test "an allowed deps.get lock update is reused by the next managed command", context do
    root = temporary_directory!(context)
    state_root = Path.join(root, "state")
    source = Path.join(root, "git_source")
    origin = Path.join(root, "git_origin.git")
    consumer = Path.join(root, "consumer")

    File.mkdir_p!(Path.join(source, "lib"))
    File.write!(Path.join(source, "mix.exs"), project_file("git_dep", "[]"))

    File.write!(
      Path.join(source, "lib/git_dep.ex"),
      "defmodule GitDep, do: def(value, do: :git)\n"
    )

    git!(source, ["init", "--quiet", "--initial-branch=main"])
    git!(source, ["config", "user.name", "MWO Test"])
    git!(source, ["config", "user.email", "mwo@example.invalid"])
    git!(source, ["add", "."])
    git!(source, ["commit", "--quiet", "-m", "git dependency"])
    commit = git!(source, ["rev-parse", "HEAD"]) |> String.trim()
    git!(root, ["clone", "--quiet", "--bare", source, origin])

    File.mkdir_p!(Path.join(consumer, "lib"))

    File.write!(
      Path.join(consumer, "mix.exs"),
      """
      if bootstrap = System.get_env("MIX_WORKSPACE_OPS_BOOTSTRAP"), do: Code.require_file(bootstrap)

      defmodule LockReuseConsumer.MixProject do
        use Mix.Project

        def project do
          [
            app: :lock_reuse_consumer,
            version: "0.1.0",
            deps: [{:git_dep, git: #{inspect(origin)}, ref: #{inspect(commit)}}]
          ]
        end
      end
      """
    )

    File.write!(
      Path.join(consumer, "lib/lock_reuse_consumer.ex"),
      "defmodule LockReuseConsumer, do: def(value, do: GitDep.value())\n"
    )

    source_lock = "%{}\n"
    File.write!(Path.join(consumer, "mix.lock"), source_lock)
    {:ok, bootstrap} = Bootstrap.materialize(state_root)

    assert {:ok, first} =
             Runtime.prepare(
               state_root,
               digest("lock-reuse-consumer"),
               source_lock,
               runtime_opts(consumer,
                 project_identity: "lock_reuse_consumer",
                 allow_lock_mutation: true
               )
             )

    first_env = [{"MIX_WORKSPACE_OPS_BOOTSTRAP", bootstrap}, {"ERL_AFLAGS", "+S 2:2"} | first.env]
    assert mix!(consumer, ["deps.get"], first_env) =~ "* Getting git_dep"
    assert {:ok, %{lock_mutated: true}} = Runtime.finish(first.handle)
    assert :ok = Runtime.release(first.handle)
    assert File.read!(Path.join(consumer, "mix.lock")) == source_lock

    assert {:ok, second} =
             Runtime.prepare(
               state_root,
               digest("lock-reuse-consumer"),
               source_lock,
               runtime_opts(consumer, project_identity: "lock_reuse_consumer")
             )

    assert second.report.dependency_identity == first.report.dependency_identity
    assert second.report.context_lock_status == :hit
    assert File.read!(second.report.lockfile) =~ commit

    second_env =
      [{"MIX_WORKSPACE_OPS_BOOTSTRAP", bootstrap}, {"ERL_AFLAGS", "+S 2:2"} | second.env]

    assert mix!(consumer, ["compile"], second_env) =~ "Generated lock_reuse_consumer app"
    assert {:ok, %{lock_mutated: false}} = Runtime.finish(second.handle)
    assert :ok = Runtime.release(second.handle)
    assert File.read!(Path.join(consumer, "mix.lock")) == source_lock
  end

  test "ordinary Mix remains standalone when no MWO environment is present", context do
    root = temporary_directory!(context)
    dependency = Path.join(root, "standalone_dep")
    consumer = Path.join(root, "standalone_consumer")
    File.mkdir_p!(Path.join(dependency, "lib"))
    File.mkdir_p!(Path.join(consumer, "lib"))

    File.write!(Path.join(dependency, "mix.exs"), project_file("standalone_dep", "[]"))

    File.write!(
      Path.join(dependency, "lib/standalone_dep.ex"),
      "defmodule StandaloneDep, do: :ok\n"
    )

    File.write!(
      Path.join(consumer, "mix.exs"),
      project_file("standalone_consumer", ~s|[{:standalone_dep, path: "../standalone_dep"}]|)
    )

    output = mix!(consumer, ["compile"], unmanaged_environment())
    assert output =~ "Generated standalone_consumer app"
    assert File.dir?(Path.join(consumer, "_build"))
  end

  test "one project reuses its build context after a checkout move and source edit", context do
    root = temporary_directory!(context)
    state_root = Path.join(root, "state")
    first_root = Path.join(root, "first/project")
    second_root = Path.join(root, "second/project")
    File.mkdir_p!(Path.join(first_root, "lib"))
    File.write!(Path.join(first_root, "mix.exs"), project_file("moving_project", "[]"))
    File.write!(Path.join(first_root, "lib/moving_project.ex"), value_module(:first))
    lock = "%{}\n"
    {:ok, bootstrap} = Bootstrap.materialize(state_root)

    assert {:ok, first} =
             Runtime.prepare(
               state_root,
               digest("moving-project"),
               lock,
               runtime_opts(first_root, project_identity: "moving_project")
             )

    first_env = [{"MIX_WORKSPACE_OPS_BOOTSTRAP", bootstrap}, {"ERL_AFLAGS", "+S 2:2"} | first.env]
    assert mix!(first_root, ["compile"], first_env) =~ "Generated moving_project app"
    assert {:ok, _report} = Runtime.finish(first.handle)
    assert :ok = Runtime.release(first.handle)

    File.mkdir_p!(Path.dirname(second_root))
    File.rename!(first_root, second_root)
    File.write!(Path.join(second_root, "lib/moving_project.ex"), value_module(:second))

    assert {:ok, second} =
             Runtime.prepare(
               state_root,
               digest("moving-project"),
               lock,
               runtime_opts(second_root,
                 project_identity: "moving_project",
                 target_head: String.duplicate("2", 40),
                 target_source_digest: digest("second-source")
               )
             )

    second_env = [
      {"MIX_WORKSPACE_OPS_BOOTSTRAP", bootstrap},
      {"ERL_AFLAGS", "+S 2:2"} | second.env
    ]

    assert first.report.deps_path == second.report.deps_path
    assert first.report.build_path == second.report.build_path
    assert mix!(second_root, ["compile"], second_env) =~ "Compiling 1 file"

    assert mix!(second_root, ["run", "-e", "IO.puts(MovingProject.value())"], second_env) =~
             "second"

    assert {:ok, _report} = Runtime.finish(second.handle)
    assert :ok = Runtime.release(second.handle)
  end

  test "runtime points Hex package cache at shared state and keeps configuration private",
       context do
    root = temporary_directory!(context)
    state_root = Path.join(root, "state")
    project = Path.join(root, "project")
    File.mkdir_p!(project)
    File.write!(Path.join(project, "mix.exs"), project_file("hex_layout", "[]"))
    {:ok, bootstrap} = Bootstrap.materialize(state_root)

    assert {:ok, runtime} =
             Runtime.prepare(
               state_root,
               digest("hex-layout"),
               "%{}\n",
               runtime_opts(project,
                 project_identity: "hex_layout",
                 archives_source: Mix.path_for(:archives)
               )
             )

    environment = [
      {"MIX_WORKSPACE_OPS_BOOTSTRAP", bootstrap},
      {"ERL_AFLAGS", "+S 2:2"} | runtime.env
    ]

    output = mix!(project, ["hex.config"], environment)
    assert output =~ ~s|cache_home: "#{runtime.report.hex_cache}"|
    assert output =~ ~s|config_home: "#{Path.join(runtime.report.config_home, "hex")}"|
    assert output =~ ~s|data_home: "#{Path.join(runtime.report.home, ".local/share/hex")}"|
    assert {:ok, _report} = Runtime.finish(runtime.handle)
    assert :ok = Runtime.release(runtime.handle)
  end

  test "different build contexts run Mix compilers concurrently", context do
    root = temporary_directory!(context)
    state_root = Path.join(root, "state")
    {:ok, bootstrap} = Bootstrap.materialize(state_root)

    runtimes =
      for id <- ~w(first second) do
        project = Path.join(root, id)
        marker = Path.join(root, "#{id}.timing")
        File.mkdir_p!(project)
        File.write!(Path.join(project, "mix.exs"), delayed_project_file(id))

        assert {:ok, runtime} =
                 Runtime.prepare(
                   state_root,
                   digest("context-#{id}"),
                   "%{}\n",
                   runtime_opts(project, project_identity: id)
                 )

        %{id: id, project: project, marker: marker, runtime: runtime}
      end

    tasks =
      Enum.map(runtimes, fn item ->
        Task.async(fn ->
          environment = [
            {"MIX_WORKSPACE_OPS_BOOTSTRAP", bootstrap},
            {"MWO_TEST_TIMING_PATH", item.marker},
            {"ERL_AFLAGS", "+S 2:2"} | item.runtime.env
          ]

          mix!(item.project, ["compile", "--force"], environment)
        end)
      end)

    Enum.each(tasks, &Task.await(&1, 15_000))

    intervals = Enum.map(runtimes, &read_interval(&1.marker))

    assert intervals |> Enum.map(&elem(&1, 0)) |> Enum.max() <
             intervals |> Enum.map(&elem(&1, 1)) |> Enum.min()

    Enum.each(runtimes, fn item ->
      assert {:ok, _report} = Runtime.finish(item.runtime.handle)
      assert :ok = Runtime.release(item.runtime.handle)
    end)
  end

  test "identical build contexts let Mix serialize the shared mutation", context do
    root = temporary_directory!(context)
    state_root = Path.join(root, "state")
    project = Path.join(root, "shared")
    File.mkdir_p!(project)
    File.write!(Path.join(project, "mix.exs"), delayed_project_file("shared"))
    {:ok, bootstrap} = Bootstrap.materialize(state_root)

    runtimes =
      for index <- 1..2 do
        assert {:ok, runtime} =
                 Runtime.prepare(
                   state_root,
                   digest("shared-context"),
                   "%{}\n",
                   runtime_opts(project, project_identity: "shared")
                 )

        %{runtime: runtime, marker: Path.join(root, "shared-#{index}.timing")}
      end

    tasks =
      Enum.map(runtimes, fn item ->
        Task.async(fn ->
          environment = [
            {"MIX_WORKSPACE_OPS_BOOTSTRAP", bootstrap},
            {"MWO_TEST_TIMING_PATH", item.marker},
            {"ERL_AFLAGS", "+S 2:2"} | item.runtime.env
          ]

          mix!(project, ["compile", "--force"], environment)
        end)
      end)

    Enum.each(tasks, &Task.await(&1, 15_000))
    [first, second] = runtimes |> Enum.map(&read_interval(&1.marker)) |> Enum.sort()
    assert elem(first, 1) <= elem(second, 0)

    Enum.each(runtimes, fn item ->
      assert {:ok, _report} = Runtime.finish(item.runtime.handle)
      assert :ok = Runtime.release(item.runtime.handle)
    end)
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

  defp value_module(value) do
    "defmodule MovingProject, do: def(value, do: #{inspect(value)})\n"
  end

  defp delayed_project_file(app) do
    module = app |> String.split("_") |> Enum.map_join(&String.capitalize/1)

    """
    defmodule Mix.Tasks.Compile.Delay do
      use Mix.Task.Compiler

      def run(_args) do
        marker = System.fetch_env!("MWO_TEST_TIMING_PATH")
        started = System.system_time(:millisecond)
        Process.sleep(1_000)
        finished = System.system_time(:millisecond)
        File.write!(marker, "\#{started},\#{finished}\n")
        {:ok, []}
      end
    end

    defmodule #{module}.MixProject do
      use Mix.Project
      def project, do: [app: :#{app}, version: "0.1.0", compilers: [:delay]]
    end
    """
  end

  defp read_interval(path) do
    [started, finished] = path |> File.read!() |> String.trim() |> String.split(",")
    {String.to_integer(started), String.to_integer(finished)}
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
