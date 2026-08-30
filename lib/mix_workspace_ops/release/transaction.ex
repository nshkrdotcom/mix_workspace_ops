defmodule MixWorkspaceOps.Release.Transaction do
  @moduledoc "Fail-closed, resumable release state machine with durable transition evidence."

  alias MixWorkspaceOps.{Report, Release.Receipt}

  @transitions [:preflight, :checkout, :gates, :archive, :publish, :verify, :tag, :push_tag]
  @event_schema "mix_workspace_ops.release.event/v2"
  @identity_schema "mix_workspace_ops.release.transaction/v2"

  @evidence_keys %{
    "archive" => :archive,
    "archive_checksum" => :archive_checksum,
    "checkout" => :checkout,
    "dependency_preflight" => :dependency_preflight,
    "expected_prepared_artifact" => :expected_prepared_artifact,
    "gate_results" => :gate_results,
    "head" => :head,
    "manifest_path" => :manifest_path,
    "manifest_sha256" => :manifest_sha256,
    "origin" => :origin,
    "prepared_artifact" => :prepared_artifact,
    "project" => :project,
    "project_sha256" => :project_sha256,
    "registry_checksum" => :registry_checksum,
    "source_revision" => :source_revision,
    "source_project" => :source_project,
    "tag" => :tag
  }

  @type plan :: %{
          required(:package) => String.t(),
          required(:version) => String.t(),
          required(:tag) => String.t(),
          required(:repository) => String.t(),
          optional(atom()) => term()
        }

  @spec run(plan(), module(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(plan, adapter, opts \\ []) do
    with :ok <- validate_plan(plan) do
      do_run(plan, adapter, opts)
    end
  end

  defp do_run(plan, adapter, opts) do
    state_root = Keyword.get_lazy(opts, :state_root, &default_state_root/0)
    transaction_id = Keyword.get_lazy(opts, :transaction_id, fn -> transaction_id(plan) end)
    mode = if Keyword.get(opts, :resume, false), do: :resume, else: :new
    identity = identity(plan, transaction_id, opts)

    with {:ok, receipt} <- Receipt.open(state_root, transaction_id, mode) do
      try do
        context = %{
          plan: plan,
          transaction_id: transaction_id,
          completed: [],
          receipt_directory: receipt.directory
        }

        case mode do
          :new -> start_new(adapter, receipt, context, identity)
          :resume -> resume(adapter, receipt, context, identity)
        end
      after
        Receipt.close(receipt)
      end
    end
  end

  @spec transitions() :: [atom()]
  def transitions, do: @transitions

  defp start_new(adapter, receipt, context, identity) do
    initialized = event(context, :transaction, :initialized, identity)

    with :ok <- persist(receipt, :transaction, initialized) do
      execute(@transitions, adapter, receipt, context)
    end
  end

  defp resume(adapter, receipt, context, identity) do
    with {:ok, history} <- parse_history(receipt.events, context.transaction_id, identity),
         context <- restore_context(context, history),
         {:ok, context} <- verify_completed(adapter, history.completed, context),
         {:ok, history, context} <- recover_started(adapter, receipt, history, context) do
      cond do
        history.complete? ->
          {:ok, Map.put(context, :receipt, receipt.path)}

        true ->
          execute(Enum.drop(@transitions, length(history.completed)), adapter, receipt, context)
      end
    else
      {:error, reason} -> {:error, {:release_resume, reason, receipt.path}}
    end
  end

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

  defp verify_completed(adapter, completed, context) do
    Enum.reduce_while(completed, {:ok, context}, fn transition, {:ok, current} ->
      case invoke_resume(adapter, transition, :completed, current) do
        {:ok, next} -> {:cont, {:ok, Map.merge(current, next)}}
        :rerun -> {:halt, {:error, {:completed_transition_requested_rerun, transition}}}
        {:error, reason} -> {:halt, {:error, {:completed_transition_drift, transition, reason}}}
      end
    end)
  end

  defp recover_started(_adapter, _receipt, %{started: nil} = history, context),
    do: {:ok, history, context}

  defp recover_started(adapter, receipt, history, context) do
    transition = history.started

    case invoke_resume(adapter, transition, :started, context) do
      :rerun ->
        {:ok, %{history | started: nil}, context}

      {:ok, next} ->
        context = merge_context(context, next, transition)
        succeeded = event(context, transition, :succeeded, evidence(next))

        with :ok <- persist(receipt, transition, succeeded) do
          {:ok,
           %{
             history
             | started: nil,
               completed: history.completed ++ [transition],
               evidence: Map.put(history.evidence, transition, evidence(next))
           }, context}
        end

      {:error, reason} ->
        {:error, {:started_transition_unresolved, transition, reason}}
    end
  end

  defp invoke_resume(adapter, transition, status, context) do
    if function_exported?(adapter, :resume, 3) do
      adapter.resume(transition, status, context)
    else
      case status do
        :completed -> {:ok, %{}}
        :started -> :rerun
      end
    end
  rescue
    error -> {:error, {:adapter_exception, error.__struct__, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:adapter_throw, kind, inspect(reason)}}
  end

  defp parse_history([first | rest], transaction_id, identity) do
    with :ok <- validate_identity_event(first, transaction_id, identity) do
      initial = %{completed: [], evidence: %{}, started: nil, complete?: false}
      Enum.reduce_while(rest, {:ok, initial}, &parse_event(&1, &2, transaction_id))
    end
  end

  defp parse_history([], _transaction_id, _identity), do: {:error, :empty_receipt}

  defp parse_event(event, {:ok, state}, transaction_id) do
    with :ok <- common_event(event, transaction_id),
         {:ok, transition} <- transition(event["transition"]),
         :ok <- expected_completed(event, state.completed, transition) do
      parse_status(event, transition, state)
    else
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp parse_status(_event, _transition, %{complete?: true}),
    do: {:halt, {:error, :event_after_complete}}

  defp parse_status(%{"status" => "started"}, transition, %{started: nil} = state) do
    if transition == Enum.at(@transitions, length(state.completed)) do
      {:cont, {:ok, %{state | started: transition}}}
    else
      {:halt, {:error, {:unexpected_started_transition, transition}}}
    end
  end

  defp parse_status(%{"status" => "succeeded", "evidence" => evidence}, transition, state)
       when transition == state.started and is_map(evidence) do
    {:cont,
     {:ok,
      %{
        state
        | completed: state.completed ++ [transition],
          evidence: Map.put(state.evidence, transition, evidence),
          started: nil
      }}}
  end

  defp parse_status(%{"status" => "failed"}, transition, state)
       when transition == state.started,
       do: {:cont, {:ok, %{state | started: nil}}}

  defp parse_status(%{"status" => "succeeded"}, :complete, state)
       when length(state.completed) == length(@transitions) and is_nil(state.started),
       do: {:cont, {:ok, %{state | complete?: true}}}

  defp parse_status(event, transition, _state),
    do: {:halt, {:error, {:invalid_transition_event, transition, event["status"]}}}

  defp restore_context(context, history) do
    Enum.reduce(history.completed, context, fn transition, current ->
      history.evidence
      |> Map.fetch!(transition)
      |> atomize_evidence()
      |> then(&Map.merge(current, &1))
      |> Map.update!(:completed, fn completed -> completed ++ [transition] end)
    end)
  end

  defp validate_identity_event(event, transaction_id, identity) do
    with :ok <- common_event(event, transaction_id),
         true <- event["transition"] == "transaction" || {:error, :missing_transaction_identity},
         true <- event["status"] == "initialized" || {:error, :invalid_transaction_identity},
         true <- event["completed"] == [] || {:error, :invalid_transaction_identity},
         stored when is_map(stored) <- event["evidence"],
         true <- Report.encode(stored) == Report.encode(identity) || {:error, :transaction_drift} do
      :ok
    else
      false -> {:error, :transaction_drift}
      nil -> {:error, :invalid_transaction_identity}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_transaction_identity}
    end
  end

  defp common_event(event, transaction_id) when is_map(event) do
    cond do
      event["schema"] != @event_schema -> {:error, :unsupported_receipt_schema}
      event["transaction_id"] != transaction_id -> {:error, :receipt_transaction_mismatch}
      not is_list(event["completed"]) -> {:error, :invalid_completed_evidence}
      true -> :ok
    end
  end

  defp expected_completed(event, completed, transition) do
    completed =
      if event["status"] == "succeeded" and transition != :complete,
        do: completed ++ [transition],
        else: completed

    expected = Enum.map(completed, &Atom.to_string/1)
    if event["completed"] == expected, do: :ok, else: {:error, :completed_evidence_drift}
  end

  defp transition("complete"), do: {:ok, :complete}

  defp transition(value) when is_binary(value) do
    case Enum.find(@transitions, &(Atom.to_string(&1) == value)) do
      nil -> {:error, {:unknown_receipt_transition, value}}
      transition -> {:ok, transition}
    end
  end

  defp transition(value), do: {:error, {:unknown_receipt_transition, value}}

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
      schema: @event_schema,
      transaction_id: context.transaction_id,
      transition: transition,
      status: status,
      completed: context.completed,
      evidence: evidence,
      system_millisecond: System.system_time(:millisecond)
    }
  end

  defp evidence(next), do: sanitize(next)

  defp sanitize(map) when is_map(map) do
    map
    |> Enum.reject(fn {key, _value} -> secret_key?(key) end)
    |> Map.new(fn {key, value} -> {key, sanitize(value)} end)
  end

  defp sanitize(list) when is_list(list), do: Enum.map(list, &sanitize/1)
  defp sanitize(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> sanitize()
  defp sanitize(value) when is_function(value) or is_pid(value) or is_reference(value), do: nil
  defp sanitize(value), do: value

  defp secret_key?(key) do
    normalized = key |> to_string() |> String.downcase()

    Enum.any?(
      ~w(credential secret token authorization hex_api_key environment),
      &String.contains?(normalized, &1)
    )
  end

  defp atomize_evidence(evidence) do
    Map.new(evidence, fn {key, value} -> {Map.get(@evidence_keys, key, key), value} end)
  end

  defp identity(plan, transaction_id, opts) do
    descriptor =
      Keyword.get(opts, :descriptor, Map.take(plan, [:package, :version, :tag, :repository]))

    %{
      schema: @identity_schema,
      transaction_id: transaction_id,
      package: plan.package,
      version: plan.version,
      descriptor: descriptor,
      descriptor_digest: digest(descriptor),
      release_plan_digest: Keyword.get(opts, :release_plan_digest),
      registry_digest: Keyword.get(opts, :registry_digest)
    }
  end

  defp digest(value) do
    value
    |> Report.encode()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
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

  @doc false
  def default_state_root do
    base = System.get_env("XDG_STATE_HOME") || Path.join(System.user_home!(), ".local/state")
    Path.join(base, "mix_workspace_ops")
  end
end
