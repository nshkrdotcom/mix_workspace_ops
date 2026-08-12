defmodule MixWorkspaceOps.Release.DescriptorTest do
  use MixWorkspaceOps.WorkspaceCase, async: true

  alias MixWorkspaceOps.Release.Descriptor

  test "accepts one exact fail-closed descriptor schema", context do
    root = temporary_directory!(context)
    path = Path.join(root, "release.json")

    File.write!(
      path,
      :json.encode(%{
        "schema" => "mix_workspace_ops.release/v1",
        "repository" => root,
        "project_path" => ".",
        "package" => "sample_package",
        "version" => "1.2.0",
        "tag" => "v1.2.0",
        "default_branch" => "main",
        "gates" => [["mix", "test"]],
        "publisher_prefix" => ["/operator/with_secrets"]
      })
    )

    assert {:ok, plan} = Descriptor.load(path)
    assert plan.package == "sample_package"
    assert plan.gates == [["mix", "test"]]
  end

  test "rejects a tag that does not name the exact version", context do
    root = temporary_directory!(context)
    path = Path.join(root, "release.json")

    File.write!(
      path,
      :json.encode(%{
        "schema" => "mix_workspace_ops.release/v1",
        "repository" => root,
        "project_path" => ".",
        "package" => "sample_package",
        "version" => "1.2.0",
        "tag" => "v1.3.0",
        "default_branch" => "main",
        "gates" => [["mix", "test"]],
        "publisher_prefix" => ["/operator/with_secrets"]
      })
    )

    assert {:error, :tag_must_match_version} = Descriptor.load(path)
  end

  test "rejects empty gates and a PATH-resolved publisher", context do
    root = temporary_directory!(context)
    path = Path.join(root, "release.json")

    base = %{
      "schema" => "mix_workspace_ops.release/v1",
      "repository" => root,
      "project_path" => ".",
      "package" => "sample_package",
      "version" => "1.2.0",
      "tag" => "v1.2.0",
      "default_branch" => "main",
      "gates" => [],
      "publisher_prefix" => ["with_secrets"]
    }

    File.write!(path, :json.encode(base))
    assert {:error, {:invalid_argv_list, :gates}} = Descriptor.load(path)

    File.write!(path, :json.encode(%{base | "gates" => [["mix", "test"]]}))
    assert {:error, :publisher_executable_must_be_absolute} = Descriptor.load(path)
  end
end
