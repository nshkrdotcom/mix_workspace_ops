defmodule MixWorkspaceOps.ViewTest do
  use MixWorkspaceOps.WorkspaceCase, async: true

  alias MixWorkspaceOps.{Registry, View}

  test "selects a canonical v2 view and rejects legacy v1", context do
    root = temporary_directory!(context)

    registry =
      root
      |> write_catalog!([
        catalog_repository("alpha", groups: ["platform"], projects: [catalog_project("alpha")]),
        catalog_repository("beta", groups: ["library"], projects: [catalog_project("beta")])
      ])
      |> Registry.load!()

    view_path = write_catalog_view!(root, "platform", %{"groups_any" => ["platform"]})
    assert {:ok, view} = View.load(view_path)
    assert view.schema == "portfolio_registry.view/v2"
    assert {:ok, [%{id: "alpha"}]} = View.select(registry, view)

    legacy = Path.join(root, "legacy-view.json")
    File.write!(legacy, :json.encode(%{
      "schema" => "mix_workspace_ops.view/v1",
      "id" => "legacy",
      "description" => "unsupported",
      "selector" => %{}
    }))
    assert {:error, :unsupported_view_schema} = View.load(legacy)
  end
end
