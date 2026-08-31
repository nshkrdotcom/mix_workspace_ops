defmodule MixWorkspaceOps.Integration.SharedRuntimeCacheTest do
  use MixWorkspaceOps.WorkspaceCase, async: false

  alias MixWorkspaceOps.{Bootstrap, DependencyLock, GitCache, HexCache, Runtime}

  test "different versions of one Hex app compile concurrently and exact warm state is reused",
       context do
    root = temporary_directory!(context)
    state_root = Path.join(root, "state")
    first = hex_fixture!(root, "1.0.0", ":one")
    second = hex_fixture!(root, "2.0.0", ":two")

    prepared =
      [first, second]
      |> Task.async_stream(&prepare_hex_consumer!(&1, root, state_root),
        max_concurrency: 2,
        ordered: true,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, value} -> value end)

    results =
      prepared
      |> Task.async_stream(&compile_and_read!/1,
        max_concurrency: 2,
        ordered: true,
        timeout: 120_000
      )
      |> Enum.map(fn {:ok, value} -> value end)

    assert Enum.map(results, & &1.value) == [":one", ":two"]

    for item <- prepared do
      assert {:ok, _report} = Runtime.finish(item.runtime.handle)
      assert :ok = Runtime.release(item.runtime.handle)
      refute File.exists?(Path.join(item.consumer, "deps"))
      refute File.exists?(Path.join(item.consumer, "_build"))
      assert File.read!(Path.join(item.consumer, "mix.lock")) == item.lock
    end

    first_prepared = hd(prepared)

    assert {:ok, warm} =
             Runtime.prepare(
               state_root,
               first_prepared.cache_identity,
               first_prepared.lock,
               runtime_opts(first_prepared.consumer, first_prepared.source_digest,
                 prepare_objects: true,
                 hex_fetch: fn _ -> flunk("a warm exact object must not fetch") end
               )
             )

    on_exit(fn -> finish_and_release(warm.handle) end)
    assert warm.report.deps_present
    assert warm.report.build_present
    assert warm.report.deps_path == first_prepared.runtime.report.deps_path
    assert warm.report.build_path == first_prepared.runtime.report.build_path

    assert {:ok, %{status: :hit, extracted: false}} =
             HexCache.materialize(state_root, first_prepared.object, warm.report.deps_path)

    before = tree_digest(warm.report.build_path)

    result =
      mix!(
        first_prepared.consumer,
        ["compile", "--no-deps-check"],
        runtime_env(warm, first_prepared.bootstrap)
      )

    after_digest = tree_digest(warm.report.build_path)
    assert before == after_digest
    refute result =~ "Compiling"
    refute result =~ "Generated"
  end

  test "Mix obtains a Git dependency from the retained mirror after its origin disappears",
       context do
    root = temporary_directory!(context)
    state_root = Path.join(root, "state")
    source = Path.join(root, "git_source")
    origin = Path.join(root, "git_origin.git")
    consumer = Path.join(root, "git_consumer")
    File.mkdir_p!(Path.join(source, "lib"))
    write_git_dependency!(source)
    git!(source, ["init", "--quiet", "--initial-branch=main"])
    git!(source, ["config", "user.name", "P9Pre"])
    git!(source, ["config", "user.email", "p9pre@example.invalid"])
    git!(source, ["add", "."])
    git!(source, ["commit", "--quiet", "-m", "git dependency"])
    commit = git!(source, ["rev-parse", "HEAD"]) |> String.trim()
    git!(root, ["clone", "--quiet", "--bare", source, origin])
    hex = hex_fixture!(root, "1.0.0", ":hex")

    object = %{app: "git_dep", remote: origin, commit: commit, options: [ref: commit]}
    assert {:ok, mirror} = GitCache.ensure(state_root, object)
    assert mirror.status == :miss

    unavailable = origin <> ".offline"
    File.rename!(origin, unavailable)
    write_git_consumer!(consumer, origin, commit, hex.version)
    lock = git_and_hex_lock(origin, commit, hex.object)
    File.write!(Path.join(consumer, "mix.lock"), lock)
    {:ok, bootstrap} = Bootstrap.materialize(state_root)

    assert {:ok, runtime} =
             Runtime.prepare(
               state_root,
               digest("git-consumer"),
               lock,
               runtime_opts(consumer, digest("git-source"),
                 prepare_objects: true,
                 hex_fetch: fn _ -> {:ok, hex.tarball} end
               )
             )

    assert [%{status: :hit, network: false}] = runtime.report.cache_objects.git

    assert [%{object: %{status: :miss}, materialization: %{status: :miss}}] =
             runtime.report.cache_objects.hex

    assert {:ok, expected_operational_lock} = DependencyLock.project(lock, ["shared_dep"])
    assert File.read!(runtime.report.lockfile) == expected_operational_lock

    output = mix!(consumer, ["deps.get"], runtime_env(runtime, bootstrap))
    assert output =~ "* Getting git_dep"
    checkout = Path.join(runtime.report.deps_path, "git_dep")
    assert File.dir?(Path.join(checkout, ".git"))
    assert String.trim(git!(checkout, ["remote", "get-url", "origin"])) == origin
    assert String.trim(git!(checkout, ["rev-parse", "HEAD"])) == commit
    refute File.exists?(Path.join(consumer, "deps"))
    refute File.exists?(Path.join(consumer, "_build"))
    assert File.read!(Path.join(consumer, "mix.lock")) == lock
    assert File.read!(runtime.report.lockfile) == expected_operational_lock
    assert {:ok, %{lock_mutated: false}} = Runtime.finish(runtime.handle)
    assert :ok = Runtime.release(runtime.handle)
  end

  test "an unwrapped transitive Hex dependency is projected from the exact lock", context do
    root = temporary_directory!(context)
    state_root = Path.join(root, "state")
    consumer = Path.join(root, "transitive_consumer")
    nested = hex_fixture!(root, "1.0.0", ":nested", app: "nested_dep")

    parent =
      hex_fixture!(root, "1.0.0", "NestedDep.value()",
        app: "parent_dep",
        deps: [{:nested_dep, "== 1.0.0"}]
      )

    File.mkdir_p!(Path.join(consumer, "lib"))

    File.write!(
      Path.join(consumer, "mix.exs"),
      project_file("transitive_consumer", ~s|[{:parent_dep, "== 1.0.0"}]|)
    )

    File.write!(
      Path.join(consumer, "lib/transitive_consumer.ex"),
      module_file("TransitiveConsumer", "ParentDep.value()")
    )

    lock =
      inspect(%{
        parent_dep:
          hex_entry(parent.object, [
            {:nested_dep, "== 1.0.0", [hex: :nested_dep, repo: "hexpm", optional: false]}
          ]),
        nested_dep: hex_entry(nested.object)
      }) <> "\n"

    File.write!(Path.join(consumer, "mix.lock"), lock)

    tarballs = %{
      parent.object.outer_checksum => parent.tarball,
      nested.object.outer_checksum => nested.tarball
    }

    assert {:ok, runtime} =
             Runtime.prepare(
               state_root,
               digest("transitive-consumer"),
               lock,
               runtime_opts(consumer, digest("transitive-source"),
                 prepare_objects: true,
                 hex_fetch: fn object -> {:ok, Map.fetch!(tarballs, object.outer_checksum)} end
               )
             )

    {:ok, bootstrap} = Bootstrap.materialize(state_root)

    output = mix!(consumer, ["deps.compile"], runtime_env(runtime, bootstrap))

    assert output =~ "nested_dep"
    assert output =~ "parent_dep"

    compile = mix!(consumer, ["compile", "--no-deps-check"], runtime_env(runtime, bootstrap))
    assert compile =~ "Generated transitive_consumer app"
    refute File.exists?(Path.join(consumer, "deps"))
    refute File.exists?(Path.join(consumer, "_build"))
    assert File.read!(Path.join(consumer, "mix.lock")) == lock
    assert {:ok, %{lock_mutated: false}} = Runtime.finish(runtime.handle)
    assert :ok = Runtime.release(runtime.handle)
  end

  test "a retained exact Hex source preserves Mix version requirement checks", context do
    root = temporary_directory!(context)
    state_root = Path.join(root, "state")
    consumer = Path.join(root, "requirement_consumer")
    fixture = hex_fixture!(root, "1.0.0", ":one")
    File.mkdir_p!(Path.join(consumer, "lib"))
    File.write!(Path.join(consumer, "mix.exs"), managed_project_file("2.0.0"))
    File.write!(Path.join(consumer, "lib/consumer.ex"), module_file("Consumer", ":consumer"))
    lock = hex_lock(fixture.object)
    File.write!(Path.join(consumer, "mix.lock"), lock)

    assert {:ok, runtime} =
             Runtime.prepare(
               state_root,
               digest("requirement-consumer"),
               lock,
               runtime_opts(consumer, digest("requirement-source"),
                 prepare_objects: true,
                 hex_fetch: fn _ -> {:ok, fixture.tarball} end
               )
             )

    on_exit(fn -> finish_and_release(runtime.handle) end)
    {:ok, bootstrap} = Bootstrap.materialize(state_root)

    {output, status} =
      System.cmd("mix", ["deps.compile"],
        cd: consumer,
        env: runtime_env(runtime, bootstrap),
        stderr_to_stdout: true
      )

    assert status != 0
    assert output =~ "does not match the requirement"
    assert output =~ "== 2.0.0"
  end

  test "ordinary Mix remains standalone when no managed environment is present", context do
    root = temporary_directory!(context)
    dependency = Path.join(root, "standalone_dep")
    consumer = Path.join(root, "standalone_consumer")
    File.mkdir_p!(Path.join(dependency, "lib"))
    File.mkdir_p!(Path.join(consumer, "lib"))

    File.write!(Path.join(dependency, "mix.exs"), project_file("standalone_dep", "[]"))

    File.write!(
      Path.join(dependency, "lib/standalone_dep.ex"),
      module_file("StandaloneDep", ":ok")
    )

    File.write!(
      Path.join(consumer, "mix.exs"),
      project_file("standalone_consumer", ~s|[{:standalone_dep, path: "../standalone_dep"}]|)
    )

    File.write!(
      Path.join(consumer, "lib/standalone_consumer.ex"),
      module_file("StandaloneConsumer", ":ok")
    )

    output = mix!(consumer, ["compile"], unmanaged_environment())
    assert output =~ "Generated standalone_consumer app"
    assert File.dir?(Path.join(consumer, "_build"))
    refute File.exists?(Path.join(consumer, "deps"))
  end

  defp prepare_hex_consumer!(fixture, root, state_root) do
    consumer = Path.join(root, "consumer_#{String.replace(fixture.version, ".", "_")}")
    File.mkdir_p!(Path.join(consumer, "lib"))
    File.write!(Path.join(consumer, "mix.exs"), managed_project_file(fixture.version))
    File.write!(Path.join(consumer, "lib/consumer.ex"), module_file("Consumer", ":consumer"))
    lock = hex_lock(fixture.object)
    File.write!(Path.join(consumer, "mix.lock"), lock)
    cache_identity = digest("consumer:" <> fixture.version)
    source_digest = digest("source:" <> fixture.version)

    assert {:ok, runtime} =
             Runtime.prepare(
               state_root,
               cache_identity,
               lock,
               runtime_opts(consumer, source_digest,
                 prepare_objects: true,
                 hex_fetch: fn _ -> {:ok, fixture.tarball} end
               )
             )

    assert [%{object: %{status: :miss}, materialization: %{status: :miss, extracted: true}}] =
             runtime.report.cache_objects.hex

    {:ok, bootstrap} = Bootstrap.materialize(state_root)

    Map.merge(fixture, %{
      bootstrap: bootstrap,
      cache_identity: cache_identity,
      consumer: consumer,
      lock: lock,
      runtime: runtime,
      source_digest: source_digest
    })
  end

  defp compile_and_read!(item) do
    environment = runtime_env(item.runtime, item.bootstrap)
    deps_compile = mix!(item.consumer, ["deps.compile"], environment)
    compile = mix!(item.consumer, ["compile", "--no-deps-check"], environment)

    [beam] =
      Path.wildcard(Path.join(item.runtime.report.build_path, "**/Elixir.SharedDep.beam"))

    {value, 0} =
      System.cmd(
        "elixir",
        ["-pa", Path.dirname(beam), "-e", "IO.inspect(SharedDep.value())"],
        env: [{"ERL_AFLAGS", "+S 2:2"}],
        stderr_to_stdout: true
      )

    assert deps_compile =~ "shared_dep"
    %{compile: compile, value: String.trim(value)}
  end

  defp hex_fixture!(root, version, value, opts \\ []) do
    app = Keyword.get(opts, :app, "shared_dep")
    module = app |> String.split("_") |> Enum.map_join(&String.capitalize/1)
    dependencies = Keyword.get(opts, :deps, [])
    package_root = Path.join(root, "package_#{app}_#{String.replace(version, ".", "_")}")
    File.mkdir_p!(Path.join(package_root, "lib"))

    File.write!(
      Path.join(package_root, "mix.exs"),
      project_file(app, inspect(dependencies), version)
    )

    File.write!(Path.join(package_root, "lib/#{app}.ex"), module_file(module, value))
    Mix.Local.append_archives()

    tar =
      File.cd!(package_root, fn ->
        Hex.Tar.create!(
          %{name: app, version: version, build_tools: ["mix"]},
          ["mix.exs", "lib/#{app}.ex"],
          :memory
        )
      end)

    canonical = %{
      repository: "hexpm",
      package: app,
      version: version,
      inner_checksum: Base.encode16(tar.inner_checksum, case: :lower),
      outer_checksum: Base.encode16(tar.outer_checksum, case: :lower)
    }

    object =
      Map.merge(canonical, %{
        app: app,
        managers: [:mix],
        identity: canonical |> MixWorkspaceOps.Report.encode() |> digest()
      })

    %{object: object, tarball: tar.tarball, version: version}
  end

  defp managed_project_file(version) do
    """
    defmodule Consumer.MixProject do
      use Mix.Project

      def project do
        [app: :consumer, version: "0.1.0", deps: [{:shared_dep, "== #{version}"}]]
      end
    end
    """
  end

  defp write_git_dependency!(root) do
    File.write!(Path.join(root, "mix.exs"), project_file("git_dep", "[]"))
    File.write!(Path.join(root, "lib/git_dep.ex"), module_file("GitDep", ":git"))
  end

  defp write_git_consumer!(root, remote, commit, hex_version) do
    File.mkdir_p!(Path.join(root, "lib"))

    File.write!(
      Path.join(root, "mix.exs"),
      """
      if bootstrap = System.get_env("MIX_WORKSPACE_OPS_BOOTSTRAP"), do: Code.require_file(bootstrap)

      defmodule GitConsumer.MixProject do
        use Mix.Project

        def project do
          [
            app: :git_consumer,
            version: "0.1.0",
            deps: [
              {:git_dep, git: #{inspect(remote)}, ref: #{inspect(commit)}},
              workspace_dep({:shared_dep, "== #{hex_version}"})
            ]
          ]
        end

        defp workspace_dep(committed) do
          if function_exported?(MixWorkspaceOpsBootstrap, :dep, 2),
            do: apply(MixWorkspaceOpsBootstrap, :dep, [committed, __DIR__]),
            else: committed
        end
      end
      """
    )

    File.write!(Path.join(root, "lib/git_consumer.ex"), module_file("GitConsumer", ":ok"))
  end

  defp project_file(app, deps, version \\ "0.1.0") do
    module = app |> String.split("_") |> Enum.map_join(&String.capitalize/1)

    """
    defmodule #{module}.MixProject do
      use Mix.Project
      def project, do: [app: :#{app}, version: #{inspect(version)}, deps: #{deps}]
    end
    """
  end

  defp module_file(module, value), do: "defmodule #{module}, do: def(value, do: #{value})\n"

  defp hex_lock(object) do
    inspect(%{shared_dep: hex_entry(object)}) <> "\n"
  end

  defp hex_entry(object, dependencies \\ []) do
    {:hex, String.to_atom(object.package), object.version, object.inner_checksum, [:mix],
     dependencies, object.repository, object.outer_checksum}
  end

  defp git_and_hex_lock(remote, commit, hex) do
    inspect(%{
      git_dep: {:git, remote, commit, [ref: commit]},
      shared_dep:
        {:hex, :shared_dep, hex.version, hex.inner_checksum, [:mix], [], "hexpm",
         hex.outer_checksum}
    }) <> "\n"
  end

  defp runtime_opts(root, source_digest, extra) do
    Keyword.merge(
      [
        ownership: :managed,
        target_head: String.duplicate("1", 40),
        target_source_digest: source_digest,
        binding_root: root,
        mix_env: "dev",
        mix_target: "host",
        archives_source: nil
      ],
      extra
    )
  end

  defp runtime_env(runtime, bootstrap) do
    [{"MIX_WORKSPACE_OPS_BOOTSTRAP", bootstrap}, {"ERL_AFLAGS", "+S 2:2"} | runtime.env]
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

  defp mix!(root, arguments, environment) do
    case System.cmd("mix", arguments, cd: root, env: environment, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> flunk("mix #{Enum.join(arguments, " ")} exited #{status}:\n#{output}")
    end
  end

  defp git!(root, arguments) do
    case System.cmd("git", arguments, cd: root, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> flunk("git #{inspect(arguments)} exited #{status}:\n#{output}")
    end
  end

  defp tree_digest(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map_join("\0", fn path -> Path.relative_to(path, root) <> "\0" <> File.read!(path) end)
    |> digest()
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp finish_and_release(handle) do
    Runtime.finish(handle)
    Runtime.release(handle)
  end
end
