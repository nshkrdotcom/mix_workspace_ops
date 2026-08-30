defmodule MixWorkspaceOps.Release.ReceiptTest do
  use MixWorkspaceOps.WorkspaceCase, async: false

  alias MixWorkspaceOps.Release.Receipt

  test "a transaction receipt has one cross-process writer", context do
    state_root = temporary_directory!(context)
    assert {:ok, first} = Receipt.open(state_root, "exclusive-writer")

    assert {:error, :receipt_locked} = Receipt.open(state_root, "exclusive-writer", :resume)

    assert :ok = Receipt.close(first)
    assert {:ok, resumed} = Receipt.open(state_root, "exclusive-writer", :resume)
    assert :ok = Receipt.close(resumed)
  end

  test "resume rejects and unlocks a truncated receipt", context do
    state_root = temporary_directory!(context)
    assert {:ok, receipt} = Receipt.open(state_root, "truncated")
    assert :ok = Receipt.close(receipt)
    File.write!(receipt.path, ~s({"complete":true}))

    assert {:error, :truncated_receipt} = Receipt.open(state_root, "truncated", :resume)

    File.write!(receipt.path, ~s({"complete":true}\n))
    assert {:ok, reopened} = Receipt.open(state_root, "truncated", :resume)
    assert :ok = Receipt.close(reopened)
  end

  test "the receipt lock process inherits no publication credential", context do
    previous = System.get_env("HEX_API_KEY")
    System.put_env("HEX_API_KEY", "receipt-lock-sentinel")

    on_exit(fn ->
      if previous,
        do: System.put_env("HEX_API_KEY", previous),
        else: System.delete_env("HEX_API_KEY")
    end)

    state_root = temporary_directory!(context)
    assert {:ok, receipt} = Receipt.open(state_root, "credential-free-lock")
    assert {:os_pid, pid} = Port.info(receipt.lock, :os_pid)
    refute File.read!("/proc/#{pid}/environ") =~ "receipt-lock-sentinel"
    assert :ok = Receipt.close(receipt)
  end
end
