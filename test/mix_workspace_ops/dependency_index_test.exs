defmodule MixWorkspaceOps.DependencyIndexTest do
  use MixWorkspaceOps.WorkspaceCase, async: true

  alias MixWorkspaceOps.{DependencyIndex, Registry}

  test "dependency truth comes from Mix dependency reader, never registry source rows", context do
    root = temporary_directory!(context)
    for id <- ~w(core consumer), do: File.mkdir_p!(Path.join(root, id))

    registry =
      root
      |> write_catalog!([
        catalog_repository("core", projects: [catalog_project("core")]),
        catalog_repository("consumer",
          projects: [catalog_project("consumer")],
          dependency_sources: %{
            "core" => %{"hex" => "~> 1.0"},
            "declared_but_unused" => %{"hex" => "~> 9.0"}
          }
        )
      ])
      |> Registry.load!()
      |> then(&%{&1 | bindings: %{"core" => Path.join(root, "core"), "consumer" => Path.join(root, "consumer")}})

    reader = fn
      %{id: "consumer"}, _opts -> {:ok, ["core", "external_dep"]}
      _project, _opts -> {:ok, []}
    end

    assert {:ok, index} = DependencyIndex.build(registry, dependency_reader: reader)
    assert index.complete

    assert %{classification: :managed, provider: "core"} =
             Enum.find(index.edges, &(&1.application == "core"))

    assert %{classification: :external} =
             Enum.find(index.edges, &(&1.application == "external_dep"))

    refute Enum.any?(index.edges, &(&1.application == "declared_but_unused"))
  end

  test "absence is a coverage gap rather than an empty dependency list", context do
    root = temporary_directory!(context)
    File.mkdir_p!(Path.join(root, "consumer"))

    registry =
      root
      |> write_catalog!([
        catalog_repository("core", projects: [catalog_project("core")]),
        catalog_repository("consumer", projects: [catalog_project("consumer")])
      ])
      |> Registry.load!()
      |> then(&%{&1 | bindings: %{"consumer" => Path.join(root, "consumer")}, absent_checkouts: %{"core" => Path.join(root, "core")}})

    assert {:ok, index} =
             DependencyIndex.build(registry, dependency_reader: fn _project, _opts -> {:ok, []} end)

    refute index.complete
    assert index.absent_projects == ["core"]
    assert DependencyIndex.coverage(index).complete == false
  end
end
