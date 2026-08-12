defmodule MixWorkspaceOps.RegistryTest do
  use MixWorkspaceOps.WorkspaceCase, async: true

  alias MixWorkspaceOps.{Graph, Registry}

  test "loads, binds, and derives a dependency closure", context do
    root = temporary_directory!(context)
    initialize_repository!(Path.join(root, "core"))
    initialize_repository!(Path.join(root, "consumer"))

    registry =
      root
      |> write_registry!([
        repository("core", [project("core")]),
        repository("consumer", [project("consumer")])
      ])
      |> Registry.load!()
      |> bind!(root)

    reader = fn item -> {:ok, if(item.id == "consumer", do: ["core"], else: [])} end

    assert {:ok, resolution} = Graph.resolve(registry, "consumer", dependency_reader: reader)
    assert Enum.map(resolution.projects, & &1.id) == ["core", "consumer"]
    assert resolution.edges == [{"consumer", "core"}]
    assert Registry.project_root(registry, "consumer") == Path.join(root, "consumer")
  end

  test "rejects paths that are absolute or escape a repository", context do
    root = temporary_directory!(context)

    absolute = write_registry!(root, [repository("bad", [project("bad", nil, path: "/tmp/bad")])])
    assert {:error, {:absolute_registry_path, "/tmp/bad"}} = Registry.load(absolute)

    escaping = write_registry!(root, [repository("bad", [project("bad", nil, path: "../bad")])])
    assert {:error, {:escaping_registry_path, "../bad"}} = Registry.load(escaping)
  end

  test "records dependencies outside the registry", context do
    root = temporary_directory!(context)
    initialize_repository!(Path.join(root, "consumer"))

    registry =
      root
      |> write_registry!([repository("consumer", [project("consumer")])])
      |> Registry.load!()
      |> bind!(root)

    assert {:ok, resolution} =
             Graph.resolve(registry, "consumer",
               dependency_reader: fn _ -> {:ok, ["external"]} end
             )

    assert resolution.external_dependencies == [{"consumer", "external"}]
  end

  test "rejects generated dependency and build paths", context do
    root = temporary_directory!(context)

    for reserved <- ["deps/pkg", "_build/pkg", ".mix_workspace_ops/pkg"] do
      path = write_registry!(root, [repository("bad", [project("bad", nil, path: reserved)])])
      assert {:error, {:reserved_registry_path, ^reserved}} = Registry.load(path)
    end
  end

  test "binding rejects a checkout with the wrong origin", context do
    root = temporary_directory!(context)
    initialize_repository!(Path.join(root, "widget"), "[]", "other-org/widget")

    registry =
      root |> write_registry!([repository("widget", [project("widget")])]) |> Registry.load!()

    assert {:error, {:wrong_origin, "widget", "example-org/widget", "other-org/widget"}} =
             Registry.bind(registry, root)
  end
end
