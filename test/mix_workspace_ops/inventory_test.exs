defmodule MixWorkspaceOps.InventoryTest do
  use MixWorkspaceOps.WorkspaceCase, async: true

  alias MixWorkspaceOps.{Inventory, Registry}

  test "scans only repositories admitted by a bound registry", context do
    root = temporary_directory!(context)
    alpha = initialize_repository!(Path.join(root, "alpha"))
    private = Path.join(root, "private")
    File.mkdir_p!(Path.join(private, "build_support"))
    File.write!(Path.join(private, "build_support/dependency_sources.exs"), "private")
    helper = Path.join(alpha, "build_support")
    File.mkdir_p!(helper)
    File.write!(Path.join(helper, "dependency_sources.exs"), "canonical")

    registry_path = write_registry!(root, [repository("alpha", [project("alpha")])])
    registry = registry_path |> Registry.load!() |> bind!(root)

    assert {:ok, [row]} = Inventory.scan_registry(registry)
    assert row.repository_root == alpha
    assert row.helper_path == Path.join(helper, "dependency_sources.exs")
  end

  test "prunes archived dependency helpers", context do
    root = temporary_directory!(context)
    alpha = initialize_repository!(Path.join(root, "alpha"))
    archived = Path.join(alpha, "_legacy/deps_legacy_20260302/copied/build_support")
    File.mkdir_p!(archived)
    File.write!(Path.join(archived, "dependency_sources.exs"), "archived")

    registry_path = write_registry!(root, [repository("alpha", [project("alpha")])])
    registry = registry_path |> Registry.load!() |> bind!(root)

    assert {:ok, []} = Inventory.scan_registry(registry)
  end
end
