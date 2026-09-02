defmodule MixWorkspaceOps.Fanout do
  @moduledoc """
  Binds a portable operation plan to local execution state and delegates its
  commands to Blitz.

  Planning and binding are deliberately separate. The plan is portable and
  self-digested; the binding records local checkout and private runtime paths.
  Every runtime lease allocated here is finalized and released before `run/3`
  returns, including after a failed command or a partial binding failure.
  """

  alias MixWorkspaceOps.{
    Binding,
    Git,
    OperationPlan,
    Overlay,
    PublishMode,
    Registry,
    Report,
    ResourceBudget,
    Runtime,
    Toolchain
  }

  alias MixWorkspaceOps.Project.ProbeMemo

  @binding_schema "mix_workspace_ops.binding/v1"
  @run_schema "mix_workspace_ops.run/v1"

  @type result :: {:ok, map()} | {:error, {:fanout_failed, map()}} | {:error, term()}

  @doc "Binds and executes every present unit in semantic-plan order."
  @spec run(map(), Registry.t(), keyword()) :: result()
  def run(plan, registry, opts \\ []) do
    started_at = System.system_time(:millisecond)

    with {:ok, execution} <- execution_options(plan, opts),
         execution <- binding_budget(plan, execution),
         :ok <- verify_all_units(plan, registry),
         {:ok, bound} <- bind_all(plan, registry, execution) do
      execute_and_finalize(plan, bound, execution, started_at)
    else
      {:error, {:binding_failed, reason, bound}} ->
        binding_failure(plan, bound, reason, opts, started_at)

      {:error, reason} ->
        binding_failure(plan, [], reason, opts, started_at)
    end
  end

  defp execution_options(plan, opts) do
    items =
      plan
      |> field(:units)
      |> Enum.count(&(field(&1, :status) in [:planned, "planned"]))

    resource_budget =
      opts
      |> Keyword.get(:resource_snapshot, ResourceBudget.snapshot())
      |> ResourceBudget.allocate(
        operation_class(plan),
        items,
        Keyword.take(opts, [:max_concurrency, :beam_schedulers])
      )

    max_concurrency = resource_budget.workers
    beam_schedulers = resource_budget.beam_schedulers

    timeout = Keyword.get(opts, :timeout, :infinity)
    binding_timeout = Keyword.get(opts, :binding_timeout, 300_000)
    preparation_timeout = Keyword.get(opts, :preparation_timeout, 120_000)

    with :ok <- positive_integer(max_concurrency, :invalid_max_concurrency),
         :ok <- valid_timeout(timeout),
         :ok <- positive_integer(binding_timeout, :invalid_binding_timeout),
         :ok <- positive_integer(preparation_timeout, :invalid_preparation_timeout),
         :ok <- positive_integer(beam_schedulers, :invalid_beam_schedulers),
         {:ok, state_root} <- Keyword.fetch(opts, :state_root),
         true <- is_binary(state_root) || {:error, {:invalid_state_root, state_root}} do
      {:ok,
       %{
         max_concurrency: max_concurrency,
         beam_schedulers: beam_schedulers,
         timeout: timeout,
         binding_timeout: binding_timeout,
         preparation_timeout: preparation_timeout,
         resource_budget: resource_budget,
         state_root: state_root,
         allow_lock_mutation: Keyword.get(opts, :allow_lock_mutation, false),
         git_cache_memo:
           :ets.new(GitCache, [:set, :public, read_concurrency: true, write_concurrency: true]),
         probe_memo: Keyword.get(opts, :probe_memo, ProbeMemo.new())
       }}
    end
  end

  defp positive_integer(value, _error) when is_integer(value) and value > 0, do: :ok
  defp positive_integer(value, error), do: {:error, {error, value}}

  defp valid_timeout(:infinity), do: :ok
  defp valid_timeout(timeout), do: positive_integer(timeout, :invalid_timeout)

  defp verify_all_units(plan, registry) do
    plan
    |> field(:units)
    |> Enum.reduce_while(:ok, fn unit, :ok ->
      case safe_verify_unit(unit, registry) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp safe_verify_unit(unit, registry) do
    verify_unit(unit, registry)
  catch
    kind, reason ->
      {:error,
       {:binding_verification_exception, kind, reason,
        Exception.format_stacktrace(__STACKTRACE__)}}
  end

  defp verify_unit(unit, registry) do
    repository_id = unit |> field(:repository) |> field(:id)
    verify_repository_status(unit, registry, repository_id)
  end

  defp verify_repository_status(unit, registry, repository_id) do
    case {field(unit, :status), Registry.checkout(registry, repository_id)} do
      {status, {:bound, root}} when status in [:planned, "planned"] ->
        verify_expected(repository_id, field(unit, :expected), root)

      {status, {:absent, _path}} when status in [:absent, "absent"] ->
        :ok

      {expected, {:bound, _root}} ->
        {:error, {:binding_state_drift, repository_id, expected, :planned}}

      {expected, {:absent, path}} ->
        {:error, {:binding_state_drift, repository_id, expected, {:absent, path}}}

      {_expected, :unknown} ->
        {:error, {:unknown_repository, repository_id}}
    end
  end

  defp verify_expected(identity, expected, root) do
    actual = current_state(root)

    drifts =
      [:head, :source_digest, :clean]
      |> Enum.flat_map(fn dimension ->
        wanted = field(expected, dimension)
        found = Map.fetch!(actual, dimension)

        if wanted == found,
          do: [],
          else: [%{field: dimension, expected: wanted, actual: found}]
      end)

    if drifts == [],
      do: :ok,
      else: {:error, {:binding_state_drift, identity, drifts}}
  end

  defp bind_all(plan, registry, execution) do
    results =
      plan
      |> field(:units)
      |> Task.async_stream(&safe_bind_unit(plan, &1, registry, execution),
        max_concurrency: execution.binding_concurrency,
        ordered: true,
        timeout: execution.binding_timeout,
        on_timeout: :kill_task,
        zip_input_on_exit: true
      )
      |> Enum.map(fn
        {:ok, result} ->
          result

        {:exit, {unit, :timeout}} ->
          {:error, {:binding_timeout, field(unit, :id), execution.binding_timeout}}

        {:exit, {unit, reason}} ->
          {:error, {:binding_task_exit, field(unit, :id), reason}}
      end)

    bound = for {:ok, item} <- results, not is_nil(item), do: item

    case Enum.find(results, &match?({:error, _reason}, &1)) do
      nil -> {:ok, bound}
      {:error, reason} -> {:error, {:binding_failed, reason, bound}}
    end
  end

  defp safe_bind_unit(plan, unit, registry, execution) do
    bind_unit(plan, unit, registry, execution)
  catch
    kind, reason ->
      {:error,
       {:binding_exception, field(unit, :id), kind, reason,
        Exception.format_stacktrace(__STACKTRACE__)}}
  end

  defp bind_unit(plan, unit, registry, execution) do
    if field(unit, :status) in [:absent, "absent"] do
      {:ok, nil}
    else
      case field(unit, :kind) do
        kind when kind in [:project, "project"] ->
          bind_project(plan, unit, registry, execution)

        kind when kind in [:repository, "repository"] ->
          bind_repository(plan, unit, registry, execution)

        kind ->
          {:error, {:unknown_plan_unit_kind, kind}}
      end
    end
  end

  defp bind_project(plan, unit, registry, execution) do
    policy = field(plan, :policy)
    project_id = field(unit, :id)

    activation_opts = [
      mode: source_mode(field(policy, :source_mode)),
      sources: field(policy, :source_overrides),
      publish?: false,
      mix_env: field(policy, :mix_env),
      mix_target: field(policy, :mix_target),
      dependency_scope:
        PublishMode.dependency_scope(OperationPlan.command_argv(plan), field(policy, :mix_env)),
      allow_lock_mutation: execution.allow_lock_mutation,
      prepare_objects: true,
      cache_concurrency: execution.cache_concurrency,
      preparation_timeout: execution.preparation_timeout,
      mix_state: :managed,
      git_cache_memo: execution.git_cache_memo,
      probe_memo: execution.probe_memo,
      state_root: execution.state_root
    ]

    with {:ok, activation} <- Overlay.activate(registry, project_id, activation_opts) do
      root = Registry.project_root(registry, project_id)

      result =
        try do
          case verify_project_activation(unit, activation, root, registry) do
            :ok ->
              {:ok,
               bound_item(
                 plan,
                 unit,
                 root,
                 scheduler_environment(activation.env, execution),
                 activation,
                 :overlay
               )}

            {:error, reason} ->
              {:error, reason}
          end
        catch
          kind, reason ->
            {:error,
             {:binding_exception, project_id, kind, reason,
              Exception.format_stacktrace(__STACKTRACE__)}}
        end

      case result do
        {:ok, _item} = ok ->
          ok

        {:error, _reason} = error ->
          Overlay.deactivate(activation)
          error
      end
    end
  end

  defp bind_repository(plan, unit, registry, execution) do
    policy = field(plan, :policy)
    repository_id = field(unit, :id)
    {:bound, root} = Registry.checkout(registry, repository_id)
    expected = field(unit, :expected)

    with {:ok, lock_bytes} <- source_lock(root),
         {:ok, runtime} <-
           Runtime.prepare(
             execution.state_root,
             runtime_cache_identity(unit),
             lock_bytes,
             ownership: :delegated,
             target_head: field(expected, :head),
             target_source_digest: field(expected, :source_digest),
             binding_root: root,
             project_identity: field(unit, :id),
             mix_env: field(policy, :mix_env),
             mix_target: field(policy, :mix_target),
             prepare_objects: true,
             git_cache_memo: execution.git_cache_memo,
             cache_concurrency: execution.cache_concurrency,
             preparation_timeout: execution.preparation_timeout,
             allow_lock_mutation: execution.allow_lock_mutation
           ) do
      env =
        [
          {"MIX_ENV", field(policy, :mix_env)},
          {"MIX_TARGET", field(policy, :mix_target)}
          | runtime.env
        ]

      activation = %{runtime_handle: runtime.handle, report: %{runtime: runtime.report}}

      try do
        {:ok,
         bound_item(
           plan,
           unit,
           root,
           scheduler_environment(env, execution),
           activation,
           :runtime
         )}
      catch
        kind, reason ->
          finalize(%{activation_kind: :runtime, activation: activation})

          {:error,
           {:binding_exception, repository_id, kind, reason,
            Exception.format_stacktrace(__STACKTRACE__)}}
      end
    end
  end

  defp bound_item(plan, unit, root, env, activation, activation_kind) do
    command = field(plan, :command)

    blitz =
      Blitz.command(%{
        id: field(unit, :id),
        command: command |> field(:executable) |> bound_executable(),
        args: field(command, :args),
        cd: root,
        env: env
      })

    %{
      id: field(unit, :id),
      unit: unit,
      blitz: blitz,
      activation: activation,
      activation_kind: activation_kind,
      binding: %{
        id: field(unit, :id),
        cd: root,
        command: command_binding(blitz),
        overlay_path: Map.get(activation, :path),
        runtime: activation.report.runtime
      }
    }
  end

  defp verify_project_activation(unit, activation, root, registry) do
    with :ok <- verify_expected(field(unit, :id), field(unit, :expected), root),
         true <-
           field(unit, :graph_digest) == activation.report.graph_digest ||
             {:error,
              {:binding_activation_drift, field(unit, :id),
               [
                 %{
                   field: :graph_digest,
                   expected: field(unit, :graph_digest),
                   actual: activation.report.graph_digest
                 }
               ]}},
         :ok <- verify_source_decisions(unit, activation),
         do: verify_overlay_rows(unit, activation, registry)
  end

  defp verify_source_decisions(unit, activation) do
    expected =
      unit
      |> field(:sources)
      |> Enum.map(&source_summary/1)

    actual = Enum.map(activation.report.decisions, &source_summary/1)

    if Report.encode(expected) == Report.encode(actual),
      do: :ok,
      else: {:error, {:binding_source_drift, field(unit, :id), expected, actual}}
  end

  defp source_summary(source) do
    %{
      application: field(source, :application),
      classification: field(source, :classification),
      provider: field(source, :provider),
      source: field(source, :source),
      reason: field(source, :reason),
      considered: field(source, :considered),
      declared_by: field(source, :declared_by)
    }
  end

  defp verify_overlay_rows(unit, activation, registry) do
    expected = field(unit, :sources)
    actual = activation.report.rows

    if length(expected) == length(actual) do
      expected |> Enum.zip(actual) |> verify_overlay_pairs(registry)
    else
      {:error, {:binding_overlay_drift, field(unit, :id), length(expected), length(actual)}}
    end
  end

  defp verify_overlay_pairs(pairs, registry) do
    Enum.reduce_while(pairs, :ok, fn {source, row}, :ok ->
      case verify_overlay_row(source, row, registry) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp verify_overlay_row(source, row, registry) do
    case field(source, :source) do
      "local" -> verify_local_overlay_row(source, row, registry)
      _remote -> verify_remote_overlay_row(source, row)
    end
  end

  defp verify_remote_overlay_row(source, row) do
    expected = overlay_row(source)
    if expected == row, do: :ok, else: {:error, {:binding_overlay_drift, expected, row}}
  end

  defp verify_local_overlay_row(
         source,
         [application, "local", path, head, source_digest, options] = row,
         _registry
       ) do
    coordinates = field(source, :coordinates)
    provider = field(coordinates, :provider)
    repository = field(coordinates, :repository)
    expected = field(coordinates, :expected)

    with true <- application == field(source, :application) || {:error, :local_application_drift},
         true <- head == field(expected, :head) || {:error, :local_revision_drift},
         true <-
           source_digest == field(expected, :source_digest) ||
             {:error, :local_source_digest_drift},
         true <- options == source_options(source) || {:error, :local_options_drift},
         {:ok, root} <- Git.root(path),
         :ok <- verify_local_binding_identity(path, root, provider, repository),
         :ok <- verify_expected(field(provider, :id), expected, root) do
      :ok
    else
      {:error, reason} -> {:error, {:binding_overlay_drift, row, reason}}
    end
  end

  defp verify_local_overlay_row(_source, row, _registry),
    do: {:error, {:binding_overlay_drift, row, :invalid_local_row}}

  defp verify_local_binding_identity(path, root, provider, repository) do
    expected_path = root |> Path.join(field(provider, :path)) |> Path.expand()
    github = field(repository, :github)
    identities = Binding.github_identities(root)

    cond do
      Path.expand(path) != expected_path -> {:error, :local_project_path_drift}
      identities != [github] -> {:error, {:local_repository_identity_drift, github, identities}}
      true -> :ok
    end
  end

  defp overlay_row(source) do
    application = field(source, :application)
    coordinates = field(source, :coordinates)
    options = source_options(source)

    case field(source, :source) do
      "github" ->
        {revision, value} = github_revision(coordinates)

        [
          application,
          "github",
          field(coordinates, :repo),
          revision,
          value,
          field(coordinates, :subdir) || "-",
          options
        ]

      "hex" ->
        [application, "hex", field(coordinates, :requirement), options]
    end
  end

  defp source_options(source) do
    source
    |> field(:opts)
    |> Enum.map(fn option -> {option_key(field(option, :key)), field(option, :value)} end)
    |> Overlay.encode_options()
  end

  defp option_key(key) when is_atom(key), do: key
  defp option_key("hex"), do: :hex
  defp option_key("only"), do: :only
  defp option_key("optional"), do: :optional
  defp option_key("override"), do: :override
  defp option_key("runtime"), do: :runtime
  defp option_key("targets"), do: :targets

  defp github_revision(coordinates) do
    Enum.find_value([:branch, :ref, :tag], {"-", "-"}, fn key ->
      case field(coordinates, key) do
        nil -> nil
        value -> {Atom.to_string(key), value}
      end
    end)
  end

  defp execute_and_finalize(plan, bound, execution, started_at) do
    execution_result = safe_execute(bound, plan, execution)

    {launched, blitz_results} =
      case execution_result do
        {:ok, result} -> result
        {:error, _reason} -> {MapSet.new(), []}
      end

    finalized = finalize_all(bound)
    finished_at = System.system_time(:millisecond)
    results = result_rows(plan, launched, blitz_results, finalized)
    binding = binding_report(plan, finalized, execution, started_at, finished_at)

    status =
      if match?({:error, _reason}, execution_result) or
           Enum.any?(results, &(&1.status == :failed)),
         do: :failed,
         else: :passed

    report =
      %{
        schema: @run_schema,
        status: status,
        plan: plan,
        binding: binding,
        results: results
      }
      |> maybe_execution_failure(execution_result)

    if status == :passed,
      do: {:ok, report},
      else: {:error, {:fanout_failed, report}}
  end

  defp safe_execute(bound, plan, execution) do
    {:ok, execute(bound, plan, execution)}
  catch
    kind, reason ->
      {:error, {:execution_exception, kind, reason, Exception.format_stacktrace(__STACKTRACE__)}}
  end

  defp maybe_execution_failure(report, {:ok, _result}), do: report

  defp maybe_execution_failure(report, {:error, reason}),
    do: Map.put(report, :failure, %{kind: :execution, reason: inspect(reason, limit: :infinity)})

  defp execute(bound, plan, execution) do
    policy = plan |> field(:policy) |> field(:failure)

    case policy do
      value when value in [:fail_fast, "fail_fast"] -> execute_fail_fast(bound, execution)
      value when value in [:continue, "continue"] -> execute_continue(bound, execution)
    end
  end

  defp execute_continue(bound, execution) do
    results =
      bound
      |> Task.async_stream(&execute_item(&1, execution),
        max_concurrency: execution.max_concurrency,
        ordered: true,
        timeout: :infinity
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, reason} -> exit({:operation_task_exit, reason})
      end)

    {MapSet.new(Enum.map(bound, & &1.id)), results}
  end

  defp execute_fail_fast(bound, execution) do
    Enum.reduce_while(bound, {MapSet.new(), []}, fn item, {launched, results} ->
      launched = MapSet.put(launched, item.id)
      result = execute_item(item, execution)

      if Blitz.Result.failed?(result),
        do: {:halt, {launched, results ++ [result]}},
        else: {:cont, {launched, results ++ [result]}}
    end)
  end

  defp execute_item(item, execution) do
    operation = fn ->
      Runtime.with_operation_lock(item.activation.runtime_handle, fn ->
        run_item(item, execution)
      end)
    end

    operation.()
  end

  defp run_item(item, execution) do
    case Blitz.run([item.blitz], blitz_options(execution)) do
      {:ok, [result]} -> result
      {:error, %Blitz.Error{results: [result]}} -> result
    end
  end

  defp bound_executable(executable) when executable in ["elixir", "iex", "mix"],
    do: Toolchain.executable(executable)

  defp bound_executable(executable), do: executable

  defp blitz_options(execution) do
    [
      max_concurrency: execution.max_concurrency,
      timeout: execution.timeout,
      announce?: false,
      prefix_output?: true
    ]
  end

  defp finalize_all(bound) do
    Enum.map(bound, fn item ->
      case safe_finalize(item) do
        {:ok, runtime} -> put_in(item.binding.runtime, runtime)
        {:error, reason} -> finalize_failure(item, reason)
      end
    end)
  end

  defp finalize_failure(
         item,
         {:lock_mutation_not_allowed, _run_id, initial, final} = reason
       ) do
    item
    |> put_in([:binding, :runtime, :status], "rejected")
    |> put_in([:binding, :runtime, :source_lock_digest], initial)
    |> put_in([:binding, :runtime, :final_lock_digest], final)
    |> put_in([:binding, :runtime, :lock_mutated], true)
    |> Map.put(:finalize_error, reason)
  end

  defp finalize_failure(item, {:runtime_release_failed, _reason, runtime} = failure) do
    item
    |> put_in([:binding, :runtime], runtime)
    |> Map.put(:finalize_error, failure)
  end

  defp finalize_failure(item, reason), do: Map.put(item, :finalize_error, reason)

  defp safe_finalize(item) do
    finalize(item)
  catch
    kind, reason ->
      {:error, {:finalize_exception, kind, reason, Exception.format_stacktrace(__STACKTRACE__)}}
  end

  defp finalize(%{activation_kind: :overlay, activation: %{runtime_handle: handle}}),
    do: finish_handle(handle)

  defp finalize(%{activation_kind: :runtime, activation: %{runtime_handle: handle}}) do
    finish_handle(handle)
  end

  defp finish_handle(handle) do
    result = Runtime.finish(handle)

    case {result, Runtime.release(handle)} do
      {result, :ok} ->
        result

      {{:ok, runtime}, {:error, reason}} ->
        {:error, {:runtime_release_failed, reason, runtime}}

      {{:error, finish_reason}, {:error, release_reason}} ->
        {:error, {:runtime_finish_and_release_failed, finish_reason, release_reason}}
    end
  end

  defp result_rows(plan, launched, blitz_results, finalized) do
    by_id = Map.new(blitz_results, &{&1.id, &1})
    finalized_by_id = Map.new(finalized, &{&1.id, &1})

    Enum.map(field(plan, :units), fn unit ->
      id = field(unit, :id)

      cond do
        field(unit, :status) in [:absent, "absent"] ->
          %{id: id, status: :absent}

        Map.has_key?(finalized_by_id, id) and
            Map.has_key?(Map.fetch!(finalized_by_id, id), :finalize_error) ->
          item = Map.fetch!(finalized_by_id, id)

          %{
            id: id,
            status: :failed,
            result: maybe_result(by_id[id]),
            finalize_error: inspect(item.finalize_error, limit: :infinity)
          }

        MapSet.member?(launched, id) ->
          result_record(Map.fetch!(by_id, id))

        true ->
          %{id: id, status: :not_run}
      end
    end)
  end

  defp result_record(result) do
    result
    |> Map.from_struct()
    |> Map.put(:status, if(Blitz.Result.failed?(result), do: :failed, else: :passed))
  end

  defp maybe_result(nil), do: nil
  defp maybe_result(result), do: result_record(result)

  defp binding_report(plan, finalized, execution, started_at, finished_at) do
    %{
      schema: @binding_schema,
      plan_digest: field(plan, :digest),
      max_concurrency: execution.max_concurrency,
      binding_concurrency: execution.binding_concurrency,
      cache_concurrency: execution.cache_concurrency,
      beam_schedulers: execution.beam_schedulers,
      scheduler_budget: execution.resource_budget.cpu_slots,
      resource_budget: execution.resource_budget,
      probe_cache: ProbeMemo.stats(execution.probe_memo),
      timeout: execution.timeout,
      started_at: started_at,
      finished_at: finished_at,
      units: Enum.map(finalized, &binding_with_finalize_error/1)
    }
  end

  defp binding_with_finalize_error(%{finalize_error: reason, binding: binding}),
    do: Map.put(binding, :finalize_error, inspect(reason, limit: :infinity))

  defp binding_with_finalize_error(%{binding: binding}), do: binding

  defp binding_failure(plan, bound, reason, opts, started_at) do
    finalized = finalize_all(bound)
    finished_at = System.system_time(:millisecond)

    execution =
      case execution_options(plan, opts) do
        {:ok, value} -> binding_budget(plan, value)
        {:error, _invalid_options} -> failure_execution(plan, opts)
      end

    binding = binding_report(plan, finalized, execution, started_at, finished_at)

    results =
      Enum.map(field(plan, :units), fn unit ->
        status = if field(unit, :status) in [:absent, "absent"], do: :absent, else: :not_run
        %{id: field(unit, :id), status: status}
      end)

    report = %{
      schema: @run_schema,
      status: :failed,
      plan: plan,
      binding: binding,
      results: results,
      failure: %{kind: :binding, reason: inspect(reason, limit: :infinity)}
    }

    {:error, {:fanout_failed, report}}
  end

  defp command_binding(command) do
    %{
      id: command.id,
      executable: command.command,
      args: command.args,
      cd: command.cd,
      env: for({name, value} <- command.env, not is_nil(value), do: %{name: name, value: value})
    }
  end

  defp source_lock(root) do
    case File.read(Path.join(root, "mix.lock")) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, :enoent} -> {:ok, "%{}\n"}
      {:error, reason} -> {:error, {:source_lock, reason}}
    end
  end

  defp runtime_cache_identity(unit) do
    %{
      unit: field(unit, :id),
      kind: field(unit, :kind),
      repository: field(unit, :repository)
    }
    |> Report.encode()
    |> sha256()
  end

  defp current_state(root) do
    %{head: Git.head!(root), source_digest: Git.source_digest(root), clean: Git.clean?(root)}
  end

  defp source_mode(value) when is_atom(value), do: value
  defp source_mode("auto"), do: :auto
  defp source_mode("local"), do: :local
  defp source_mode("git"), do: :git
  defp source_mode("hex"), do: :hex

  defp field(map, key), do: OperationPlan.field(map, key)

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp binding_budget(plan, execution) do
    present =
      plan
      |> field(:units)
      |> Enum.count(&(field(&1, :status) in [:planned, "planned"]))

    binding_concurrency = max(1, min(execution.max_concurrency, present))
    cache_concurrency = max(1, div(execution.max_concurrency, binding_concurrency))

    Map.merge(execution, %{
      binding_concurrency: binding_concurrency,
      cache_concurrency: cache_concurrency
    })
  end

  defp scheduler_environment(env, execution) do
    current = Map.new(env)["ERL_AFLAGS"] || System.get_env("ERL_AFLAGS", "")
    scheduler_flag = "+S #{execution.beam_schedulers}:#{execution.beam_schedulers}"
    flags = String.trim(current <> " " <> scheduler_flag)

    env
    |> Map.new()
    |> Map.put("ERL_AFLAGS", flags)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp operation_class(plan) do
    tasks =
      plan |> OperationPlan.command_argv() |> PublishMode.task_argv() |> PublishMode.task_tokens()

    if Enum.any?(tasks, &(&1 in ["deps.get", "deps.update"])), do: :transport, else: :cpu
  end

  defp failure_execution(plan, opts) do
    items =
      plan
      |> field(:units)
      |> Enum.count(&(field(&1, :status) in [:planned, "planned"]))

    budget = ResourceBudget.allocate(ResourceBudget.snapshot(), operation_class(plan), items)

    binding_budget(plan, %{
      max_concurrency: budget.workers,
      beam_schedulers: budget.beam_schedulers,
      timeout: Keyword.get(opts, :timeout, :infinity),
      binding_timeout: Keyword.get(opts, :binding_timeout, 300_000),
      preparation_timeout: Keyword.get(opts, :preparation_timeout, 120_000),
      resource_budget: budget,
      probe_memo: ProbeMemo.new()
    })
  end
end
