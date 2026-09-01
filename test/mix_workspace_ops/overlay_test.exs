defmodule MixWorkspaceOps.OverlayTest do
  use MixWorkspaceOps.WorkspaceCase, async: true

  alias MixWorkspaceOps.{Overlay, Registry}

  test "materializes one operator-state overlay without writing managed repositories", context do
    root = temporary_directory!(context)
    state_root = Path.join(root, "operator-state")
    initialize_repository!(Path.join(root, "core"))
    initialize_repository!(Path.join(root, "consumer"), ~s([{:core, path: "../core"}]))
    registry = registry(root)

    assert {:ok, activation} = Overlay.activate(registry, "consumer", state_root: state_root)
    assert activation.report.projects == ["core", "consumer"]
    assert {"MIX_WORKSPACE_OPS_OVERLAY", activation.path} in activation.env
    assert {"MIX_WORKSPACE_OPS_BOOTSTRAP", activation.report.bootstrap_path} in activation.env

    assert {"MIX_WORKSPACE_OPS_CONTEXT_DIGEST", activation.report.context_digest} in activation.env

    assert {"MIX_DEPS_PATH", activation.report.runtime.deps_path} in activation.env
    assert {"MIX_BUILD_PATH", activation.report.runtime.build_path} in activation.env
    assert {"XDG_CACHE_HOME", activation.report.runtime.xdg_cache_home} in activation.env
    assert {"HEX_HOME", nil} in activation.env

    assert {"MIX_WORKSPACE_OPS_LOCKFILE", activation.report.runtime.lockfile} in activation.env

    assert String.starts_with?(activation.path, state_root)
    assert String.starts_with?(activation.report.runtime.root, state_root)
    assert File.read!(activation.report.runtime.lockfile) == "%{}\n"
    assert {:ok, overlay} = Overlay.read(activation.path)
    assert overlay.schema == "mix_workspace_ops.overlay/v3"
    assert overlay.mode == "auto"
    refute overlay.publish
    assert overlay.context_digest == activation.report.context_digest
    assert Map.keys(overlay.sources) == ["core"]
    assert overlay.sources["core"].kind == :local
    assert overlay.sources["core"].path == Path.join(root, "core")
    assert is_binary(overlay.sources["core"].source_digest)
    assert [%{application: "core", source: "local", reason: :order}] = activation.report.decisions

    refute File.exists?(Path.join(root, "core/.mix_workspace_ops"))
    refute File.exists?(Path.join(root, "consumer/.mix_workspace_ops"))
  end

  test "delegated execution carries source context and external reusable Mix state", context do
    root = temporary_directory!(context)
    state_root = Path.join(root, "operator-state")
    initialize_repository!(Path.join(root, "core"))
    initialize_repository!(Path.join(root, "consumer"), ~s([{:core, path: "../core"}]))

    assert {:ok, activation} =
             Overlay.activate(registry(root), "consumer",
               state_root: state_root,
               mix_state: :delegated
             )

    assert activation.report.runtime.ownership == :delegated
    assert activation.report.runtime.digest == activation.report.context_digest
    assert {"MIX_WORKSPACE_OPS_OVERLAY", activation.path} in activation.env

    assert {"MIX_WORKSPACE_OPS_CONTEXT_DIGEST", activation.report.context_digest} in activation.env

    assert {"HEX_HOME", nil} in activation.env
    assert {"MIX_DEPS_PATH", activation.report.runtime.deps_path} in activation.env
    assert {"MIX_BUILD_PATH", activation.report.runtime.build_path} in activation.env
    assert {"MIX_WORKSPACE_OPS_LOCKFILE", activation.report.runtime.lockfile} in activation.env
  end

  test "a local path overlay leaves ordinary Hex materialization to Mix", context do
    root = temporary_directory!(context)
    state_root = Path.join(root, "operator-state")
    initialize_repository!(Path.join(root, "core"))
    consumer = initialize_repository!(Path.join(root, "consumer"), ~s([{:core, "~> 1.0"}]))

    checksum = String.duplicate("f", 64)

    File.write!(
      Path.join(consumer, "mix.lock"),
      ~s|%{"core" => {:hex, :core, "1.0.0", "#{checksum}", [:mix], [], "hexpm", "#{checksum}"}}\n|
    )

    assert {:ok, activation} =
             Overlay.activate(registry(root), "consumer",
               state_root: state_root,
               prepare_objects: true
             )

    assert activation.report.runtime.cache_objects == %{git: []}
    refute File.exists?(Path.join([state_root, "cache", "hex", "objects"]))

    changed_checksum = String.duplicate("e", 64)

    File.write!(
      Path.join(consumer, "mix.lock"),
      ~s|%{"core" => {:hex, :core, "9.9.9", "#{changed_checksum}", [:mix], [], "hexpm", "#{changed_checksum}"}}\n|
    )

    assert {:ok, changed} =
             Overlay.activate(registry(root), "consumer",
               state_root: state_root,
               prepare_objects: true
             )

    # The stale source lock row is projected out when `core` is a local path.
    # Its bytes remain in overlay audit identity but cannot split reusable Mix
    # dependency/build contexts.
    assert changed.report.context_digest == activation.report.context_digest

    assert changed.report.runtime.dependency_identity ==
             activation.report.runtime.dependency_identity

    assert changed.report.runtime.deps_path == activation.report.runtime.deps_path
    assert changed.report.runtime.build_path == activation.report.runtime.build_path
    refute changed.report.overlay_digest == activation.report.overlay_digest
  end

  test "semantic context is independent of checkout paths", context do
    root = temporary_directory!(context)
    first = Path.join(root, "first")
    second = Path.join(root, "second")
    File.mkdir_p!(first)
    File.mkdir_p!(second)
    initialize_repository!(Path.join(first, "core"))
    initialize_repository!(Path.join(first, "consumer"), ~s([{:core, path: "../core"}]))

    for repository <- ~w(core consumer) do
      source = Path.join(first, repository)
      destination = Path.join(second, repository)
      {_, 0} = System.cmd("git", ["clone", "--quiet", source, destination])

      {_, 0} =
        System.cmd(
          "git",
          ["remote", "set-url", "origin", "https://github.com/example-org/#{repository}.git"],
          cd: destination
        )
    end

    first_registry = registry(first)
    second_registry = registry(second)

    assert {:ok, first_activation} =
             Overlay.activate(first_registry, "consumer", state_root: Path.join(root, "state-a"))

    assert {:ok, second_activation} =
             Overlay.activate(second_registry, "consumer", state_root: Path.join(root, "state-b"))

    assert first_activation.report.context_digest == second_activation.report.context_digest
    refute first_activation.report.overlay_digest == second_activation.report.overlay_digest
  end

  test "content addressing reuses identical bytes and changes across modes", context do
    root = temporary_directory!(context)
    state_root = Path.join(root, "operator-state")
    initialize_repository!(Path.join(root, "core"))
    initialize_repository!(Path.join(root, "consumer"), ~s([{:core, path: "../core"}]))
    registry = registry(root)

    assert {:ok, first} = Overlay.activate(registry, "consumer", state_root: state_root)
    assert {:ok, second} = Overlay.activate(registry, "consumer", state_root: state_root)
    assert first.path == second.path
    assert first.report.runtime.deps_path == second.report.runtime.deps_path
    assert first.report.runtime.build_path == second.report.runtime.build_path

    File.write!(Path.join(root, "consumer/target-change.txt"), "owned by target impact logic\n")
    assert {:ok, target_changed} = Overlay.activate(registry, "consumer", state_root: state_root)
    refute target_changed.path == first.path
    assert target_changed.report.context_digest == first.report.context_digest

    File.write!(Path.join(root, "core/uncommitted.txt"), "changed source\n")
    assert {:ok, dirty} = Overlay.activate(registry, "consumer", state_root: state_root)
    refute dirty.path == first.path
    assert dirty.report.context_digest == first.report.context_digest
    assert dirty.report.runtime.deps_path == first.report.runtime.deps_path
    assert dirty.report.runtime.build_path == first.report.runtime.build_path
    assert dirty.report.runtime.cache_objects == %{git: []}

    assert {:ok, git} = Overlay.activate(registry, "consumer", mode: :git, state_root: state_root)
    refute git.path == first.path
    assert {:ok, git_overlay} = Overlay.read(git.path)
    assert git_overlay.sources["core"].kind == :github
    assert git_overlay.sources["core"].repo == "example-org/core"
    assert git_overlay.sources["core"].revision_kind == "branch"
    assert git_overlay.sources["core"].revision == "main"

    assert {:ok, hex} = Overlay.activate(registry, "consumer", mode: :hex, state_root: state_root)
    refute hex.path == first.path
    assert {:ok, hex_overlay} = Overlay.read(hex.path)
    assert hex_overlay.mode == "hex"
    assert hex_overlay.sources["core"] == %{kind: :hex, requirement: "~> 1.0", opts: []}
  end

  test "target commits preserve dependency and build context identity", context do
    root = temporary_directory!(context)
    state_root = Path.join(root, "operator-state")
    initialize_repository!(Path.join(root, "core"))
    consumer = initialize_repository!(Path.join(root, "consumer"), ~s([{:core, path: "../core"}]))
    registry = registry(root)

    assert {:ok, first} = Overlay.activate(registry, "consumer", state_root: state_root)

    File.write!(Path.join(consumer, "target.txt"), "second target revision\n")
    {_, 0} = System.cmd("git", ["add", "target.txt"], cd: consumer)

    {_, 0} =
      System.cmd("git", ["commit", "--quiet", "-m", "second target revision"], cd: consumer)

    assert {:ok, second} = Overlay.activate(registry, "consumer", state_root: state_root)

    assert first.report.runtime.cache_identity == second.report.runtime.cache_identity
    assert first.report.runtime.dependency_identity == second.report.runtime.dependency_identity
    assert first.report.runtime.execution_identity == second.report.runtime.execution_identity
    refute first.report.runtime.root == second.report.runtime.root
    assert {:ok, _report} = Overlay.deactivate(first)
    assert {:ok, _report} = Overlay.deactivate(second)
  end

  test "concurrent identical activations share contexts and isolate transient state", context do
    root = temporary_directory!(context)
    state_root = Path.join(root, "operator-state")
    initialize_repository!(Path.join(root, "core"))
    initialize_repository!(Path.join(root, "consumer"), ~s([{:core, path: "../core"}]))
    registry = registry(root)

    tasks =
      for _index <- 1..2 do
        Task.async(fn -> Overlay.activate(registry, "consumer", state_root: state_root) end)
      end

    assert [{:ok, first}, {:ok, second}] = Enum.map(tasks, &Task.await(&1, 30_000))
    first_runtime = first.report.runtime
    second_runtime = second.report.runtime

    assert first_runtime.cache_identity == second_runtime.cache_identity
    assert first_runtime.execution_identity == second_runtime.execution_identity
    refute first_runtime.invocation_id == second_runtime.invocation_id
    assert first_runtime.deps_path == second_runtime.deps_path
    assert first_runtime.build_path == second_runtime.build_path
    assert first_runtime.xdg_cache_home == second_runtime.xdg_cache_home

    assert MapSet.disjoint?(
             MapSet.new(runtime_writable_paths(first_runtime)),
             MapSet.new(runtime_writable_paths(second_runtime))
           )

    assert {:ok, _report} = Overlay.deactivate(first)
    assert {:ok, _report} = Overlay.deactivate(second)
  end

  test "unlocked incompatible dependency declarations never share a dependency context",
       context do
    root = temporary_directory!(context)
    state_root = Path.join(root, "operator-state")
    initialize_repository!(Path.join(root, "first"), ~s([{:external_dep, "~> 1.0"}]))
    initialize_repository!(Path.join(root, "second"), ~s([{:external_dep, "~> 2.0"}]))

    registry =
      root
      |> write_catalog!([
        catalog_repository("first", projects: [catalog_project("first")]),
        catalog_repository("second", projects: [catalog_project("second")])
      ])
      |> Registry.load!()
      |> bind!(root)

    assert {:ok, first} = Overlay.activate(registry, "first", state_root: state_root)
    assert {:ok, second} = Overlay.activate(registry, "second", state_root: state_root)

    refute first.report.context_digest == second.report.context_digest
    refute first.report.runtime.deps_path == second.report.runtime.deps_path
    assert {:ok, _report} = Overlay.deactivate(first)
    assert {:ok, _report} = Overlay.deactivate(second)
  end

  test "different projects with identical dependency declarations share only dependency state",
       context do
    root = temporary_directory!(context)
    state_root = Path.join(root, "operator-state")
    dependency = ~s([{:external_dep, "~> 1.0"}])
    initialize_repository!(Path.join(root, "first"), dependency)
    initialize_repository!(Path.join(root, "second"), dependency)

    registry =
      root
      |> write_catalog!([
        catalog_repository("first", projects: [catalog_project("first")]),
        catalog_repository("second", projects: [catalog_project("second")])
      ])
      |> Registry.load!()
      |> bind!(root)

    assert {:ok, first} = Overlay.activate(registry, "first", state_root: state_root)
    assert {:ok, second} = Overlay.activate(registry, "second", state_root: state_root)

    assert first.report.context_digest == second.report.context_digest
    assert first.report.runtime.deps_path == second.report.runtime.deps_path
    refute first.report.runtime.build_path == second.report.runtime.build_path
    assert {:ok, _report} = Overlay.deactivate(first)
    assert {:ok, _report} = Overlay.deactivate(second)
  end

  # The overlay is content-addressed, so what it attests to has to name the view
  # it was decided under. Two views over one catalog decide different rows, and
  # an overlay that recorded only the document digest gave them one identity.
  test "an overlay attests to the selection it was decided under", context do
    root = temporary_directory!(context)
    state_root = Path.join(root, "operator-state")
    initialize_repository!(Path.join(root, "core"))
    initialize_repository!(Path.join(root, "consumer"), ~s([{:core, path: "../core"}]))
    initialize_repository!(Path.join(root, "spare"))
    registry = registry(root, spare: true)

    assert {:ok, whole} = Overlay.activate(registry, "consumer", state_root: state_root)
    assert {:ok, unselected} = Overlay.read(whole.path)
    assert unselected.selection_digest == nil
    assert whole.report.selection_digest == nil

    narrowed =
      Registry.select(registry, Enum.map(~w(core consumer), &Registry.project!(registry, &1)))

    assert {:ok, viewed} = Overlay.activate(narrowed, "consumer", state_root: state_root)
    assert {:ok, selected} = Overlay.read(viewed.path)
    assert selected.selection_digest == Registry.selection_digest(narrowed)
    assert viewed.report.selection_digest == selected.selection_digest

    # The overlay attests to the view and therefore has different content, but
    # the reusable Mix context is identical because the actual source semantics
    # for this project did not change.
    assert Map.keys(unselected.sources) == Map.keys(selected.sources)
    refute whole.path == viewed.path
    assert whole.report.context_digest == viewed.report.context_digest
  end

  test "a mode naming a source the catalog cannot reach is a typed error", context do
    root = temporary_directory!(context)
    state_root = Path.join(root, "operator-state")
    initialize_repository!(Path.join(root, "core"))
    initialize_repository!(Path.join(root, "consumer"), ~s([{:core, path: "../core"}]))
    registry = registry(root, declaration: %{"order" => ["local"]})

    assert {:error, {:unavailable_run_mode, "hex", ["core"]}} =
             Overlay.activate(registry, "consumer", mode: :hex, state_root: state_root)

    assert {:error, {:unavailable_run_mode, "github", ["core"]}} =
             Overlay.activate(registry, "consumer", mode: :git, state_root: state_root)
  end

  test "a per-dependency source overrides the run mode", context do
    root = temporary_directory!(context)
    state_root = Path.join(root, "operator-state")
    initialize_repository!(Path.join(root, "core"))
    initialize_repository!(Path.join(root, "consumer"), ~s([{:core, path: "../core"}]))

    assert {:ok, activation} =
             Overlay.activate(registry(root), "consumer",
               mode: :hex,
               sources: %{"core" => "github"},
               state_root: state_root
             )

    assert {:ok, overlay} = Overlay.read(activation.path)
    assert overlay.mode == "hex"
    assert overlay.sources["core"].kind == :github
    assert [%{reason: :dependency_override}] = activation.report.decisions
  end

  test "known-unselected stays on a committed source until a new selection permits local",
       context do
    root = temporary_directory!(context)
    state_root = Path.join(root, "operator-state")
    initialize_repository!(Path.join(root, "core"))
    initialize_repository!(Path.join(root, "consumer"), ~s([{:core, path: "../core"}]))

    registry = registry(root)

    selected =
      Registry.select(registry, [Registry.project!(registry, "consumer")])

    assert {:ok, report} = MixWorkspaceOps.Resolution.resolve(selected, "consumer")

    assert [decision] = report.decisions
    assert decision.application == "core"
    assert decision.classification == :known_unselected
    assert decision.provider_project_id == "core"
    assert decision.source == "github"
    assert decision.location.repo == "example-org/core"

    assert {:ok, activation} =
             Overlay.activate(selected, "consumer", state_root: state_root)

    assert {:ok, overlay} = Overlay.read(activation.path)
    assert overlay.sources["core"].kind == :github
    assert activation.report.known_unselected == [{"consumer", "core", ["core"]}]

    expression = """
    Code.require_file(#{inspect(activation.report.bootstrap_path)})
    IO.inspect(MixWorkspaceOpsBootstrap.dep({:core, "~> 1.0"}, #{inspect(Path.join(root, "consumer"))}))
    """

    assert {bootstrap_output, 0} =
             System.cmd(System.find_executable("elixir"), ["-e", expression],
               env: activation.env,
               stderr_to_stdout: true
             )

    assert bootstrap_output =~ ~s|{:core, [github: "example-org/core", branch: "main"]}|

    assert {:error, {:known_unselected_local, "core", ["core"]}} =
             MixWorkspaceOps.Resolution.resolve(selected, "consumer", mode: "local")

    assert {:error, {:known_unselected_local, "core", ["core"]}} =
             Overlay.activate(selected, "consumer", mode: :local, state_root: state_root)

    permitted =
      Registry.select(registry, [
        Registry.project!(registry, "consumer"),
        Registry.project!(registry, "core")
      ])

    assert {:ok, permitted_report} =
             MixWorkspaceOps.Resolution.resolve(permitted, "consumer")

    assert [%{classification: :managed, source: "local"}] = permitted_report.decisions
  end

  test "publish resolution is recorded in the overlay it produces", context do
    root = temporary_directory!(context)
    state_root = Path.join(root, "operator-state")
    initialize_repository!(Path.join(root, "core"))
    initialize_repository!(Path.join(root, "consumer"), ~s([{:core, path: "../core"}]))

    assert {:ok, activation} =
             Overlay.activate(registry(root), "consumer",
               publish?: true,
               state_root: state_root
             )

    assert {:ok, overlay} = Overlay.read(activation.path)
    assert overlay.publish
    assert overlay.sources["core"] == %{kind: :hex, requirement: "~> 1.0", opts: []}
    assert activation.report.publish
  end

  test "the options a declaration carries reach the overlay row", context do
    root = temporary_directory!(context)
    state_root = Path.join(root, "operator-state")
    initialize_repository!(Path.join(root, "core"))
    initialize_repository!(Path.join(root, "consumer"), ~s([{:core, path: "../core"}]))

    registry =
      registry(root,
        declaration: %{
          "hex" => "~> 1.0",
          "opts" => %{"only" => ["dev", "test"], "runtime" => false}
        }
      )

    assert {:ok, activation} = Overlay.activate(registry, "consumer", state_root: state_root)
    assert {:ok, overlay} = Overlay.read(activation.path)
    assert overlay.sources["core"].opts == [only: [:dev, :test], runtime: false]
  end

  test "rejects an overlay whose content no longer matches its address", context do
    root = temporary_directory!(context)
    state_root = Path.join(root, "operator-state")
    initialize_repository!(Path.join(root, "core"))
    initialize_repository!(Path.join(root, "consumer"), ~s([{:core, path: "../core"}]))

    assert {:ok, activation} =
             Overlay.activate(registry(root), "consumer", state_root: state_root)

    File.chmod!(activation.path, 0o600)
    File.write!(activation.path, File.read!(activation.path) <> "tampered\n")

    assert {:error, {:overlay_digest_mismatch, _expected, _actual}} =
             Overlay.read(activation.path)
  end

  test "a migrated project keeps lock, deps, build, and Hex state outside its checkout",
       context do
    root = temporary_directory!(context)
    state_root = Path.join(root, "operator-state")
    initialize_repository!(Path.join(root, "core"))
    consumer = initialize_repository!(Path.join(root, "consumer"))
    File.write!(Path.join(consumer, "mix.lock"), "%{}\n")

    File.write!(Path.join(consumer, "mix.exs"), """
    if bootstrap = System.get_env("MIX_WORKSPACE_OPS_BOOTSTRAP") do
      Code.require_file(bootstrap)
    end

    defmodule Consumer.MixProject do
      use Mix.Project

      def project do
        [app: :consumer, version: "0.1.0", deps: deps()]
      end

      defp deps do
        [workspace_dep({:core, ">= 0.0.0"})]
      end

      defp workspace_dep(committed) do
        if function_exported?(MixWorkspaceOpsBootstrap, :dep, 2),
          do: apply(MixWorkspaceOpsBootstrap, :dep, [committed, __DIR__]),
          else: committed
      end
    end
    """)

    assert {:ok, activation} =
             Overlay.activate(registry(root), "consumer", state_root: state_root)

    assert {_output, 0} =
             System.cmd("mix", ["deps.get"],
               cd: consumer,
               env: activation.env,
               stderr_to_stdout: true
             )

    assert File.read!(Path.join(consumer, "mix.lock")) == "%{}\n"
    refute File.exists?(Path.join(consumer, "deps"))
    refute File.exists?(Path.join(consumer, "_build"))
    assert File.dir?(activation.report.runtime.deps_path)
    assert File.dir?(activation.report.runtime.build_root)
    assert File.dir?(activation.report.runtime.hex_cache)
    assert File.read!(activation.report.runtime.lockfile) == "%{}\n"
  end

  defp registry(root, opts \\ []) do
    declaration =
      Keyword.get(opts, :declaration, %{
        "github" => %{"repo" => "example-org/core", "branch" => "main"},
        "hex" => "~> 1.0"
      })

    spare =
      if Keyword.get(opts, :spare, false),
        do: [catalog_repository("spare", projects: [catalog_project("spare")])],
        else: []

    root
    |> write_catalog!(
      [
        catalog_repository("core", projects: [catalog_project("core")]),
        catalog_repository("consumer",
          projects: [catalog_project("consumer")],
          dependency_sources: %{"core" => declaration}
        )
      ] ++ spare
    )
    |> Registry.load!()
    |> bind!(root)
  end

  defp runtime_writable_paths(report) do
    ~w(root home config_home lockfile source_lock)a
    |> Enum.map(&Map.fetch!(report, &1))
  end
end
