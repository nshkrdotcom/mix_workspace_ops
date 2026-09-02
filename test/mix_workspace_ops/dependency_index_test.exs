defmodule MixWorkspaceOps.DependencyIndexTest do
  use MixWorkspaceOps.WorkspaceCase, async: true

  alias MixWorkspaceOps.{DependencyIndex, Registry}

  test "dependency truth comes from Mix dependency reader, never registry source rows", context do
    root = temporary_directory!(context)
    for id <- ~w(core consumer declared_but_unused), do: File.mkdir_p!(Path.join(root, id))

    registry =
      root
      |> write_catalog!([
        catalog_repository("core", projects: [catalog_project("core")]),
        catalog_repository("declared_but_unused",
          projects: [catalog_project("declared_but_unused")]
        ),
        catalog_repository("consumer",
          projects: [catalog_project("consumer")],
          dependency_sources: %{
            "core" => %{"hex" => "~> 1.0"},
            "declared_but_unused" => %{"hex" => "~> 9.0"}
          }
        )
      ])
      |> Registry.load!()
      |> then(
        &%{
          &1
          | bindings: %{
              "core" => Path.join(root, "core"),
              "consumer" => Path.join(root, "consumer"),
              "declared_but_unused" => Path.join(root, "declared_but_unused")
            }
        }
      )

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
      |> then(
        &%{
          &1
          | bindings: %{"consumer" => Path.join(root, "consumer")},
            absent_checkouts: %{"core" => Path.join(root, "core")}
        }
      )

    assert {:ok, index} =
             DependencyIndex.build(registry,
               dependency_reader: fn _project, _opts -> {:ok, []} end
             )

    refute index.complete
    assert index.absent_projects == ["core"]
    assert DependencyIndex.coverage(index).complete == false
  end

  test "a catalogued application without a source declaration remains external", context do
    root = temporary_directory!(context)
    for id <- ~w(core consumer), do: File.mkdir_p!(Path.join(root, id))

    registry =
      root
      |> write_catalog!([
        catalog_repository("core", projects: [catalog_project("core")]),
        catalog_repository("consumer", projects: [catalog_project("consumer")])
      ])
      |> Registry.load!()
      |> then(fn registry ->
        %{registry | bindings: Map.new(~w(core consumer), &{&1, Path.join(root, &1)})}
      end)

    reader = fn
      %{id: "consumer"}, _opts -> {:ok, ["core"]}
      _project, _opts -> {:ok, []}
    end

    assert {:ok, index} = DependencyIndex.build(registry, dependency_reader: reader)

    assert %{classification: :external, provider: nil} =
             Enum.find(index.edges, &(&1.application == "core"))
  end

  test "an undeclared provider in the consumer repository keeps its managed identity", context do
    root = temporary_directory!(context)
    File.mkdir_p!(Path.join(root, "workspace"))

    registry =
      root
      |> write_catalog!([
        catalog_repository("workspace",
          projects: [
            catalog_project("workspace.consumer", app: "consumer"),
            catalog_project("workspace.core", app: "core")
          ]
        )
      ])
      |> Registry.load!()
      |> then(fn registry ->
        %{registry | bindings: %{"workspace" => Path.join(root, "workspace")}}
      end)

    reader = fn
      %{id: "workspace.consumer"}, _opts -> {:ok, ["core"]}
      _project, _opts -> {:ok, []}
    end

    assert {:ok, index} = DependencyIndex.build(registry, dependency_reader: reader)

    assert %{classification: :managed, provider: "workspace.core"} =
             Enum.find(index.edges, &(&1.application == "core"))
  end
end
