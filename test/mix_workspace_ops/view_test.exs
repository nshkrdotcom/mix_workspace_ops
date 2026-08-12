defmodule MixWorkspaceOps.ViewTest do
  use MixWorkspaceOps.WorkspaceCase, async: true

  alias MixWorkspaceOps.{Registry, View}

  test "selects a tag-based view without copying project rows", context do
    root = temporary_directory!(context)

    registry =
      root
      |> write_registry!([
        repository("alpha", [project("alpha", nil, tags: ["platform"])]),
        repository("beta", [project("beta", nil, tags: ["library"])])
      ])
      |> Registry.load!()

    view_path = Path.join(root, "view.json")

    File.write!(
      view_path,
      :json.encode(%{
        "schema" => "mix_workspace_ops.view/v1",
        "id" => "platform",
        "description" => "Synthetic platform view",
        "selector" => %{
          "tags_any" => ["platform"],
          "tags_all" => [],
          "project_ids" => [],
          "exclude_project_ids" => []
        }
      })
    )

    assert {:ok, view} = View.load(view_path)
    assert {:ok, [project]} = View.select(registry, view)
    assert project.id == "alpha"
  end
end
