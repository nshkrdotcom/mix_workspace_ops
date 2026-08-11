defmodule MixWorkspaceOps.CatalogTest do
  use MixWorkspaceOps.WorkspaceCase, async: true

  alias MixWorkspaceOps.{Catalog, Graph}

  test "loads a literal catalog and orders a dependency closure", context do
    root = temporary_directory!(context)
    initialize_repository!(Path.join(root, "core"))
    initialize_repository!(Path.join(root, "consumer"))

    catalog =
      root
      |> write_catalog!([
        repository("core", "core", [project("core", [])]),
        repository("consumer", "consumer", [project("consumer", ["core"])])
      ])
      |> Catalog.load!(root: root)

    assert Enum.map(Graph.closure(catalog, "consumer"), & &1.app) == ["core", "consumer"]
    assert Catalog.project_root(catalog, :consumer) == Path.join(root, "consumer")
    assert Catalog.repository_root(catalog, "core") == Path.join(root, "core")
  end

  test "rejects paths that are absolute or escape the catalog root", context do
    root = temporary_directory!(context)

    absolute = write_catalog!(root, [repository("bad", "/tmp/bad", [project("bad", [])])])
    assert {:error, {:absolute_catalog_path, "/tmp/bad"}} = Catalog.load(absolute, root: root)

    escaping = write_catalog!(root, [repository("bad", "../workspace2", [project("bad", [])])])

    assert {:error, {:escaping_catalog_path, "../workspace2"}} =
             Catalog.load(escaping, root: root)
  end

  test "rejects unknown dependency edges", context do
    root = temporary_directory!(context)
    path = write_catalog!(root, [repository("consumer", ".", [project("consumer", ["gone"])])])

    assert {:error, {:unknown_managed_dependencies, [{"consumer", "gone"}]}} =
             Catalog.load(path, root: root)
  end

  test "rejects generated dependency and build paths", context do
    root = temporary_directory!(context)

    for reserved <- ["deps/pkg", "_build/pkg", ".mix_workspace_ops/pkg"] do
      path = write_catalog!(root, [repository("bad", reserved, [project("bad", [])])])
      assert {:error, {:reserved_catalog_path, ^reserved}} = Catalog.load(path, root: root)
    end
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
