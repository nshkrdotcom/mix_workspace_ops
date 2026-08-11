defmodule MixWorkspaceOps.OverlayTest do
  use MixWorkspaceOps.WorkspaceCase, async: true

  alias MixWorkspaceOps.{Catalog, Overlay}

  test "activates a dependency closure and restores every repository", context do
    root = temporary_directory!(context)
    initialize_repository!(Path.join(root, "core"))
    initialize_repository!(Path.join(root, "consumer"))
    catalog = catalog(root)

    assert {:ok, activation} = Overlay.activate(catalog, :consumer)
    assert activation.report.projects == ["core", "consumer"]

    for repository <- ["core", "consumer"] do
      assert {:ok, overlay} = Overlay.read(Path.join(root, repository))
      assert Map.keys(overlay.sources) == ["consumer", "core"]
      assert overlay.sources["core"].path == Path.join(root, "core")
    end

    assert :ok = Overlay.restore(activation)

    refute File.exists?(Path.join(root, "core/#{Overlay.relative_path()}"))
    refute File.exists?(Path.join(root, "consumer/#{Overlay.relative_path()}"))
  end

  test "restores pre-existing overlay bytes after a raised operation", context do
    root = temporary_directory!(context)
    initialize_repository!(Path.join(root, "core"))
    initialize_repository!(Path.join(root, "consumer"))
    catalog = catalog(root)
    path = Path.join(root, "consumer/#{Overlay.relative_path()}")
    File.mkdir_p!(Path.dirname(path))
    original = "operator-owned bytes\n"
    File.write!(path, original)

    assert_raise RuntimeError, "stop", fn ->
      Overlay.with_activation(catalog, :consumer, [], fn _report -> raise "stop" end)
    end

    assert File.read!(path) == original
  end

  test "hex mode temporarily removes and restores a recognized overlay", context do
    root = temporary_directory!(context)
    initialize_repository!(Path.join(root, "core"))
    initialize_repository!(Path.join(root, "consumer"))
    catalog = catalog(root)
    assert {:ok, local_activation} = Overlay.activate(catalog, :consumer)

    Overlay.with_activation(catalog, :consumer, [mode: :hex], fn report ->
      assert report.mode == :hex
      refute File.exists?(Path.join(root, "consumer/#{Overlay.relative_path()}"))
    end)

    assert {:ok, %{mode: "local"}} = Overlay.read(Path.join(root, "consumer"))
    assert :ok = Overlay.restore(local_activation)
  end

  defp catalog(root) do
    root
    |> write_catalog!([
      repository("core", "core", [project("core", [])]),
      repository("consumer", "consumer", [project("consumer", ["core"])])
    ])
    |> Catalog.load!(root: root)
  end

  defp repository(id, path, projects) do
    %{
      "id" => id,
      "path" => path,
      "github" => "nshkrdotcom/#{id}",
      "status" => "pilot",
      "projects" => projects
    }
  end

  defp project(app, dependencies) do
    %{"app" => app, "path" => ".", "managed_deps" => dependencies}
  end
end
