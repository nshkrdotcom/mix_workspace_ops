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
    assert {"MIX_BUILD_ROOT", activation.report.runtime.build_root} in activation.env
    assert {"HEX_HOME", activation.report.runtime.hex_home} in activation.env

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

  test "delegated execution carries source context but allocates no child Mix state", context do
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

    refute Enum.any?(activation.env, fn {key, _value} ->
             key in ~w(MIX_DEPS_PATH MIX_BUILD_ROOT HEX_HOME MIX_WORKSPACE_OPS_LOCKFILE)
           end)
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

    File.write!(Path.join(root, "consumer/target-change.txt"), "owned by target impact logic\n")
    assert {:ok, target_changed} = Overlay.activate(registry, "consumer", state_root: state_root)
    refute target_changed.path == first.path
    assert target_changed.report.context_digest == first.report.context_digest

    File.write!(Path.join(root, "core/uncommitted.txt"), "changed source\n")
    assert {:ok, dirty} = Overlay.activate(registry, "consumer", state_root: state_root)
    refute dirty.path == first.path
    refute dirty.report.context_digest == first.report.context_digest

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

    # Same catalog, same rows, different view: two identities, not one.
    assert Map.keys(unselected.sources) == Map.keys(selected.sources)
    refute whole.path == viewed.path
    refute whole.report.context_digest == viewed.report.context_digest
  end

  test "a mode naming a source the catalog cannot reach is a typed error", context do
    root = temporary_directory!(context)
    state_root = Path.join(root, "operator-state")
    initialize_repository!(Path.join(root, "core"))
    initialize_repository!(Path.join(root, "consumer"), ~s([{:core, path: "../core"}]))
    registry = registry(root, declaration: %{"order" => ["local"]})

    assert {:error, {:unavailable_run_mode, "hex", ["core"]}} =
             Overlay.activate(registry, "consumer", mode: :hex, state_root: state_root)

    # `git` is the one mode that always has an answer: the catalog knows the
    # provider's repository, and an explicit request falls back to it.
    assert {:ok, activation} =
             Overlay.activate(registry, "consumer", mode: :git, state_root: state_root)

    assert {:ok, overlay} = Overlay.read(activation.path)
    assert overlay.sources["core"].kind == :github
    assert overlay.sources["core"].repo == "example-org/core"
    assert overlay.sources["core"].revision_kind == "ref"
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
    IO.inspect(MixWorkspaceOpsBootstrap.dep(:core, "~> 1.0", #{inspect(Path.join(root, "consumer"))}, []))
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
        [app: :consumer, version: "0.1.0", deps: deps()] ++
          workspace_project_options()
      end

      defp deps do
        [workspace_dep(:core, ">= 0.0.0")]
      end

      defp workspace_dep(app, requirement) do
        case Code.ensure_loaded(MixWorkspaceOpsBootstrap) do
          {:module, module} -> apply(module, :dep, [app, requirement, __DIR__, []])
          _other -> {app, requirement}
        end
      end

      defp workspace_project_options do
        case Code.ensure_loaded(MixWorkspaceOpsBootstrap) do
          {:module, module} -> apply(module, :project_options, [__DIR__])
          _other -> []
        end
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
    assert File.dir?(activation.report.runtime.hex_home)
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
end
