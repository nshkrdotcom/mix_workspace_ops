defmodule MixWorkspaceOps.OperatorPathsTest do
  use MixWorkspaceOps.WorkspaceCase, async: false

  alias MixWorkspaceOps.{OperatorLedger, OperatorPaths}

  setup do
    original_cwd = File.cwd!()
    original_xdg = System.get_env("XDG_CONFIG_HOME")
    original_registry = System.get_env("MIX_WORKSPACE_OPS_REGISTRY")
    original_checkout = System.get_env("MIX_WORKSPACE_OPS_CHECKOUT_ROOT")
    original_ledger = System.get_env("MIX_WORKSPACE_OPS_LEDGER")

    on_exit(fn ->
      File.cd!(original_cwd)
      restore("XDG_CONFIG_HOME", original_xdg)
      restore("MIX_WORKSPACE_OPS_REGISTRY", original_registry)
      restore("MIX_WORKSPACE_OPS_CHECKOUT_ROOT", original_checkout)
      restore("MIX_WORKSPACE_OPS_LEDGER", original_ledger)
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
      ~s({"registry":"configured.json","checkout_root":"configured","ledger":"ledger.json"})
    )

    System.put_env("XDG_CONFIG_HOME", config_home)
    File.cd!(nested)

    assert {:ok, configured} = OperatorPaths.resolve(%{}, [:registry, :checkout_root, :ledger])
    assert configured.registry == Path.join(config_dir, "configured.json")
    assert configured.checkout_root == Path.join(config_dir, "configured")
    assert configured.ledger == Path.join(config_dir, "ledger.json")

    System.put_env("MIX_WORKSPACE_OPS_REGISTRY", Path.join(root, "environment.json"))
    assert {:ok, environment} = OperatorPaths.resolve(%{}, [:registry])
    assert environment.registry == Path.join(root, "environment.json")

    assert {:ok, explicit} =
             OperatorPaths.resolve(%{registry: Path.join(root, "flag.json")}, [:registry])

    assert explicit.registry == Path.join(root, "flag.json")

    File.rm!(Path.join(config_dir, "config.json"))
    System.delete_env("MIX_WORKSPACE_OPS_REGISTRY")
    default_ledger = OperatorLedger.default_path()
    File.write!(default_ledger, "{}")

    assert {:ok, discovered} =
             OperatorPaths.resolve(%{}, [:registry, :checkout_root, :ledger])

    assert discovered.registry == Path.join(checkout, "registry.json")
    assert discovered.checkout_root == root
    assert discovered.ledger == default_ledger
  end

  test "an empty config requests the ordinary discovery fallbacks", context do
    root = temporary_directory!(context)
    checkout = initialize_repository!(Path.join(root, "alpha"))
    File.write!(Path.join(checkout, "registry.json"), "{}")
    config_home = Path.join(root, "config")
    config_dir = Path.join(config_home, "mix_workspace_ops")
    File.mkdir_p!(config_dir)
    File.write!(Path.join(config_dir, "config.json"), "{}")

    System.put_env("XDG_CONFIG_HOME", config_home)
    File.cd!(checkout)

    assert {:ok, paths} = OperatorPaths.resolve(%{}, [:registry, :checkout_root])
    assert paths.registry == Path.join(checkout, "registry.json")
    assert paths.checkout_root == root
  end

  test "malformed config is an error rather than silent discovery", context do
    root = temporary_directory!(context)
    checkout = initialize_repository!(Path.join(root, "alpha"))
    File.write!(Path.join(checkout, "registry.json"), "{}")
    config_home = Path.join(root, "config")
    config_dir = Path.join(config_home, "mix_workspace_ops")
    config_path = Path.join(config_dir, "config.json")
    File.mkdir_p!(config_dir)
    System.put_env("XDG_CONFIG_HOME", config_home)
    File.cd!(checkout)

    File.write!(config_path, "not-json")

    assert {:error, {:operator_config, ^config_path, {:invalid_json, _reason}}} =
             OperatorPaths.resolve(%{}, [:registry])

    File.write!(config_path, "[]")

    assert {:error, {:operator_config, ^config_path, :expected_object}} =
             OperatorPaths.resolve(%{}, [:registry])

    File.write!(config_path, ~s({"registry":""}))

    assert {:error, {:operator_config, ^config_path, :paths_must_be_non_empty_strings}} =
             OperatorPaths.resolve(%{}, [:registry])
  end

  test "a configured nonexistent path remains explicit", context do
    root = temporary_directory!(context)
    config_home = Path.join(root, "config")
    config_dir = Path.join(config_home, "mix_workspace_ops")
    config_path = Path.join(config_dir, "config.json")
    File.mkdir_p!(config_dir)
    File.write!(config_path, ~s({"registry":"absent.json"}))
    System.put_env("XDG_CONFIG_HOME", config_home)

    assert {:ok, paths} = OperatorPaths.resolve(%{}, [:registry])
    assert paths.registry == Path.join(config_dir, "absent.json")
    refute File.exists?(paths.registry)
  end

  defp restore(name, nil), do: System.delete_env(name)
  defp restore(name, value), do: System.put_env(name, value)
end
