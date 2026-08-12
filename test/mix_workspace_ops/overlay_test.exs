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
    assert {"MIX_DEPS_PATH", activation.report.runtime.deps_path} in activation.env
    assert {"MIX_BUILD_ROOT", activation.report.runtime.build_root} in activation.env
    assert {"HEX_HOME", activation.report.runtime.hex_home} in activation.env

    assert {"MIX_WORKSPACE_OPS_LOCKFILE", activation.report.runtime.lockfile} in activation.env

    assert String.starts_with?(activation.path, state_root)
    assert String.starts_with?(activation.report.runtime.root, state_root)
    assert File.read!(activation.report.runtime.lockfile) == "%{}\n"
    assert {:ok, overlay} = Overlay.read(activation.path)
    assert Map.keys(overlay.sources) == ["consumer", "core"]
    assert overlay.sources["core"].path == Path.join(root, "core")
    assert is_binary(overlay.sources["core"].source_digest)

    refute File.exists?(Path.join(root, "core/.mix_workspace_ops"))
    refute File.exists?(Path.join(root, "consumer/.mix_workspace_ops"))
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

    File.write!(Path.join(root, "core/uncommitted.txt"), "changed source\n")
    assert {:ok, dirty} = Overlay.activate(registry, "consumer", state_root: state_root)
    refute dirty.path == first.path

    assert {:ok, git} = Overlay.activate(registry, "consumer", mode: :git, state_root: state_root)
    refute git.path == first.path

    assert {:ok, hex} = Overlay.activate(registry, "consumer", mode: :hex, state_root: state_root)
    assert hex.path == nil
    assert {"MIX_WORKSPACE_OPS_OVERLAY", nil} in hex.env
    assert {"MIX_DEPS_PATH", hex.report.runtime.deps_path} in hex.env
    refute hex.report.runtime.root == first.report.runtime.root
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
    {:ok, bootstrap} = MixWorkspaceOps.Bootstrap.install(consumer)
    File.write!(Path.join(consumer, "mix.lock"), "%{}\n")

    File.write!(Path.join(consumer, "mix.exs"), """
    Code.require_file(#{inspect(bootstrap)})

    defmodule Consumer.MixProject do
      use Mix.Project

      def project do
        [app: :consumer, version: "0.1.0", deps: deps()] ++
          MixWorkspaceOpsBootstrap.project_options(__DIR__)
      end

      defp deps do
        [MixWorkspaceOpsBootstrap.dep(:core, ">= 0.0.0", __DIR__)]
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

  defp registry(root) do
    root
    |> write_registry!([
      repository("core", [project("core")]),
      repository("consumer", [project("consumer")])
    ])
    |> Registry.load!()
    |> bind!(root)
  end
end
