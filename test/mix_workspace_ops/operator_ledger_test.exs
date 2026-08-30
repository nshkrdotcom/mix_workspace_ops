defmodule MixWorkspaceOps.OperatorLedgerTest do
  use MixWorkspaceOps.WorkspaceCase, async: true

  alias MixWorkspaceOps.{Git, OperatorLedger, Registry}

  test "one strict ledger binds an exact out-of-root checkout", context do
    root = temporary_directory!(context)
    checkout_root = Path.join(root, "checkouts")
    File.mkdir_p!(checkout_root)
    alpha = initialize_repository!(Path.join(root, "elsewhere/alpha"), "[]", "example-org/alpha")
    catalog = write_catalog!(root, [catalog_repository("alpha")])
    {:ok, registry} = Registry.load(catalog)
    ledger_path = write_ledger!(root, [binding("alpha", alpha)], [])

    assert {:ok, ledger} = OperatorLedger.load(ledger_path, registry)
    assert ledger.bindings["alpha"].path == alpha
    assert is_binary(ledger.digest)

    assert {:ok, bound} = Registry.bind(registry, checkout_root, binding_file: ledger_path)
    assert Registry.checkout(bound, "alpha") == {:bound, alpha}
  end

  test "unknown ids, relative paths, duplicate identities and unknown keys fail by name",
       context do
    root = temporary_directory!(context)
    catalog = write_catalog!(root, [catalog_repository("alpha")])
    {:ok, registry} = Registry.load(catalog)
    absolute = Path.join(root, "ignored")
    remotes = ["https://github.com/example-org/ignored.git"]

    unknown =
      write_ledger!(
        root,
        [%{"repository" => "missing", "path" => absolute, "remotes" => remotes}],
        [],
        "unknown.json"
      )

    assert {:error, {:operator_ledger, ^unknown, {:unknown_binding_repository, "missing"}}} =
             OperatorLedger.load(unknown, registry)

    relative =
      write_ledger!(
        root,
        [%{"repository" => "alpha", "path" => "relative", "remotes" => remotes}],
        [],
        "relative.json"
      )

    assert {:error, {:operator_ledger, ^relative, {{:binding_path, 1}, :must_be_absolute}}} =
             OperatorLedger.load(relative, registry)

    duplicate =
      write_ledger!(
        root,
        [],
        [
          %{"path" => absolute, "remotes" => remotes, "reason" => "first"},
          %{"path" => absolute <> "-two", "remotes" => remotes, "reason" => "second"}
        ],
        "duplicate.json"
      )

    assert {:error, {:operator_ledger, ^duplicate, {:duplicate_ignore_identity, ^remotes}}} =
             OperatorLedger.load(duplicate, registry)

    path = Path.join(root, "unknown-key.json")

    File.write!(
      path,
      :json.encode(%{
        "schema" => "mix_workspace_ops.operator_ledger/v1",
        "bindings" => [],
        "ignores" => [],
        "extra" => true
      })
    )

    assert {:error, {:operator_ledger, ^path, {:invalid_keys, :ledger, _expected, actual}}} =
             OperatorLedger.load(path, registry)

    assert "extra" in actual
  end

  test "binding refuses remote drift after the ledger observation", context do
    root = temporary_directory!(context)
    checkout_root = Path.join(root, "checkouts")
    File.mkdir_p!(checkout_root)
    alpha = initialize_repository!(Path.join(root, "elsewhere/alpha"), "[]", "example-org/alpha")
    catalog = write_catalog!(root, [catalog_repository("alpha")])
    {:ok, registry} = Registry.load(catalog)
    ledger_path = write_ledger!(root, [binding("alpha", alpha)], [])

    {_, 0} =
      System.cmd(
        "git",
        ["remote", "set-url", "origin", "https://github.com/example-org/other.git"],
        cd: alpha,
        stderr_to_stdout: true
      )

    assert {:error, {:binding_remote_drift, "alpha", _expected, _actual}} =
             Registry.bind(registry, checkout_root, binding_file: ledger_path)
  end

  defp binding(repository, path) do
    {:ok, remotes} = Git.remote_urls(path)
    %{"repository" => repository, "path" => path, "remotes" => remotes}
  end

  defp write_ledger!(root, bindings, ignores, name \\ "ledger.json") do
    path = Path.join(root, name)

    File.write!(
      path,
      :json.encode(%{
        "schema" => "mix_workspace_ops.operator_ledger/v1",
        "bindings" => bindings,
        "ignores" => ignores
      })
    )

    path
  end
end
