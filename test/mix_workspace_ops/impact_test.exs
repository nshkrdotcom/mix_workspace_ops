defmodule MixWorkspaceOps.ImpactTest do
  use MixWorkspaceOps.WorkspaceCase, async: true

  alias MixWorkspaceOps.{DependencyIndex, Impact, Registry, Selection}

  test "reverse impact returns direct/transitive paths and repository aggregation", context do
    {registry, root} = registry(context)

    reader = fn
      %{id: "middle"}, _opts -> {:ok, ["core"]}
      %{id: "leaf"}, _opts -> {:ok, ["middle"]}
      _project, _opts -> {:ok, []}
    end

    assert {:ok, index} = DependencyIndex.build(registry, dependency_reader: reader)
    assert {:ok, impact} = Impact.analyze(registry, index, "core")

    assert impact.direct_dependents == ["middle"]
    assert impact.transitive_dependents == ["leaf"]
    assert impact.selected_affected_projects == ["core", "leaf", "middle"]
    assert impact.paths["leaf"] == ["leaf", "middle", "core"]
    assert impact.safe_affected_only
    assert Enum.map(impact.affected_repositories, & &1.repository) == ["core", "leaf", "middle"]
    assert File.dir?(root)
  end

  test "affected selection widens to the complete base scope when coverage is incomplete",
       context do
    {registry, _root} = registry(context)

    registry = %{
      registry
      | absent_checkouts: %{"leaf" => "/absent/leaf"},
        bindings: Map.delete(registry.bindings, "leaf")
    }

    reader = fn
      %{id: "middle"}, _opts -> {:ok, ["core"]}
      _project, _opts -> {:ok, []}
    end

    assert {:ok, index} = DependencyIndex.build(registry, dependency_reader: reader)
    refute index.complete
    assert {:ok, selection} = Selection.affected(registry, index, "core")
    assert selection.fallback_to_full_scope
    assert selection.fallback_reason == :dependency_index_incomplete
    assert selection.projects == index.selected_projects
  end

  defp registry(context) do
    root = temporary_directory!(context)
    for id <- ~w(core middle leaf), do: File.mkdir_p!(Path.join(root, id))

    registry =
      root
      |> write_catalog!([
        catalog_repository("core", projects: [catalog_project("core")]),
        catalog_repository("middle",
          projects: [catalog_project("middle")],
          dependency_sources: %{"core" => %{"hex" => "~> 1.0"}}
        ),
        catalog_repository("leaf",
          projects: [catalog_project("leaf")],
          dependency_sources: %{"middle" => %{"hex" => "~> 1.0"}}
        )
      ])
      |> Registry.load!()
      |> then(fn registry ->
        %{registry | bindings: Map.new(~w(core middle leaf), &{&1, Path.join(root, &1)})}
      end)

    {registry, root}
  end
end
