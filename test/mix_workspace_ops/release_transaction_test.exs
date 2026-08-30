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

    @impl true
    def resume(:publish, :started, context) do
      if Map.get(context.plan, :recover_publish?, false) do
        send(context.plan.owner, {:recovered, :publish})
        {:ok, %{registry_checksum: "aaa"}}
      else
        :rerun
      end
    end

    def resume(transition, :started, context) do
      send(context.plan.owner, {:rerun, transition})
      :rerun
    end

    def resume(transition, :completed, context) do
      send(context.plan.owner, {:resumed, transition})
      {:ok, %{}}
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

  test "a transaction id cannot append to an earlier receipt", context do
    state_root = temporary_directory!(context)

    assert {:error, {:release_transition, :preflight, {:injected, :preflight}, _receipt}} =
             Transaction.run(plan(:preflight), Adapter,
               state_root: state_root,
               transaction_id: "one-attempt"
             )

    expected = Path.join([state_root, "releases", "one-attempt"])

    assert {:error, {:transaction_exists, ^expected}} =
             Transaction.run(plan(nil), Adapter,
               state_root: state_root,
               transaction_id: "one-attempt"
             )
  end

  test "an interrupted transaction resumes after publish without publishing twice", context do
    state_root = temporary_directory!(context)

    assert {:error, {:release_transition, :verify, {:injected, :verify}, receipt}} =
             Transaction.run(plan(:verify), Adapter,
               state_root: state_root,
               transaction_id: "resume-after-publish"
             )

    first = drain_transitions([])
    assert Enum.count(first, &(&1 == :publish)) == 1

    assert {:ok, result} =
             Transaction.run(plan(nil), Adapter,
               state_root: state_root,
               transaction_id: "resume-after-publish",
               resume: true
             )

    second = drain_messages([])
    refute {:transition, :publish} in second
    assert {:resumed, :publish} in second
    assert {:transition, :verify} in second
    assert result.completed == Transaction.transitions()
    assert result.receipt == receipt
  end

  test "a failed publish recovers exact external success instead of republishing",
       context do
    state_root = temporary_directory!(context)

    assert {:error, {:release_transition, :publish, {:injected, :publish}, _receipt}} =
             Transaction.run(plan(:publish), Adapter,
               state_root: state_root,
               transaction_id: "recover-started-publish"
             )

    _messages = drain_messages([])

    recovering_plan = plan(nil) |> Map.put(:recover_publish?, true)

    assert {:ok, result} =
             Transaction.run(recovering_plan, Adapter,
               state_root: state_root,
               transaction_id: "recover-started-publish",
               resume: true
             )

    messages = drain_messages([])
    assert {:recovered, :publish} in messages
    refute {:transition, :publish} in messages
    assert result.completed == Transaction.transitions()
  end

  test "resume refuses descriptor drift before calling the adapter", context do
    state_root = temporary_directory!(context)
    descriptor = %{package: "sample_package", policy: "one"}

    assert {:error, {:release_transition, :preflight, {:injected, :preflight}, receipt}} =
             Transaction.run(plan(:preflight), Adapter,
               state_root: state_root,
               transaction_id: "descriptor-drift",
               descriptor: descriptor
             )

    _messages = drain_messages([])

    assert {:error, {:release_resume, :transaction_drift, ^receipt}} =
             Transaction.run(plan(nil), Adapter,
               state_root: state_root,
               transaction_id: "descriptor-drift",
               descriptor: %{package: "sample_package", policy: "two"},
               resume: true
             )

    assert drain_messages([]) == []
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

  defp drain_messages(acc) do
    receive do
      message -> drain_messages(acc ++ [message])
    after
      0 -> acc
    end
  end
end
