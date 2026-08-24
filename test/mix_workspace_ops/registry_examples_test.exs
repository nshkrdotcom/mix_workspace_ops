defmodule MixWorkspaceOps.RegistryExamplesTest do
  use MixWorkspaceOps.WorkspaceCase, async: true

  alias MixWorkspaceOps.CLI
  alias MixWorkspaceOps.Registry.Examples

  test "a guide's examples assemble into one document that validates", context do
    guide = write_guide!(context, [document(), core_record(), sources_record()])

    assert {:ok, report} = Examples.validate(guide)
    assert report.schema == "mix_workspace_ops.examples/v1"
    assert report.document_schema == "portfolio_registry.registry/v2"
    assert report.examples == 3
    assert report.documents == 1
    assert report.records == 2
    assert report.repositories == 2
    assert report.projects == 2
    assert report.release_packages == 1
  end

  test "an example whose dependency source names no catalogued provider is refused",
       context do
    guide = write_guide!(context, [document(), sources_record()])

    assert {:error, {:dependency_source, "alpha", {:unprovided_application, "core"}}} =
             Examples.validate(guide)
  end

  test "a record carrying only the fields its passage is about merges into the whole",
       context do
    guide =
      write_guide!(context, [
        document(),
        ~s({"id": "alpha", "mix": {"workspace": {"kind": "blitz"}}})
      ])

    assert {:ok, report} = Examples.validate(guide)
    assert report.workspaces == 1
    assert report.repositories == 1
  end

  test "a block claiming to be a whole document is held to that claim alone", context do
    guide =
      write_guide!(context, [
        document(),
        ~s({"schema": "portfolio_registry.registry/v2", "repositories": [], "extra": 1})
      ])

    assert {:error, {:invalid_example, 2, :unsupported_registry_schema}} =
             Examples.validate(guide)
  end

  test "a view example is loaded as a view", context do
    guide =
      write_guide!(context, [
        ~s({"schema": "portfolio_registry.view/v2", "id": "all",) <>
          ~s( "description": "Everything.", "selector": {}})
      ])

    assert {:ok, report} = Examples.validate(guide)
    assert report.views == 1
    assert report.repositories == 0
  end

  test "a block addressed to nothing is refused", context do
    guide = write_guide!(context, [document(), ~s({"kind": "blitz"})])

    assert {:error, {:unaddressed_example, 2}} = Examples.validate(guide)
  end

  test "a documentation file carrying no example is refused", context do
    root = temporary_directory!(context)
    path = Path.join(root, "empty.md")
    File.write!(path, "# Nothing here\n\nProse only.\n")

    assert {:error, {:no_examples, ^path}} = Examples.validate(path)
  end

  test "registry examples reports the guide it validated", context do
    guide = write_guide!(context, [document(), core_record(), sources_record()])

    assert {:ok, report} = CLI.dispatch(["registry", "examples", "--guide", guide])
    assert report.guide == guide
    assert report.examples == 3

    assert CLI.dispatch(["registry", "examples"]) == {:usage_error, "missing --guide"}
  end

  defp write_guide!(context, blocks) do
    root = temporary_directory!(context)
    path = Path.join(root, "guide.md")

    body =
      Enum.map_join(blocks, "\n", fn block ->
        "Prose about it.\n\n```json\n#{block}\n```\n"
      end)

    File.write!(path, "# Guide\n\n" <> body)
    path
  end

  defp document do
    ~s({"schema": "portfolio_registry.registry/v2", "repositories": [) <>
      ~s({"id": "alpha", "github": "example-org/alpha", "default_branch": "main",) <>
      ~s( "languages": ["elixir"], "lifecycle": "active", "disposition": "tracked",) <>
      ~s( "visibility": "public", "roles": [], "groups": ["family.alpha"],) <>
      ~s( "agent_scope": "eligible", "mix": {"projects": [) <>
      ~s({"id": "alpha", "app": "alpha", "path": ".", "kind": "standalone"}]},) <>
      ~s( "release_chain": {"alpha": []}}]})
  end

  defp core_record do
    ~s({"id": "core", "github": "example-org/core", "default_branch": "main",) <>
      ~s( "languages": ["elixir"], "lifecycle": "active", "disposition": "tracked",) <>
      ~s( "visibility": "public", "roles": [], "groups": ["family.core"],) <>
      ~s( "agent_scope": "eligible", "mix": {"projects": [) <>
      ~s({"id": "core", "app": "core", "path": ".", "kind": "standalone"}]}})
  end

  defp sources_record do
    ~s({"id": "alpha", "dependency_sources": {"core": {"hex": "~> 0.1.0"}}})
  end
end
