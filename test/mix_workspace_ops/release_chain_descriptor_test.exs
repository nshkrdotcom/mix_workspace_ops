defmodule MixWorkspaceOps.Release.ChainDescriptorTest do
  use MixWorkspaceOps.WorkspaceCase, async: true

  alias MixWorkspaceOps.Release.Descriptor

  test "loads one exact chain descriptor without repository identity overrides", context do
    root = temporary_directory!(context)
    path = Path.join(root, "release-chain.json")
    digest = String.duplicate("a", 64)

    File.write!(
      path,
      :json.encode(%{
        "schema" => "mix_workspace_ops.release_descriptor/v2",
        "release_plan_digest" => digest,
        "registry_digest" => String.duplicate("b", 64),
        "publisher_prefix" => ["/operator/with-publish-capability"],
        "packages" => %{
          "sample_package" => %{
            "version" => "1.2.3",
            "tag" => "v1.2.3",
            "gates" => [["mix", "deps.get"], ["mix", "test"]],
            "prepared_artifact" => %{
              "expected_handoff" => Path.join(root, "release.json"),
              "prepare" => ["mix", "weld.release.prepare", "packaging/weld/sample.exs"],
              "rebuilt_handoff" => "dist/release.json"
            }
          }
        }
      })
    )

    assert {:ok, descriptor} = Descriptor.load_chain(path)
    assert descriptor.release_plan_digest == digest
    assert descriptor.publisher_prefix == ["/operator/with-publish-capability"]
    assert descriptor.packages["sample_package"].version == "1.2.3"
    refute Map.has_key?(descriptor.packages["sample_package"], :repository)
  end

  test "rejects unknown keys, path-resolved publishers and embedded credentials", context do
    root = temporary_directory!(context)
    path = Path.join(root, "release-chain.json")

    base = %{
      "schema" => "mix_workspace_ops.release_descriptor/v2",
      "release_plan_digest" => String.duplicate("a", 64),
      "registry_digest" => String.duplicate("b", 64),
      "publisher_prefix" => ["publisher"],
      "packages" => %{
        "sample_package" => %{
          "version" => "1.2.3",
          "tag" => "v1.2.3",
          "gates" => [["mix", "test"]],
          "prepared_artifact" => nil
        }
      }
    }

    File.write!(path, :json.encode(base))
    assert {:error, :publisher_executable_must_be_absolute} = Descriptor.load_chain(path)

    File.write!(
      path,
      :json.encode(%{base | "publisher_prefix" => ["/bin/env", "HEX_API_KEY=value"]})
    )

    assert {:error, :credential_embedded_in_descriptor} = Descriptor.load_chain(path)

    File.write!(path, :json.encode(Map.put(base, "repository", "/override")))
    assert {:error, :invalid_release_chain_descriptor} = Descriptor.load_chain(path)
  end
end
