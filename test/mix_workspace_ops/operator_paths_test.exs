defmodule MixWorkspaceOps.OperatorPathsTest do
  use MixWorkspaceOps.WorkspaceCase, async: false

  alias MixWorkspaceOps.OperatorPaths

  setup do
    original_cwd = File.cwd!()
    original_xdg = System.get_env("XDG_CONFIG_HOME")
    original_registry = System.get_env("MIX_WORKSPACE_OPS_REGISTRY")
    original_checkout = System.get_env("MIX_WORKSPACE_OPS_CHECKOUT_ROOT")

    on_exit(fn ->
      File.cd!(original_cwd)
      restore("XDG_CONFIG_HOME", original_xdg)
      restore("MIX_WORKSPACE_OPS_REGISTRY", original_registry)
      restore("MIX_WORKSPACE_OPS_CHECKOUT_ROOT", original_checkout)
    end)

    :ok
  end

  test "flags, environment, config, and upward discovery have one order", context do
    root = temporary_directory!(context)
    checkout = initialize_repository!(Path.join(root, "alpha"))
    nested = Path.join(checkout, "lib")
    File.mkdir_p!(nested)
    File.write!(Path.join(checkout, "registry.json"), "{}")
    config_home = Path.join(root, "config")
    config_dir = Path.join(config_home, "mix_workspace_ops")
    File.mkdir_p!(config_dir)

    File.write!(
      Path.join(config_dir, "config.json"),
      ~s({"registry":"configured.json","checkout_root":"configured"})
    )

    System.put_env("XDG_CONFIG_HOME", config_home)
    File.cd!(nested)

    assert {:ok, configured} = OperatorPaths.resolve(%{}, [:registry, :checkout_root])
    assert configured.registry == Path.join(config_dir, "configured.json")
    assert configured.checkout_root == Path.join(config_dir, "configured")

    System.put_env("MIX_WORKSPACE_OPS_REGISTRY", Path.join(root, "environment.json"))
    assert {:ok, environment} = OperatorPaths.resolve(%{}, [:registry])
    assert environment.registry == Path.join(root, "environment.json")

    assert {:ok, explicit} =
             OperatorPaths.resolve(%{registry: Path.join(root, "flag.json")}, [:registry])

    assert explicit.registry == Path.join(root, "flag.json")

    File.rm!(Path.join(config_dir, "config.json"))
    System.delete_env("MIX_WORKSPACE_OPS_REGISTRY")
    assert {:ok, discovered} = OperatorPaths.resolve(%{}, [:registry, :checkout_root])
    assert discovered.registry == Path.join(checkout, "registry.json")
    assert discovered.checkout_root == root
  end

  defp restore(name, nil), do: System.delete_env(name)
  defp restore(name, value), do: System.put_env(name, value)
end
