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
    DependencyRequirement,
    Git,
    OperationPlan,
    Overlay,
    PublishMode,
    Registry,
    Report,
    ResourceBudget,
    RunReport,
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
    binding_started_at = System.monotonic_time(:millisecond)

    with {:ok, execution} <- execution_options(plan, opts),
         execution <- binding_budget(plan, execution),
         {:ok, bound, binding_failures} <- bind_all(plan, registry, execution) do
      binding_duration_ms = System.monotonic_time(:millisecond) - binding_started_at

      execute_and_finalize(
        plan,
        bound,
        binding_failures,
        execution,
        started_at,
        binding_duration_ms
      )
    else
      {:error, reason} ->
        binding_failure(plan, [], reason, opts, started_at)
    end
  end

  defp execution_options(plan, opts) do
    items =
      plan
      |> field(:units)
      |> Enum.count(&(field(&1, :status) in [:planned, "planned"]))

    resource_snapshot = Keyword.get(opts, :resource_snapshot, ResourceBudget.snapshot())

    resource_budget =
      resource_snapshot
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
    lifecycle = plan |> field(:policy) |> field(:lifecycle) |> lifecycle()

    with :ok <- positive_integer(max_concurrency, :invalid_max_concurrency),
         :ok <- valid_lifecycle(lifecycle),
         :ok <- valid_timeout(timeout),
         :ok <- positive_integer(binding_timeout, :invalid_binding_timeout),
         :ok <- positive_integer(preparation_timeout, :invalid_preparation_timeout),
         :ok <- positive_integer(beam_schedulers, :invalid_beam_schedulers),
         {:ok, state_root} <- Keyword.fetch(opts, :state_root),
         true <- is_binary(state_root) || {:error, {:invalid_state_root, state_root}},
         :ok <- Runtime.initialize(state_root),
         {:ok, report_root} <-
           RunReport.prepare(state_root, report_root: Keyword.get(opts, :report_root)) do
      {:ok,
       %{
         max_concurrency: max_concurrency,
         beam_schedulers: beam_schedulers,
         timeout: timeout,
         binding_timeout: binding_timeout,
         preparation_timeout: preparation_timeout,
         lifecycle: lifecycle,
         resource_snapshot: resource_snapshot,
         resource_budget: resource_budget,
         report_root: report_root,
         state_root: state_root,
         allow_lock_mutation: lifecycle != :run or Keyword.get(opts, :allow_lock_mutation, false),
         git_cache_memo:
           :ets.new(GitCache, [:set, :public, read_concurrency: true, write_concurrency: true]),
         hex_cache_memo:
           :ets.new(MixWorkspaceOps.HexCache, [
             :set,
             :public,
             read_concurrency: true,
             write_concurrency: true
           ]),
         transport_cache_memo:
           :ets.new(Runtime, [:set, :public, read_concurrency: true, write_concurrency: true]),
         archive_cache_memo:
           :ets.new(Runtime, [:set, :public, read_concurrency: true, write_concurrency: true]),
         repository_state_memo:
           :ets.new(Git, [:set, :public, read_concurrency: true, write_concurrency: true]),
         probe_memo: Keyword.get(opts, :probe_memo, ProbeMemo.new())
       }}
    end
  end

  defp positive_integer(value, _error) when is_integer(value) and value > 0, do: :ok
  defp positive_integer(value, error), do: {:error, {error, value}}

  defp valid_timeout(:infinity), do: :ok
  defp valid_timeout(timeout), do: positive_integer(timeout, :invalid_timeout)

  defp valid_lifecycle(value) when value in [:run, :setup, :compile, :test], do: :ok
  defp valid_lifecycle(value), do: {:error, {:invalid_lifecycle, value}}

  defp lifecycle(value) when value in [:run, :setup, :compile, :test], do: value
  defp lifecycle("run"), do: :run
  defp lifecycle("setup"), do: :setup
  defp lifecycle("compile"), do: :compile
  defp lifecycle("test"), do: :test
  defp lifecycle(value), do: value

  defp verify_repository_status(unit, registry, repository_id, repository_state_memo) do
    case {field(unit, :status), Registry.checkout(registry, repository_id)} do
      {status, {:bound, root}} when status in [:planned, "planned"] ->
        verify_expected(repository_id, field(unit, :expected), root, repository_state_memo)

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

  defp verify_expected(identity, expected, root, repository_state_memo) do
    actual = Git.state(root, repository_state_memo)

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
      |> Task.async_stream(
        fn unit -> {field(unit, :id), safe_bind_unit(plan, unit, registry, execution)} end,
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
          id = field(unit, :id)
          {id, {:error, {:binding_timeout, id, execution.binding_timeout}}}

        {:exit, {unit, reason}} ->
          id = field(unit, :id)
          {id, {:error, {:binding_task_exit, id, reason}}}
      end)

    bound =
      for {_id, {:ok, item}} <- results, not is_nil(item) do
        attach_unit_log(item, execution.report_root)
      end

    failures =
      for {id, {:error, reason}} <- results,
          into: %{},
          do: {id, reason}

    {:ok, bound, failures}
  end

  defp attach_unit_log(item, report_root) do
    output_path = RunReport.unit_log(report_root, item.id)
    blitz = %{item.blitz | output_path: output_path}

    item
    |> Map.put(:blitz, blitz)
    |> put_in([:binding, :command], command_binding(blitz))
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
      hex_cache_memo: execution.hex_cache_memo,
      transport_cache_memo: execution.transport_cache_memo,
      archive_cache_memo: execution.archive_cache_memo,
      repository_state_memo: execution.repository_state_memo,
      probe_memo: execution.probe_memo,
      state_root: execution.state_root
    ]

    with {:ok, activation} <- Overlay.activate(registry, project_id, activation_opts) do
      root = Registry.project_root(registry, project_id)

      result =
        try do
          case verify_project_activation(
                 unit,
                 activation,
                 root,
                 registry,
                 execution.repository_state_memo
               ) do
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

    with :ok <-
           verify_repository_status(
             unit,
             registry,
             repository_id,
             execution.repository_state_memo
           ),
         {:ok, lock_bytes} <- source_lock(root),
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
             hex_cache_memo: execution.hex_cache_memo,
             transport_cache_memo: execution.transport_cache_memo,
             archive_cache_memo: execution.archive_cache_memo,
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
          finalize(%{activation_kind: :runtime, activation: activation}, false)

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

  defp verify_project_activation(unit, activation, root, registry, repository_state_memo) do
    with :ok <-
           verify_expected(
             field(unit, :id),
             field(unit, :expected),
             root,
             repository_state_memo
           ),
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
         do: verify_overlay_rows(unit, activation, registry, repository_state_memo)
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

  defp verify_overlay_rows(unit, activation, registry, repository_state_memo) do
    expected = field(unit, :sources)
    actual = activation.report.rows

    if length(expected) == length(actual) do
      expected
      |> Enum.zip(actual)
      |> verify_overlay_pairs(registry, repository_state_memo)
    else
      {:error, {:binding_overlay_drift, field(unit, :id), length(expected), length(actual)}}
    end
  end

  defp verify_overlay_pairs(pairs, registry, repository_state_memo) do
    Enum.reduce_while(pairs, :ok, fn {source, row}, :ok ->
      case verify_overlay_row(source, row, registry, repository_state_memo) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp verify_overlay_row(source, row, registry, repository_state_memo) do
    case field(source, :source) do
      "local" -> verify_local_overlay_row(source, row, registry, repository_state_memo)
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
         _registry,
         repository_state_memo
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
         :ok <- verify_expected(field(provider, :id), expected, root, repository_state_memo) do
      :ok
    else
      {:error, reason} -> {:error, {:binding_overlay_drift, row, reason}}
    end
  end

  defp verify_local_overlay_row(_source, row, _registry, _repository_state_memo),
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

  defp execute_and_finalize(
         plan,
         bound,
         binding_failures,
         execution,
         started_at,
         binding_duration_ms
       ) do
    {runnable, binding_blocked} = runnable_after_binding(bound, plan, binding_failures)

    execution_result = safe_execute(runnable, plan, execution, binding_blocked)
    execution_state = execution_state_from(execution_result)

    finalized = finalize_all(bound, execution_state.accepted_locks)
    finished_at = System.system_time(:millisecond)

    report =
      completed_report(
        plan,
        bound,
        finalized,
        binding_failures,
        execution,
        %{
          result: execution_result,
          state: execution_state,
          started_at: started_at,
          finished_at: finished_at,
          binding_duration_ms: binding_duration_ms
        }
      )

    persist_report(report, execution.report_root)
  end

  defp execution_state_from({:ok, result}), do: result
  defp execution_state_from({:error, _reason}), do: empty_execution_state()

  defp completed_report(
         plan,
         bound,
         finalized,
         binding_failures,
         execution,
         outcome
       ) do
    execution_state = outcome.state
    {binding_causes, binding_cause_by_unit} = binding_causes(binding_failures)
    {finalize_causes, finalize_cause_by_unit} = finalize_causes(finalized)

    cause_by_unit =
      execution_state.cause_by_unit
      |> Map.merge(binding_cause_by_unit)
      |> Map.merge(finalize_cause_by_unit)

    blocked = resolve_blocked_causes(execution_state.blocked, cause_by_unit)

    causes =
      execution_state.causes
      |> Kernel.++(binding_causes)
      |> Kernel.++(finalize_causes)
      |> merge_causes()
      |> attach_blocked_units(blocked)

    results =
      result_rows(
        plan,
        execution_state.launched,
        execution_state.results,
        blocked,
        finalized,
        binding_failures,
        cause_by_unit
      )

    phases = [
      binding_phase(bound, binding_failures, outcome.binding_duration_ms) | execution_state.phases
    ]

    binding =
      binding_report(
        plan,
        finalized,
        binding_failures,
        execution,
        outcome.started_at,
        outcome.finished_at,
        phases
      )

    status =
      if binding_failures != %{} or match?({:error, _reason}, outcome.result) or
           Enum.any?(results, &(&1.status == :failed)),
         do: :failed,
         else: :passed

    report =
      %{
        schema: @run_schema,
        status: status,
        plan: plan,
        binding: binding,
        results: results,
        causes: causes
      }
      |> maybe_execution_failure(outcome.result)

    report
  end

  defp persist_report(report, report_root) do
    case RunReport.persist(report, report_root) do
      {:ok, persisted} when report.status == :passed -> {:ok, persisted}
      {:ok, persisted} -> {:error, {:fanout_failed, persisted}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp safe_execute(bound, plan, execution, blocked) do
    {:ok, execute(bound, plan, execution, blocked)}
  catch
    kind, reason ->
      {:error, {:execution_exception, kind, reason, Exception.format_stacktrace(__STACKTRACE__)}}
  end

  defp maybe_execution_failure(report, {:ok, _result}), do: report

  defp maybe_execution_failure(report, {:error, reason}),
    do: Map.put(report, :failure, %{kind: :execution, reason: inspect(reason, limit: :infinity)})

  defp execute(bound, plan, execution, blocked) do
    case execution.lifecycle do
      :run -> requested_execution(bound, plan, execution, blocked) |> execution_state()
      lifecycle -> execute_lifecycle(bound, plan, execution, lifecycle, blocked)
    end
  end

  defp requested_execution(bound, plan, execution, blocked) do
    case failure_policy(plan) do
      value when value in [:fail_fast, "fail_fast"] ->
        execute_graph(bound, plan, execution, blocked, :fail_fast)

      value when value in [:continue, "continue"] ->
        execute_graph(bound, plan, execution, blocked, :continue)
    end
  end

  defp execution_state({launched, results, blocked}) do
    {causes, cause_by_unit} = command_causes(results)

    %{
      launched: launched,
      results: results,
      blocked: blocked,
      phases: [],
      accepted_locks: successful_ids(results),
      causes: causes,
      cause_by_unit: cause_by_unit
    }
  end

  defp empty_execution_state,
    do: %{
      launched: MapSet.new(),
      results: [],
      blocked: %{},
      phases: [],
      accepted_locks: MapSet.new(),
      causes: [],
      cause_by_unit: %{}
    }

  defp execute_lifecycle(bound, plan, execution, lifecycle, binding_blocked) do
    population = populate_contexts(bound, plan, execution, lifecycle)

    case lifecycle do
      :setup ->
        population_state(population, binding_blocked)

      _compile_or_test ->
        lifecycle_execution(population, plan, execution, binding_blocked)
    end
  end

  defp populate_contexts(bound, plan, execution, lifecycle) do
    started_at = System.monotonic_time(:millisecond)
    groups = dependency_context_groups(bound)

    budget =
      ResourceBudget.allocate(
        execution.resource_snapshot,
        :transport,
        length(groups),
        population_budget_overrides(execution)
      )

    results =
      groups
      |> Task.async_stream(
        &safe_populate_context(&1, plan, execution, lifecycle, budget.beam_schedulers),
        max_concurrency: budget.workers,
        ordered: true,
        timeout: :infinity,
        zip_input_on_exit: true
      )
      |> Enum.map(fn
        {:ok, result} ->
          result

        {:exit, {group, reason}} ->
          population_task_failure(
            group,
            plan,
            execution,
            lifecycle,
            budget.beam_schedulers,
            reason
          )
      end)

    finished_at = System.monotonic_time(:millisecond)

    %{
      groups: results,
      budget: budget,
      duration_ms: finished_at - started_at
    }
  end

  defp dependency_context_groups(bound) do
    bound
    |> Enum.group_by(& &1.binding.runtime.dependency_identity)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {identity, items} -> {identity, Enum.sort_by(items, & &1.id)} end)
  end

  defp population_budget_overrides(execution) do
    []
    |> maybe_budget_override(
      :max_concurrency,
      execution.max_concurrency,
      execution.resource_budget.worker_override
    )
    |> maybe_budget_override(
      :beam_schedulers,
      execution.beam_schedulers,
      execution.resource_budget.scheduler_override
    )
  end

  defp maybe_budget_override(options, key, value, true), do: Keyword.put(options, key, value)
  defp maybe_budget_override(options, _key, _value, false), do: options

  defp populate_context({identity, items}, plan, execution, lifecycle, beam_schedulers) do
    representative = hd(items)
    command = population_command(representative, plan, execution, lifecycle, beam_schedulers)

    result =
      case Blitz.run([command], blitz_options(execution, prefix_output?: false)) do
        {:ok, [result]} -> result
        {:error, %Blitz.Error{results: [result]}} -> result
      end

    result =
      if Blitz.Result.failed?(result) do
        result
      else
        with :ok <- validate_populated_requirements(representative, plan, execution),
             :ok <- synchronize_context_locks(representative, tl(items)) do
          result
        else
          {:error, reason} ->
            Blitz.Result.worker_crash(
              command,
              result.duration_ms,
              result.output_tail,
              inspect(reason, limit: :infinity)
            )
        end
      end

    %{identity: identity, items: items, representative: representative, result: result}
  end

  defp safe_populate_context(group, plan, execution, lifecycle, beam_schedulers) do
    started_at = System.monotonic_time(:millisecond)

    try do
      populate_context(group, plan, execution, lifecycle, beam_schedulers)
    catch
      kind, reason ->
        population_task_failure(
          group,
          plan,
          execution,
          lifecycle,
          beam_schedulers,
          {kind, reason, Exception.format_stacktrace(__STACKTRACE__)},
          System.monotonic_time(:millisecond) - started_at
        )
    end
  end

  defp population_task_failure(
         {identity, items},
         plan,
         execution,
         lifecycle,
         beam_schedulers,
         reason,
         duration_ms \\ 0
       ) do
    representative = hd(items)
    command = population_command(representative, plan, execution, lifecycle, beam_schedulers)

    %{
      identity: identity,
      items: items,
      representative: representative,
      result:
        Blitz.Result.worker_crash(
          command,
          duration_ms,
          [],
          inspect({:population_task_exit, reason}, limit: :infinity)
        )
    }
  end

  defp population_command(item, plan, execution, lifecycle, beam_schedulers) do
    mix_env = plan |> field(:policy) |> field(:mix_env)
    args = if lifecycle == :setup, do: ["deps.get"], else: ["deps.get", "--only", mix_env]

    Blitz.command(%{
      id: item.id,
      command: Toolchain.executable("mix"),
      args: args,
      cd: item.blitz.cd,
      env: population_scheduler_environment(item.blitz.env, beam_schedulers),
      output_path:
        RunReport.context_log(execution.report_root, item.binding.runtime.dependency_identity)
    })
  end

  defp validate_populated_requirements(item, plan, execution) do
    policy = field(plan, :policy)

    DependencyRequirement.validate_runtime(
      item.activation.report,
      item.activation.runtime_handle.lockfile,
      item.binding.runtime.deps_path,
      mix_env: field(policy, :mix_env),
      mix_target: field(policy, :mix_target),
      probe_memo: execution.probe_memo
    )
  end

  defp synchronize_context_locks(representative, consumers) do
    source = representative.activation.runtime_handle.lockfile

    case File.read(source) do
      {:ok, bytes} -> Enum.reduce_while(consumers, :ok, &synchronize_context_lock(&1, bytes, &2))
      {:error, reason} -> {:error, {:context_lock_read, source, reason}}
    end
  end

  defp synchronize_context_lock(item, bytes, :ok) do
    destination = item.activation.runtime_handle.lockfile

    case replace_private(destination, bytes) do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, {:context_lock_copy, destination, reason}}}
    end
  end

  defp replace_private(path, bytes) do
    temporary =
      path <> ".tmp-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    with :ok <- File.write(temporary, bytes, [:write, :exclusive]),
         :ok <- File.chmod(temporary, 0o600),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(temporary)
        {:error, reason}
    end
  end

  defp population_state(population, binding_blocked) do
    {launched, results, blocked} = population_results(population, true)
    {causes, cause_by_unit} = population_causes(population)

    %{
      launched: launched,
      results: results,
      blocked: Map.merge(binding_blocked, blocked),
      phases: [population_phase(population)],
      accepted_locks: successful_population_ids(population),
      causes: causes,
      cause_by_unit: cause_by_unit
    }
  end

  defp lifecycle_execution(population, plan, execution, binding_blocked) do
    {_population_launched, population_failures, context_blocked} =
      population_results(population, false)

    ready =
      population.groups
      |> Enum.reject(&Blitz.Result.failed?(&1.result))
      |> Enum.flat_map(& &1.items)

    population_failed? = Enum.any?(population.groups, &Blitz.Result.failed?(&1.result))

    {ready, blocked} =
      ready_after_population(
        ready,
        plan,
        population,
        Map.merge(binding_blocked, context_blocked)
      )

    ready = if population_failed? and failure_policy(plan) == :fail_fast, do: [], else: ready
    started_at = System.monotonic_time(:millisecond)

    {launched, requested_results, blocked} =
      requested_execution(ready, plan, execution, blocked)

    finished_at = System.monotonic_time(:millisecond)
    {population_causes, population_cause_by_unit} = population_causes(population)
    {command_causes, command_cause_by_unit} = command_causes(requested_results)

    %{
      launched: Enum.reduce(population_failures, launched, &MapSet.put(&2, &1.id)),
      results: population_failures ++ requested_results,
      blocked: blocked,
      phases: [
        population_phase(population),
        %{
          name: :execute,
          units: length(ready),
          duration_ms: finished_at - started_at,
          budget: execution.resource_budget
        }
      ],
      accepted_locks: successful_population_ids(population),
      causes: merge_causes(population_causes ++ command_causes),
      cause_by_unit: Map.merge(population_cause_by_unit, command_cause_by_unit)
    }
  end

  defp successful_population_ids(population) do
    population.groups
    |> Enum.reject(&Blitz.Result.failed?(&1.result))
    |> Enum.flat_map(& &1.items)
    |> MapSet.new(& &1.id)
  end

  defp successful_ids(results) do
    results
    |> Enum.reject(&Blitz.Result.failed?/1)
    |> MapSet.new(& &1.id)
  end

  defp command_causes(results) do
    failed = Enum.filter(results, &Blitz.Result.failed?/1)

    records =
      Enum.map(failed, fn result ->
        paths = [result.cd]

        cause_record(
          %{
            kind: :command,
            command: [result.command | result.args],
            failure_kind: result.failure_kind,
            exit_code: result.exit_code,
            reason: normalize_diagnostic(result.failure_reason, paths),
            diagnostic: result.output_tail |> Enum.take(-5) |> normalize_diagnostic(paths)
          },
          [result.id],
          [result.output_path]
        )
      end)

    by_unit = Map.new(Enum.zip(Enum.map(failed, & &1.id), Enum.map(records, & &1.id)))
    {merge_causes(records), by_unit}
  end

  defp population_results(population, include_successes?) do
    Enum.reduce(
      population.groups,
      {MapSet.new(), [], %{}},
      &population_result(&1, include_successes?, &2)
    )
  end

  defp population_result(group, include_successes?, state) do
    if Blitz.Result.failed?(group.result),
      do: failed_population_result(group, state),
      else: successful_population_result(group, include_successes?, state)
  end

  defp failed_population_result(group, {launched, results, blocked}) do
    cause = population_cause(group)
    [representative | consumers] = group.items

    blocked =
      Map.merge(
        blocked,
        Map.new(
          consumers,
          &{&1.id, %{kind: :dependency_context, cause: cause, context: group.identity}}
        )
      )

    {MapSet.put(launched, representative.id), results ++ [group.result], blocked}
  end

  defp successful_population_result(
         group,
         include_successes?,
         {launched, results, blocked}
       ) do
    successful =
      if include_successes?,
        do: Enum.map(group.items, &%{group.result | id: &1.id, cd: &1.blitz.cd}),
        else: []

    ids = if include_successes?, do: Enum.map(group.items, & &1.id), else: []
    {MapSet.union(launched, MapSet.new(ids)), results ++ successful, blocked}
  end

  defp population_cause(group), do: group |> population_cause_record() |> Map.fetch!(:id)

  defp population_causes(population) do
    failed = Enum.filter(population.groups, &Blitz.Result.failed?(&1.result))
    records = Enum.map(failed, &population_cause_record/1)

    by_unit =
      Map.new(
        for group <- failed,
            item <- group.items do
          {item.id, population_cause(group)}
        end
      )

    {records, by_unit}
  end

  defp population_cause_record(group) do
    paths =
      group.items
      |> Enum.flat_map(fn item ->
        runtime = item.binding.runtime

        [
          item.blitz.cd,
          runtime.root,
          runtime.deps_path,
          runtime.build_path,
          runtime.lockfile
        ]
      end)

    cause_record(
      %{
        kind: :dependency_context,
        failure_kind: group.result.failure_kind,
        exit_code: group.result.exit_code,
        reason: normalize_diagnostic(group.result.failure_reason, paths),
        diagnostic: group.result.output_tail |> Enum.take(-5) |> normalize_diagnostic(paths)
      },
      Enum.map(group.items, & &1.id),
      [group.result.output_path],
      [group.identity]
    )
  end

  defp binding_causes(failures) do
    entries = Enum.sort_by(failures, &elem(&1, 0))

    records =
      Enum.map(entries, fn {id, reason} ->
        cause_record(%{kind: :binding, reason: inspect(reason, limit: :infinity)}, [id], [])
      end)

    by_unit = Map.new(Enum.zip(Enum.map(entries, &elem(&1, 0)), Enum.map(records, & &1.id)))
    {merge_causes(records), by_unit}
  end

  defp finalize_causes(finalized) do
    failed = Enum.filter(finalized, &Map.has_key?(&1, :finalize_error))

    records =
      Enum.map(failed, fn item ->
        cause_record(
          %{kind: :runtime_finalization, reason: inspect(item.finalize_error, limit: :infinity)},
          [item.id],
          []
        )
      end)

    by_unit = Map.new(Enum.zip(Enum.map(failed, & &1.id), Enum.map(records, & &1.id)))
    {merge_causes(records), by_unit}
  end

  defp cause_record(canonical, affected_units, log_paths, affected_contexts \\ []) do
    canonical
    |> Map.put(:id, canonical |> Report.encode() |> sha256())
    |> Map.put(:affected_units, Enum.sort(affected_units))
    |> Map.put(:affected_contexts, Enum.sort(affected_contexts))
    |> Map.put(:log_paths, log_paths |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort())
  end

  defp merge_causes(records) do
    records
    |> Enum.reduce(%{}, fn record, causes ->
      Map.update(causes, record.id, record, fn existing ->
        existing
        |> Map.update!(:affected_units, &Enum.sort(Enum.uniq(&1 ++ record.affected_units)))
        |> Map.update!(
          :affected_contexts,
          &Enum.sort(Enum.uniq(&1 ++ record.affected_contexts))
        )
        |> Map.update!(:log_paths, &Enum.sort(Enum.uniq(&1 ++ record.log_paths)))
      end)
    end)
    |> Map.values()
    |> Enum.sort_by(& &1.id)
  end

  defp normalize_diagnostic(nil, _paths), do: nil

  defp normalize_diagnostic(lines, paths) when is_list(lines),
    do: Enum.map(lines, &normalize_diagnostic(&1, paths))

  defp normalize_diagnostic(value, paths) when is_binary(value) do
    paths
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.sort_by(&byte_size/1, :desc)
    |> Enum.reduce(value, &String.replace(&2, &1, "$PATH"))
  end

  defp population_phase(population) do
    failures = Enum.count(population.groups, &Blitz.Result.failed?(&1.result))

    %{
      name: :populate,
      contexts: length(population.groups),
      passed: length(population.groups) - failures,
      failed: failures,
      duration_ms: population.duration_ms,
      budget: population.budget
    }
  end

  defp binding_phase(bound, failures, duration_ms) do
    %{
      name: :bind,
      passed: length(bound),
      failed: map_size(failures),
      duration_ms: duration_ms
    }
  end

  defp failure_policy(plan) do
    case plan |> field(:policy) |> field(:failure) do
      value when value in [:fail_fast, "fail_fast"] -> :fail_fast
      value when value in [:continue, "continue"] -> :continue
    end
  end

  defp runnable_after_binding(bound, plan, failures) do
    if failures != %{} and failure_policy(plan) == :fail_fast do
      {[], %{}}
    else
      blockers =
        Map.new(failures, fn {id, _reason} ->
          {id, %{kind: :project_dependency, root_unit: id}}
        end)

      {runnable, _blockers, blocked} =
        block_failed_dependants(bound, plan_dependencies(plan), blockers, %{})

      {runnable, blocked}
    end
  end

  defp ready_after_population(ready, plan, population, blocked) do
    blockers =
      population.groups
      |> Enum.filter(&Blitz.Result.failed?(&1.result))
      |> Enum.flat_map(fn group ->
        cause = population_cause(group)
        Enum.map(group.items, &{&1.id, %{kind: :dependency_context, cause: cause}})
      end)
      |> Map.new()

    {ready, _blockers, blocked} =
      block_failed_dependants(ready, plan_dependencies(plan), blockers, blocked)

    {ready, blocked}
  end

  defp plan_dependencies(plan) do
    plan
    |> field(:units)
    |> Map.new(fn unit ->
      {field(unit, :id), Enum.map(field(unit, :dependencies), &to_string/1)}
    end)
  end

  defp block_failed_dependants(pending, dependencies, blockers, blocked) do
    {pending, blockers, blocked, changed?} =
      Enum.reduce(pending, {[], blockers, blocked, false}, fn item,
                                                              {ready, known, held, changed?} ->
        blocker =
          dependencies
          |> Map.get(item.id, [])
          |> Enum.find(&Map.has_key?(known, &1))

        if blocker do
          failure = dependency_block(blocker, Map.fetch!(known, blocker))
          {ready, Map.put(known, item.id, failure), Map.put(held, item.id, failure), true}
        else
          {[item | ready], known, held, changed?}
        end
      end)

    pending = Enum.reverse(pending)

    if changed?,
      do: block_failed_dependants(pending, dependencies, blockers, blocked),
      else: {pending, blockers, blocked}
  end

  defp dependency_block(failed_unit, %{cause: cause}) do
    %{kind: :project_dependency, failed_unit: failed_unit, cause: cause}
  end

  defp dependency_block(failed_unit, %{root_unit: root_unit}) do
    %{kind: :project_dependency, failed_unit: failed_unit, root_unit: root_unit}
  end

  defp resolve_blocked_causes(blocked, cause_by_unit) do
    Map.new(blocked, fn
      {id, %{root_unit: root_unit} = failure} ->
        {id,
         failure
         |> Map.delete(:root_unit)
         |> Map.put(:cause, Map.fetch!(cause_by_unit, root_unit))}

      entry ->
        entry
    end)
  end

  defp attach_blocked_units(causes, blocked) do
    affected_by_cause =
      Enum.reduce(blocked, %{}, fn {unit, %{cause: cause}}, acc ->
        Map.update(acc, cause, [unit], &[unit | &1])
      end)

    Enum.map(causes, fn cause ->
      affected = Map.get(affected_by_cause, cause.id, [])
      Map.update!(cause, :affected_units, &Enum.sort(Enum.uniq(&1 ++ affected)))
    end)
  end

  defp execute_graph(bound, plan, execution, blocked, policy) do
    execute_ready_waves(%{
      pending: bound,
      dependencies: plan_dependencies(plan),
      all_ids: MapSet.new(bound, & &1.id),
      execution: execution,
      policy: policy,
      completed: MapSet.new(),
      blockers: %{},
      launched: MapSet.new(),
      results: [],
      blocked: blocked
    })
  end

  defp execute_ready_waves(%{pending: []} = state),
    do: {state.launched, state.results, state.blocked}

  defp execute_ready_waves(state) do
    {pending, blockers, blocked} =
      block_failed_dependants(
        state.pending,
        state.dependencies,
        state.blockers,
        state.blocked
      )

    ready =
      Enum.filter(pending, fn item ->
        state.dependencies
        |> Map.get(item.id, [])
        |> Enum.all?(&dependency_complete?(&1, state.all_ids, state.completed))
      end)
      |> maybe_take_fail_fast(state.policy)

    cond do
      pending == [] ->
        {state.launched, state.results, blocked}

      ready == [] ->
        exit({:operation_dependency_cycle, Enum.map(pending, & &1.id)})

      true ->
        batch_results = execute_batch(ready, state.execution)
        batch_ids = MapSet.new(ready, & &1.id)
        pending = Enum.reject(pending, &MapSet.member?(batch_ids, &1.id))
        failed = Enum.filter(batch_results, &Blitz.Result.failed?/1)

        blockers =
          Enum.reduce(failed, blockers, fn result, acc ->
            Map.put(acc, result.id, %{kind: :project_dependency, root_unit: result.id})
          end)

        completed =
          batch_results
          |> Enum.reject(&Blitz.Result.failed?/1)
          |> Enum.reduce(state.completed, &MapSet.put(&2, &1.id))

        state = %{
          state
          | pending: pending,
            completed: completed,
            blockers: blockers,
            launched: Enum.reduce(ready, state.launched, &MapSet.put(&2, &1.id)),
            results: state.results ++ batch_results,
            blocked: blocked
        }

        continue_ready_waves(state, failed)
    end
  end

  defp continue_ready_waves(%{policy: :fail_fast} = state, [_failed | _rest]) do
    {_pending, _blockers, blocked} =
      block_failed_dependants(
        state.pending,
        state.dependencies,
        state.blockers,
        state.blocked
      )

    {state.launched, state.results, blocked}
  end

  defp continue_ready_waves(state, _failed), do: execute_ready_waves(state)

  defp execute_batch(items, execution) do
    items
    |> Task.async_stream(&safe_execute_item(&1, execution),
      max_concurrency: execution.max_concurrency,
      ordered: true,
      timeout: :infinity,
      zip_input_on_exit: true
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, {item, reason}} -> operation_task_failure(item, reason, 0)
    end)
  end

  defp safe_execute_item(item, execution) do
    started_at = System.monotonic_time(:millisecond)

    try do
      execute_item(item, execution)
    catch
      kind, reason ->
        operation_task_failure(
          item,
          {kind, reason, Exception.format_stacktrace(__STACKTRACE__)},
          System.monotonic_time(:millisecond) - started_at
        )
    end
  end

  defp operation_task_failure(item, reason, duration_ms) do
    Blitz.Result.worker_crash(
      item.blitz,
      duration_ms,
      [],
      inspect({:operation_task_exit, reason}, limit: :infinity)
    )
  end

  defp dependency_complete?(dependency, all_ids, completed),
    do: not MapSet.member?(all_ids, dependency) or MapSet.member?(completed, dependency)

  defp maybe_take_fail_fast(items, :fail_fast), do: Enum.take(items, 1)
  defp maybe_take_fail_fast(items, :continue), do: items

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

  defp blitz_options(execution, overrides \\ []) do
    Keyword.merge(
      [
        max_concurrency: execution.max_concurrency,
        timeout: execution.timeout,
        announce?: false,
        emit_output?: false,
        prefix_output?: false
      ],
      overrides
    )
  end

  defp finalize_all(bound, accepted_locks) do
    Enum.map(bound, fn item ->
      case safe_finalize(item, MapSet.member?(accepted_locks, item.id)) do
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

  defp safe_finalize(item, accept_lock_mutation?) do
    finalize(item, accept_lock_mutation?)
  catch
    kind, reason ->
      {:error, {:finalize_exception, kind, reason, Exception.format_stacktrace(__STACKTRACE__)}}
  end

  defp finalize(
         %{activation_kind: :overlay, activation: %{runtime_handle: handle}},
         accept_lock_mutation?
       ),
       do: finish_handle(handle, accept_lock_mutation?)

  defp finalize(
         %{activation_kind: :runtime, activation: %{runtime_handle: handle}},
         accept_lock_mutation?
       ) do
    finish_handle(handle, accept_lock_mutation?)
  end

  defp finish_handle(handle, accept_lock_mutation?) do
    result = Runtime.finish(handle, accept_lock_mutation: accept_lock_mutation?)

    case {result, Runtime.release(handle)} do
      {result, :ok} ->
        result

      {{:ok, runtime}, {:error, reason}} ->
        {:error, {:runtime_release_failed, reason, runtime}}

      {{:error, finish_reason}, {:error, release_reason}} ->
        {:error, {:runtime_finish_and_release_failed, finish_reason, release_reason}}
    end
  end

  defp result_rows(
         plan,
         launched,
         blitz_results,
         blocked,
         finalized,
         binding_failures,
         cause_by_unit
       ) do
    by_id = Map.new(blitz_results, &{&1.id, &1})
    finalized_by_id = Map.new(finalized, &{&1.id, &1})

    Enum.map(field(plan, :units), fn unit ->
      id = field(unit, :id)

      cond do
        field(unit, :status) in [:absent, "absent"] ->
          %{id: id, status: :absent}

        Map.has_key?(binding_failures, id) ->
          %{
            id: id,
            status: :failed,
            failure: %{kind: :binding, cause: Map.fetch!(cause_by_unit, id)}
          }

        Map.has_key?(blocked, id) ->
          %{id: id, status: :blocked, failure: Map.fetch!(blocked, id)}

        Map.has_key?(finalized_by_id, id) and
            Map.has_key?(Map.fetch!(finalized_by_id, id), :finalize_error) ->
          item = Map.fetch!(finalized_by_id, id)

          %{
            id: id,
            status: :failed,
            cause: Map.fetch!(cause_by_unit, id),
            result: maybe_result(by_id[id], Map.get(cause_by_unit, id)),
            finalize_error: inspect(item.finalize_error, limit: :infinity)
          }

        MapSet.member?(launched, id) ->
          result_record(Map.fetch!(by_id, id), Map.get(cause_by_unit, id))

        true ->
          %{id: id, status: :not_run}
      end
    end)
  end

  defp result_record(result, cause_id) do
    record =
      result
      |> Map.from_struct()
      |> Map.put(:status, if(Blitz.Result.failed?(result), do: :failed, else: :passed))

    if cause_id, do: Map.put(record, :cause, cause_id), else: record
  end

  defp maybe_result(nil, _cause_id), do: nil
  defp maybe_result(result, cause_id), do: result_record(result, cause_id)

  defp binding_report(
         plan,
         finalized,
         binding_failures,
         execution,
         started_at,
         finished_at,
         phases
       ) do
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
      lifecycle: execution.lifecycle,
      started_at: started_at,
      finished_at: finished_at,
      phases: phases,
      failures:
        binding_failures
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(fn {id, reason} ->
          %{id: id, reason: inspect(reason, limit: :infinity)}
        end),
      units: Enum.map(finalized, &binding_with_finalize_error/1)
    }
  end

  defp binding_with_finalize_error(%{finalize_error: reason, binding: binding}),
    do: Map.put(binding, :finalize_error, inspect(reason, limit: :infinity))

  defp binding_with_finalize_error(%{binding: binding}), do: binding

  defp binding_failure(plan, bound, reason, opts, started_at) do
    finalized = finalize_all(bound, MapSet.new())
    finished_at = System.system_time(:millisecond)

    execution = failure_execution(plan, opts)

    binding = binding_report(plan, finalized, %{}, execution, started_at, finished_at, [])

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
      output_path: command.output_path,
      env: report_environment(command.env)
    }
  end

  defp report_environment(environment) do
    for {name, value} <- environment,
        not is_nil(value),
        not Regex.match?(~r/^GIT_CONFIG_(KEY|VALUE)_\d+$/, name),
        do: %{name: name, value: value}
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
    current = Map.new(env)["ERL_AFLAGS"] || ""
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
      resource_snapshot:
        Map.take(budget, [:logical_schedulers, :load_one, :memory_total, :memory_available]),
      lifecycle: plan |> field(:policy) |> field(:lifecycle) |> lifecycle(),
      probe_memo: ProbeMemo.new()
    })
  end

  defp population_scheduler_environment(env, beam_schedulers) do
    env
    |> Map.new()
    |> Map.put("ERL_AFLAGS", "+S #{beam_schedulers}:#{beam_schedulers}")
    |> Enum.sort_by(&elem(&1, 0))
  end
end
