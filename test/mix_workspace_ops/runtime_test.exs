defmodule MixWorkspaceOps.RuntimeTest do
  use MixWorkspaceOps.WorkspaceCase, async: false

  alias MixWorkspaceOps.Runtime

  @cache_identity String.duplicate("a", 64)
  @lock ~S|%{"alpha" => {:hex, :alpha, "1.0.0"}}| <> "\n"
  @changed_lock ~S|%{"alpha" => {:hex, :alpha, "2.0.0"}}| <> "\n"

  test "concurrent identical invocations share reusable contexts but not transient state",
       context do
    state_root = temporary_directory!(context)

    tasks =
      for _index <- 1..2 do
        Task.async(fn -> Runtime.prepare(state_root, @cache_identity, @lock, runtime_opts()) end)
      end

    assert [{:ok, first}, {:ok, second}] = Enum.map(tasks, &Task.await(&1, 5_000))

    on_exit(fn ->
      finish_and_release(first.handle)
      finish_and_release(second.handle)
    end)

    assert first.report.cache_identity == second.report.cache_identity
    assert first.report.dependency_identity == second.report.dependency_identity
    assert first.report.execution_identity == second.report.execution_identity
    refute first.report.invocation_id == second.report.invocation_id
    refute first.report.root == second.report.root
    assert first.report.deps_path == second.report.deps_path
    assert first.report.build_path == second.report.build_path
    assert first.report.xdg_cache_home == second.report.xdg_cache_home
    assert first.report.mix_home == second.report.mix_home
    assert first.report.rebar_cache == second.report.rebar_cache
    assert first.report.tmp == second.report.tmp

    first_paths = transient_paths(first.report)
    second_paths = transient_paths(second.report)
    assert MapSet.disjoint?(MapSet.new(first_paths), MapSet.new(second_paths))
    assert Enum.all?(first_paths ++ second_paths, &String.starts_with?(&1, state_root))

    preparation = first.report.preparation |> File.read!() |> :json.decode()
    assert preparation["schema"] == "mix_workspace_ops.preparation/v1"
    assert preparation["project_identity"] == String.duplicate("a", 64)
    assert preparation["stage"] == "complete"
    assert preparation["status"] == "complete"
    assert File.stat!(first.report.preparation).mode |> Bitwise.band(0o777) == 0o600
  end

  test "a context lock wait times out with the unit, path, and lock owner", context do
    state_root = temporary_directory!(context)
    assert {:ok, initial} = Runtime.prepare(state_root, @cache_identity, @lock, runtime_opts())
    finish_and_release(initial.handle)

    parent = self()
    lock_key = "mix_workspace_ops:context:" <> Path.expand(initial.report.deps_path)

    holder =
      Task.async(fn ->
        Mix.Sync.Lock.with_lock(lock_key, fn ->
          send(parent, :context_lock_held)

          receive do
            :release_context_lock -> :ok
          end
        end)
      end)

    assert_receive :context_lock_held, 1_000

    assert {:error,
            {:runtime_preparation_failed, snapshot,
             {:preparation_timeout, project_identity, "dependency_lockfile", 100, details}}} =
             Runtime.prepare(
               state_root,
               @cache_identity,
               @lock,
               runtime_opts(preparation_timeout: 100)
             )

    assert project_identity == @cache_identity
    assert snapshot["status"] == "timed_out"
    assert snapshot["blocked_stage"] == "dependency_lockfile_lock"
    assert snapshot["lock_owner"] == System.pid()
    assert details.lock_owner == System.pid()
    assert details.path == initial.report.deps_path

    send(holder.pid, :release_context_lock)
    assert :ok = Task.await(holder, 1_000)
  end

  test "target revisions, dirty source digests, and checkout roots reuse compatible contexts",
       context do
    state_root = temporary_directory!(context)

    assert {:ok, first} =
             Runtime.prepare(
               state_root,
               @cache_identity,
               @lock,
               runtime_opts(
                 target_head: String.duplicate("1", 40),
                 target_source_digest: String.duplicate("a", 64),
                 binding_root: "/tmp/one"
               )
             )

    assert {:ok, second} =
             Runtime.prepare(
               state_root,
               @cache_identity,
               @lock,
               runtime_opts(
                 target_head: String.duplicate("2", 40),
                 target_source_digest: String.duplicate("b", 64),
                 binding_root: "/tmp/two"
               )
             )

    on_exit(fn ->
      finish_and_release(first.handle)
      finish_and_release(second.handle)
    end)

    assert first.report.dependency_identity == second.report.dependency_identity
    assert first.report.execution_identity == second.report.execution_identity
    assert first.report.deps_path == second.report.deps_path
    assert first.report.build_path == second.report.build_path
    refute first.report.root == second.report.root
  end

  test "lock mutation is rejected unless the invocation explicitly permits it", context do
    state_root = temporary_directory!(context)

    assert {:ok, refused} = Runtime.prepare(state_root, @cache_identity, @lock, runtime_opts())
    assert refused.report.context_lock_status == :initialized
    File.write!(refused.report.lockfile, @changed_lock)

    assert {:error, {:lock_mutation_not_allowed, refused_id, initial, final}} =
             Runtime.finish(refused.handle)

    assert refused_id == refused.report.invocation_id
    refute initial == final
    assert :ok = Runtime.release(refused.handle)

    assert {:ok, allowed} =
             Runtime.prepare(
               state_root,
               @cache_identity,
               @lock,
               runtime_opts(allow_lock_mutation: true)
             )

    assert allowed.report.context_lock_status == :hit
    assert File.read!(allowed.report.lockfile) == @lock
    File.write!(allowed.report.lockfile, @changed_lock)
    assert {:ok, final_report} = Runtime.finish(allowed.handle)
    assert final_report.lock_mutated
    assert final_report.status == "complete"
    refute final_report.source_lock_digest == final_report.final_lock_digest
    assert :ok = Runtime.release(allowed.handle)

    assert File.read!(refused.report.source_lock) == @lock
    assert File.read!(allowed.report.source_lock) == @lock
    assert File.read!(allowed.report.context_lockfile) == @changed_lock

    assert {:ok, reused} = Runtime.prepare(state_root, @cache_identity, @lock, runtime_opts())
    assert reused.report.dependency_identity == allowed.report.dependency_identity
    assert reused.report.context_lock_status == :hit
    assert File.read!(reused.report.lockfile) == @changed_lock
    finish_and_release(reused.handle)
  end

  test "a malformed persistent operational lock is quarantined and rebuilt", context do
    state_root = temporary_directory!(context)
    assert {:ok, first} = Runtime.prepare(state_root, @cache_identity, @lock, runtime_opts())
    context_lockfile = first.report.context_lockfile
    finish_and_release(first.handle)

    File.write!(context_lockfile, "not a literal lock\n")

    assert {:ok, recovered} = Runtime.prepare(state_root, @cache_identity, @lock, runtime_opts())
    assert recovered.report.context_lock_status == :recovered
    assert File.read!(recovered.report.lockfile) == @lock
    assert File.read!(context_lockfile) == @lock

    quarantined =
      context_lockfile
      |> Path.dirname()
      |> File.ls!()
      |> Enum.filter(&String.starts_with?(&1, Path.basename(context_lockfile) <> ".invalid-"))

    assert [_quarantined] = quarantined
    finish_and_release(recovered.handle)
  end

  test "concurrent operational lock updates cannot overwrite a different completed update",
       context do
    state_root = temporary_directory!(context)
    opts = runtime_opts(allow_lock_mutation: true)
    assert {:ok, first} = Runtime.prepare(state_root, @cache_identity, @lock, opts)
    assert {:ok, second} = Runtime.prepare(state_root, @cache_identity, @lock, opts)

    first_lock = ~S|%{"alpha" => {:hex, :alpha, "2.0.0"}}| <> "\n"
    second_lock = ~S|%{"alpha" => {:hex, :alpha, "3.0.0"}}| <> "\n"
    File.write!(first.report.lockfile, first_lock)
    File.write!(second.report.lockfile, second_lock)

    assert {:ok, _report} = Runtime.finish(first.handle)

    assert {:error,
            {:context_lock_conflict, context_lockfile, initial_digest, current_digest,
             final_digest}} = Runtime.finish(second.handle)

    assert context_lockfile == first.report.context_lockfile
    assert initial_digest == second.report.operational_lock_digest
    refute current_digest == initial_digest
    refute final_digest in [initial_digest, current_digest]
    assert File.read!(context_lockfile) == first_lock
    assert :ok = Runtime.release(first.handle)
    assert :ok = Runtime.release(second.handle)
  end

  test "a path-backed overlay projects only its top-level lock entry", context do
    state_root = temporary_directory!(context)

    lock =
      inspect(%{
        alpha:
          {:hex, :alpha, "1.0.0", String.duplicate("1", 64), [:mix], [], "hexpm",
           String.duplicate("2", 64)},
        untouched: {:git, "https://example.invalid/untouched.git", String.duplicate("a", 40), []}
      }) <> "\n"

    assert {:ok, runtime} =
             Runtime.prepare(
               state_root,
               @cache_identity,
               lock,
               runtime_opts(path_apps: ["alpha"])
             )

    on_exit(fn -> finish_and_release(runtime.handle) end)
    assert File.read!(runtime.report.source_lock) == lock
    projected = File.read!(runtime.report.lockfile)
    refute projected =~ "alpha"
    assert projected =~ "untouched"
  end

  test "dependency/build identity changes only for semantically incompatible contexts", context do
    state_root = temporary_directory!(context)

    assert {:ok, base} = Runtime.prepare(state_root, @cache_identity, @lock, runtime_opts())

    assert {:ok, moved} =
             Runtime.prepare(
               state_root,
               @cache_identity,
               @lock,
               runtime_opts(binding_root: "/tmp/mix_workspace_ops_runtime_test_other")
             )

    assert {:ok, test_env} =
             Runtime.prepare(state_root, @cache_identity, @lock, runtime_opts(mix_env: "test"))

    assert {:ok, other_target} =
             Runtime.prepare(
               state_root,
               @cache_identity,
               @lock,
               runtime_opts(mix_target: "other")
             )

    changed_lock = String.replace(@lock, "1.0.0", "2.0.0")

    assert {:ok, changed_deps} =
             Runtime.prepare(state_root, @cache_identity, changed_lock, runtime_opts())

    runtimes = [base, moved, test_env, other_target, changed_deps]
    on_exit(fn -> Enum.each(runtimes, &finish_and_release(&1.handle)) end)

    assert base.report.deps_path == moved.report.deps_path
    assert base.report.build_path == moved.report.build_path
    assert test_env.report.deps_path != base.report.deps_path
    assert other_target.report.deps_path != base.report.deps_path
    assert changed_deps.report.deps_path != base.report.deps_path
  end

  test "projects may share dependency state but never build state", context do
    state_root = temporary_directory!(context)

    assert {:ok, first} =
             Runtime.prepare(
               state_root,
               @cache_identity,
               @lock,
               runtime_opts(project_identity: "first")
             )

    assert {:ok, second} =
             Runtime.prepare(
               state_root,
               @cache_identity,
               @lock,
               runtime_opts(project_identity: "second")
             )

    on_exit(fn -> Enum.each([first, second], &finish_and_release(&1.handle)) end)
    assert first.report.deps_path == second.report.deps_path
    refute first.report.build_path == second.report.build_path
  end

  test "ordinary runtime state hides inherited publication capability", context do
    state_root = temporary_directory!(context)

    sensitive =
      ~w(
        HEX_API_KEY
        GITHUB_TOKEN
        SSH_AUTH_SOCK
        GIT_SSH_COMMAND
        GIT_CONFIG_COUNT
        EXAMPLE_OAUTH_TOKEN
        EXAMPLE_SERVICE_TOKEN
        EXAMPLE_PRIVATE_KEY
      )

    previous = Map.new(sensitive, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    System.put_env("HEX_API_KEY", "publish-secret")
    System.put_env("GITHUB_TOKEN", "tag-secret")
    System.put_env("SSH_AUTH_SOCK", "/operator/agent.sock")
    System.put_env("GIT_SSH_COMMAND", "ssh -i /operator/publish-key")
    System.put_env("GIT_CONFIG_COUNT", "1")
    System.put_env("EXAMPLE_OAUTH_TOKEN", "oauth-secret")
    System.put_env("EXAMPLE_SERVICE_TOKEN", "service-secret")
    System.put_env("EXAMPLE_PRIVATE_KEY", "private-key-secret")

    assert {:ok, runtime} =
             Runtime.prepare(state_root, @cache_identity, @lock, runtime_opts())

    on_exit(fn -> finish_and_release(runtime.handle) end)
    env = Map.new(runtime.env)

    assert env["HEX_API_KEY"] == nil
    assert env["GITHUB_TOKEN"] == nil
    assert env["SSH_AUTH_SOCK"] == nil
    assert env["GIT_SSH_COMMAND"] == nil
    assert env["GIT_CONFIG_COUNT"] == nil
    assert env["EXAMPLE_OAUTH_TOKEN"] == nil
    assert env["EXAMPLE_SERVICE_TOKEN"] == nil
    assert env["EXAMPLE_PRIVATE_KEY"] == nil
    assert env["GIT_TERMINAL_PROMPT"] == "0"
    assert env["GCM_INTERACTIVE"] == "never"
    refute env["HOME"] == System.user_home!()
    assert env["HEX_HOME"] == nil
    assert env["MIX_XDG"] == "1"
    assert env["XDG_CONFIG_HOME"] == runtime.report.config_home
    assert env["XDG_CACHE_HOME"] == runtime.report.xdg_cache_home
    refute env["XDG_CONFIG_HOME"] == env["XDG_CACHE_HOME"]

    expected_erlang_bin = :code.root_dir() |> to_string() |> Path.join("bin")
    assert env["PATH"] |> String.split(":") |> hd() == expected_erlang_bin
    assert File.stat!(runtime.report.root).mode |> Bitwise.band(0o777) == 0o700
    assert File.stat!(runtime.report.lease).mode |> Bitwise.band(0o777) == 0o600
    assert File.stat!(runtime.report.metadata).mode |> Bitwise.band(0o777) == 0o600
  end

  test "private Git source authentication is limited to the internal mirror transport", context do
    root = temporary_directory!(context)
    source = Path.join(root, "source")
    origin = Path.join(root, "origin.git")
    operator_home = Path.join(root, "operator-home")
    state_root = Path.join(root, "state")
    File.mkdir_p!(source)
    File.mkdir_p!(operator_home)
    git!(source, ["init", "--quiet"])
    git!(source, ["config", "user.name", "P9"])
    git!(source, ["config", "user.email", "p9@example.invalid"])
    File.write!(Path.join(source, "value.txt"), "private source\n")
    git!(source, ["add", "value.txt"])
    git!(source, ["commit", "--quiet", "-m", "source"])
    commit = git!(source, ["rev-parse", "HEAD"]) |> String.trim()
    git!(root, ["clone", "--quiet", "--bare", source, origin])

    private_remote = "https://private.example.invalid/source.git"

    File.write!(
      Path.join(operator_home, ".gitconfig"),
      "[url \"file://#{origin}\"]\n\tinsteadOf = #{private_remote}\n"
    )

    previous_home = System.get_env("HOME")
    previous_token = System.get_env("GH_TOKEN")
    System.put_env("HOME", operator_home)
    System.put_env("GH_TOKEN", "private-source-sentinel")

    on_exit(fn ->
      restore_env("HOME", previous_home)
      restore_env("GH_TOKEN", previous_token)
    end)

    lock = inspect(%{"private_dep" => {:git, private_remote, commit, []}}) <> "\n"

    assert {:ok, runtime} =
             Runtime.prepare(
               state_root,
               @cache_identity,
               lock,
               runtime_opts(
                 prepare_objects: true,
                 managed_sources: %{"private_dep" => "github"}
               )
             )

    on_exit(fn -> finish_and_release(runtime.handle) end)
    assert [%{remote: ^private_remote, commit: ^commit}] = runtime.report.cache_objects.git
    child_env = Map.new(runtime.env)
    assert child_env["HOME"] == runtime.report.home
    assert child_env["GH_TOKEN"] == nil
    refute inspect(runtime.report) =~ "private-source-sentinel"
  end

  test "delegated units use external reusable Mix state and shield credentials", context do
    state_root = temporary_directory!(context)

    assert {:ok, runtime} =
             Runtime.prepare(
               state_root,
               @cache_identity,
               @lock,
               runtime_opts(ownership: :delegated)
             )

    on_exit(fn -> finish_and_release(runtime.handle) end)
    env = Map.new(runtime.env)

    assert runtime.report.ownership == :delegated
    assert env["HEX_HOME"] == nil
    assert env["MIX_DEPS_PATH"] == runtime.report.deps_path
    assert env["MIX_BUILD_PATH"] == runtime.report.build_path
    assert env["MIX_WORKSPACE_OPS_LOCKFILE"] == runtime.report.lockfile
  end

  test "gc dry-run and removal agree and never remove a live lease", context do
    state_root = temporary_directory!(context)

    assert {:ok, completed} =
             Runtime.prepare(state_root, @cache_identity, @lock, runtime_opts(now: 100))

    assert {:ok, _report} = Runtime.finish(completed.handle)
    assert :ok = Runtime.release(completed.handle)

    assert {:ok, leased} =
             Runtime.prepare(state_root, @cache_identity, @lock, runtime_opts(now: 100))

    assert {:ok, dry} = Runtime.gc(state_root, 50, now: 200, dry_run: true)
    assert Enum.map(dry.runs, & &1.run_id) == [completed.report.invocation_id]
    assert File.dir?(completed.report.root)
    assert File.dir?(leased.report.root)

    assert {:ok, removed} = Runtime.gc(state_root, 50, now: 200)
    assert Enum.map(removed.runs, & &1.run_id) == Enum.map(dry.runs, & &1.run_id)
    refute File.exists?(completed.report.root)
    assert File.dir?(leased.report.root)

    assert :ok = Runtime.release(leased.handle)

    assert {:ok, contexts} = Runtime.gc(state_root, 50, now: 201)
    assert Enum.sort(Enum.map(contexts.contexts, & &1.kind)) == [:build, :deps]
    refute File.exists?(completed.report.deps_path)
    refute File.exists?(completed.report.build_path)
  end

  test "a reused PID with the wrong process start is a stale lease", context do
    state_root = temporary_directory!(context)

    assert {:ok, runtime} =
             Runtime.prepare(state_root, @cache_identity, @lock, runtime_opts(now: 1))

    lease = runtime.report.lease
    metadata = lease |> File.read!() |> :json.decode()
    File.write!(lease, :json.encode(Map.put(metadata, "process_start", "not-this-process")))

    assert {:ok, state} = Runtime.list(state_root)
    assert [%{leased: false}] = state.runs
    assert {:ok, removed} = Runtime.gc(state_root, 0, now: 2)
    assert [%{run_id: run_id}] = removed.runs
    assert run_id == runtime.report.invocation_id
    refute File.exists?(runtime.report.root)
  end

  test "gc age accepts seconds, minutes, hours and days" do
    assert Runtime.parse_age("90") == {:ok, 90}
    assert Runtime.parse_age("90s") == {:ok, 90}
    assert Runtime.parse_age("2m") == {:ok, 120}
    assert Runtime.parse_age("3h") == {:ok, 10_800}
    assert Runtime.parse_age("4d") == {:ok, 345_600}
    assert Runtime.parse_age("soon") == {:error, {:invalid_gc_age, "soon"}}
  end

  test "state inspection is empty when absent and refuses an unmarked directory", context do
    root = temporary_directory!(context)
    absent = Path.join(root, "absent")

    assert {:ok, %{runs: [], legacy_runtimes: []}} = Runtime.list(absent)
    assert {:ok, %{runs: []}} = Runtime.gc(absent, 0)
    refute File.exists?(absent)

    unmarked = Path.join(root, "unmarked")
    candidate = Path.join([unmarked, "runs", String.duplicate("a", 64), "candidate"])
    File.mkdir_p!(candidate)
    File.write!(Path.join(candidate, "runtime.json"), "do not remove\n")

    assert {:error, {:state_root_marker_missing, _marker}} = Runtime.list(unmarked)
    assert {:error, {:state_root_marker_missing, _marker}} = Runtime.gc(unmarked, 0)
    assert File.regular?(Path.join(candidate, "runtime.json"))
  end

  test "runtime identity is lowercase SHA-256 hex", context do
    state_root = temporary_directory!(context)

    for identity <- [String.duplicate("z", 64), String.duplicate("A", 64), "short"] do
      assert {:error, {:invalid_runtime_identity, :cache_identity, ^identity}} =
               Runtime.prepare(state_root, identity, @lock, runtime_opts())
    end
  end

  test "installed archives cannot smuggle a shared writable path through a symlink", context do
    root = temporary_directory!(context)
    state_root = Path.join(root, "state")
    archives = Path.join(root, "archives")
    shared = Path.join(root, "shared")
    File.mkdir_p!(archives)
    File.mkdir_p!(shared)
    File.write!(Path.join(shared, "sentinel"), "operator state\n")
    File.ln_s!(shared, Path.join(archives, "linked"))

    assert {:error, {:unsafe_runtime_archive_entry, linked, :symlink}} =
             Runtime.prepare(
               state_root,
               @cache_identity,
               @lock,
               runtime_opts(archives_source: archives)
             )

    assert linked == Path.join(archives, "linked")
    assert File.read!(Path.join(shared, "sentinel")) == "operator state\n"
    assert Path.wildcard(Path.join(state_root, "runs/*/*")) == []
  end

  defp runtime_opts(overrides \\ []) do
    Keyword.merge(
      [
        ownership: :managed,
        target_head: String.duplicate("1", 40),
        target_source_digest: String.duplicate("a", 64),
        binding_root: "/tmp/mix_workspace_ops_runtime_test",
        mix_env: "dev",
        mix_target: "host",
        archives_source: nil
      ],
      overrides
    )
  end

  defp transient_paths(report) do
    ~w(root home config_home lockfile source_lock)a
    |> Enum.map(&Map.fetch!(report, &1))
  end

  defp finish_and_release(handle) do
    Runtime.finish(handle)
    Runtime.release(handle)
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp git!(directory, args) do
    case System.cmd("git", args, cd: directory, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> flunk("git #{inspect(args)} exited #{status}: #{output}")
    end
  end
end
