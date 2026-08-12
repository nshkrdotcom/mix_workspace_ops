defmodule MixWorkspaceOps.Release.TransactionTest do
  use MixWorkspaceOps.WorkspaceCase, async: true

  alias MixWorkspaceOps.Release.Transaction

  defmodule Adapter do
    @behaviour MixWorkspaceOps.Release.Adapter

    @impl true
    def transition(transition, context) do
      send(context.plan.owner, {:transition, transition})

      if context.plan.fail_at == transition,
        do: {:error, {:injected, transition}},
        else: {:ok, evidence(transition)}
    end

    defp evidence(:preflight), do: %{head: "abc123"}
    defp evidence(:checkout), do: %{checkout: "temporary"}
    defp evidence(:archive), do: %{archive: "package.tar", archive_checksum: "aaa"}
    defp evidence(:verify), do: %{registry_checksum: "aaa"}
    defp evidence(:tag), do: %{tag: "v1.0.0"}
    defp evidence(_transition), do: %{}
  end

  defmodule RaisingAdapter do
    @behaviour MixWorkspaceOps.Release.Adapter

    @impl true
    def transition(:preflight, _context), do: raise("preflight exploded")
  end

  test "a complete transaction reaches every transition and persists evidence", context do
    state_root = temporary_directory!(context)
    plan = plan(nil)

    assert {:ok, result} =
             Transaction.run(plan, Adapter,
               state_root: state_root,
               transaction_id: "complete"
             )

    assert result.completed == Transaction.transitions()
    assert File.regular?(result.receipt)

    events = File.read!(result.receipt)
    assert events =~ "\"transition\":\"publish\""
    assert events =~ "\"transition\":\"complete\""
    refute events =~ "credential"
  end

  test "every failed transition prevents all later transitions", context do
    for failed <- Transaction.transitions() do
      state_root = Path.join(temporary_directory!(Map.put(context, :test, failed)), "state")

      assert {:error, {:release_transition, ^failed, {:injected, ^failed}, receipt}} =
               Transaction.run(plan(failed), Adapter,
                 state_root: state_root,
                 transaction_id: to_string(failed)
               )

      called = drain_transitions([])
      expected = Enum.take_while(Transaction.transitions(), &(&1 != failed)) ++ [failed]
      assert called == expected
      assert File.read!(receipt) =~ "\"status\":\"failed\""
    end
  end

  test "adapter exceptions become durable failed transitions", context do
    state_root = temporary_directory!(context)

    assert {:error,
            {:release_transition, :preflight,
             {:adapter_exception, RuntimeError, "preflight exploded"}, receipt}} =
             Transaction.run(plan(nil), RaisingAdapter,
               state_root: state_root,
               transaction_id: "raised"
             )

    assert File.read!(receipt) =~ "adapter_exception"
  end

  defp plan(fail_at) do
    %{
      package: "sample_package",
      version: "1.0.0",
      tag: "v1.0.0",
      repository: "sample_repository",
      owner: self(),
      fail_at: fail_at
    }
  end

  defp drain_transitions(acc) do
    receive do
      {:transition, transition} -> drain_transitions(acc ++ [transition])
    after
      0 -> acc
    end
  end
end
