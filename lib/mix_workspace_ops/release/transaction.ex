defmodule MixWorkspaceOps.Release.Transaction do
  @moduledoc "Fail-closed release state machine with durable transition evidence."

  alias MixWorkspaceOps.Release.Receipt

  @transitions [:preflight, :checkout, :gates, :archive, :publish, :verify, :tag, :push_tag]

  @type plan :: %{
          required(:package) => String.t(),
          required(:version) => String.t(),
          required(:tag) => String.t(),
          required(:repository) => String.t(),
          optional(atom()) => term()
        }

  @spec run(plan(), module(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(plan, adapter, opts \\ []) do
    state_root = Keyword.get_lazy(opts, :state_root, &default_state_root/0)
    transaction_id = Keyword.get_lazy(opts, :transaction_id, fn -> transaction_id(plan) end)
    context = %{plan: plan, transaction_id: transaction_id, completed: []}

    with :ok <- validate_plan(plan),
         {:ok, receipt} <- Receipt.open(state_root, transaction_id) do
      try do
        execute(
          @transitions,
          adapter,
          receipt,
          Map.put(context, :receipt_directory, receipt.directory)
        )
      after
        Receipt.close(receipt)
      end
    end
  end

  @spec transitions() :: [atom()]
  def transitions, do: @transitions

  defp execute([], _adapter, receipt, context) do
    event = event(context, :complete, :succeeded, %{})

    case Receipt.append(receipt, event) do
      :ok -> {:ok, Map.put(context, :receipt, receipt.path)}
      {:error, reason} -> {:error, {:receipt_persistence, :complete, reason}}
    end
  end

  defp execute([transition | rest], adapter, receipt, context) do
    started = event(context, transition, :started, %{})

    with :ok <- persist(receipt, transition, started),
         {:ok, next} <- invoke(adapter, transition, context),
         context = merge_context(context, next, transition),
         succeeded = event(context, transition, :succeeded, evidence(next)),
         :ok <- persist(receipt, transition, succeeded) do
      execute(rest, adapter, receipt, context)
    else
      {:error, {:receipt_persistence, _transition, _reason} = reason} ->
        {:error, reason}

      {:error, reason} ->
        failed = event(context, transition, :failed, %{reason: inspect(reason)})

        case persist(receipt, transition, failed) do
          :ok -> {:error, {:release_transition, transition, reason, receipt.path}}
          {:error, persistence} -> {:error, persistence}
        end
    end
  end

  defp persist(receipt, transition, event) do
    case Receipt.append(receipt, event) do
      :ok -> :ok
      {:error, reason} -> {:error, {:receipt_persistence, transition, reason}}
    end
  end

  defp invoke(adapter, transition, context) do
    adapter.transition(transition, context)
  rescue
    error -> {:error, {:adapter_exception, error.__struct__, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:adapter_throw, kind, inspect(reason)}}
  end

  defp merge_context(context, next, transition) do
    context
    |> Map.merge(next)
    |> Map.update!(:completed, &(&1 ++ [transition]))
  end

  defp event(context, transition, status, evidence) do
    %{
      schema: "mix_workspace_ops.release.event/v1",
      transaction_id: context.transaction_id,
      transition: transition,
      status: status,
      completed: context.completed,
      evidence: evidence,
      system_millisecond: System.system_time(:millisecond)
    }
  end

  defp evidence(next) do
    next
    |> Map.drop([:credentials, :environment, :secret, :token])
    |> Map.take([:head, :checkout, :archive, :archive_checksum, :registry_checksum, :tag])
  end

  defp validate_plan(plan) when is_map(plan) do
    required = [:package, :version, :tag, :repository]

    if Enum.all?(required, &(is_binary(Map.get(plan, &1)) and Map.get(plan, &1) != "")),
      do: :ok,
      else: {:error, :invalid_release_plan}
  end

  defp validate_plan(_plan), do: {:error, :invalid_release_plan}

  defp transaction_id(plan) do
    timestamp = System.system_time(:microsecond)
    nonce = :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)
    "#{plan.package}-#{plan.version}-#{timestamp}-#{nonce}"
  end

  defp default_state_root do
    base = System.get_env("XDG_STATE_HOME") || Path.join(System.user_home!(), ".local/state")
    Path.join(base, "mix_workspace_ops")
  end
end
