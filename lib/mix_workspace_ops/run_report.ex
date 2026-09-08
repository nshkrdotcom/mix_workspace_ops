defmodule MixWorkspaceOps.RunReport do
  @moduledoc false

  alias MixWorkspaceOps.{OperationPlan, Report}

  @summary_schema "mix_workspace_ops.run_summary/v1"
  @lease_schema "mix_workspace_ops.run_report_lease/v1"
  @cause_sample_limit 8
  @diagnostic_line_limit 500
  @reason_limit 1_000

  @spec prepare(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def prepare(state_root, opts \\ []) do
    {root, parent_mode} = report_root(state_root, Keyword.get(opts, :report_root))

    with :ok <- prepare_parent(Path.dirname(root), parent_mode) do
      create_report(root)
    end
  end

  defp report_root(state_root, nil),
    do: {Path.join([Path.expand(state_root), "reports", report_id()]), :private}

  defp report_root(_state_root, path), do: {Path.expand(path), :preserve}

  defp prepare_parent(path, :private), do: create_private_directory(path)
  defp prepare_parent(path, :preserve), do: File.mkdir_p(path)

  defp create_report(root) do
    case create_new_private_directory(root) do
      :ok -> finish_report(root)
      {:error, reason} -> {:error, reason}
    end
  end

  defp finish_report(root) do
    with :ok <- create_private_directory(Path.join(root, "contexts")),
         :ok <- create_private_directory(Path.join(root, "units")),
         :ok <- write_lease(root) do
      {:ok, root}
    else
      {:error, reason} ->
        _ = File.rm_rf(root)
        {:error, reason}
    end
  end

  @spec context_log(String.t(), String.t()) :: String.t()
  def context_log(root, identity),
    do: Path.join([root, "contexts", digest(identity) <> ".log"])

  @spec unit_log(String.t(), String.t()) :: String.t()
  def unit_log(root, id), do: Path.join([root, "units", digest(id) <> ".log"])

  @spec persist(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def persist(report, root) do
    path = Path.join(root, "report.json")
    report = Map.put(report, :detail_path, path)
    temporary = path <> ".tmp-" <> random_suffix()

    with :ok <- File.write(temporary, Report.encode(report) <> "\n", [:write, :exclusive]),
         :ok <- File.chmod(temporary, 0o600),
         :ok <- File.rename(temporary, path),
         :ok <- remove_lease(root) do
      {:ok, report}
    else
      {:error, reason} ->
        _ = File.rm(temporary)
        {:error, {:run_report_write, path, reason}}
    end
  end

  @doc "Lists durable and incomplete command-report directories."
  @spec list(String.t()) :: [map()]
  def list(state_root) do
    state_root
    |> Path.expand()
    |> Path.join("reports/*")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.flat_map(&report_entry/1)
  end

  @doc "Removes old complete or abandoned command reports, never a live report."
  @spec gc(String.t(), non_neg_integer(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def gc(state_root, older_than_seconds, opts \\ [])

  def gc(state_root, older_than_seconds, opts)
      when is_integer(older_than_seconds) and older_than_seconds >= 0 do
    now = Keyword.get(opts, :now, System.system_time(:second))
    dry_run? = Keyword.get(opts, :dry_run, false)

    candidates =
      state_root
      |> list()
      |> Enum.filter(&(not &1.active and &1.created_at <= now - older_than_seconds))

    if dry_run? do
      {:ok, candidates}
    else
      remove_reports(candidates, Path.join(Path.expand(state_root), "reports"))
    end
  end

  def gc(_state_root, older_than_seconds, _opts),
    do: {:error, {:invalid_gc_age, older_than_seconds}}

  @spec summary(map()) :: map()
  def summary(report) do
    binding = field(report, :binding, %{})
    results = field(report, :results, [])
    plan = field(report, :plan, %{})

    %{
      schema: @summary_schema,
      status: field(report, :status),
      plan_digest: field(binding, :plan_digest),
      lifecycle: field(binding, :lifecycle, :run),
      command: command_argv(plan),
      counts: result_counts(results),
      causes: report |> field(:causes, []) |> Enum.map(&compact_cause/1),
      phases: field(binding, :phases, []),
      resource_budget: field(binding, :resource_budget),
      duration_ms: duration(binding),
      detail_path: field(report, :detail_path)
    }
  end

  defp result_counts(results) do
    counts = Enum.frequencies_by(results, &field(&1, :status))

    [:passed, :failed, :blocked, :not_run, :absent]
    |> Map.new(&{&1, Map.get(counts, &1, 0)})
    |> Map.put(:total, length(results))
  end

  defp compact_cause(cause) do
    affected = field(cause, :affected_units, [])
    contexts = field(cause, :affected_contexts, [])
    logs = field(cause, :log_paths, [])

    cause
    |> Map.put(:affected_count, length(affected))
    |> Map.put(:affected_units, Enum.take(affected, @cause_sample_limit))
    |> Map.put(:context_count, length(contexts))
    |> Map.put(:affected_contexts, Enum.take(contexts, @cause_sample_limit))
    |> Map.put(:log_count, length(logs))
    |> Map.put(:log_paths, Enum.take(logs, @cause_sample_limit))
    |> Map.update(:reason, nil, &truncate(&1, @reason_limit))
    |> Map.update(:diagnostic, [], fn lines ->
      Enum.map(lines, &truncate(&1, @diagnostic_line_limit))
    end)
  end

  defp truncate(value, limit) when is_binary(value) and byte_size(value) > limit,
    do: binary_part(value, 0, limit) <> "…"

  defp truncate(value, _limit), do: value

  defp duration(binding) do
    with started when is_integer(started) <- field(binding, :started_at),
         finished when is_integer(finished) <- field(binding, :finished_at) do
      max(0, finished - started)
    else
      _unavailable -> nil
    end
  end

  defp command_argv(plan) when is_map(plan), do: OperationPlan.command_argv(plan)
  defp command_argv(_plan), do: []

  defp create_private_directory(path) do
    with :ok <- File.mkdir_p(path), do: File.chmod(path, 0o700)
  end

  defp create_new_private_directory(path) do
    with :ok <- File.mkdir(path), do: File.chmod(path, 0o700)
  end

  defp write_lease(root) do
    Report.write(Path.join(root, "lease.json"), %{
      schema: @lease_schema,
      pid: System.pid(),
      process_start: process_start(System.pid())
    })
  end

  defp remove_lease(root) do
    case File.rm(Path.join(root, "lease.json")) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp report_entry(path) do
    with true <- ordinary_directory?(path),
         {:ok, created_at} <- report_timestamp(Path.basename(path)) do
      lease = report_lease(path)

      [
        %{
          id: Path.basename(path),
          path: path,
          created_at: created_at,
          complete: File.regular?(Path.join(path, "report.json")),
          active: lease.active,
          lease_pid: lease.pid
        }
      ]
    else
      _invalid -> []
    end
  end

  defp report_timestamp(id) do
    case Integer.parse(id) do
      {microseconds, "-" <> suffix} when microseconds >= 0 and byte_size(suffix) > 0 ->
        {:ok, div(microseconds, 1_000_000)}

      _invalid ->
        :error
    end
  end

  defp report_lease(path) do
    case File.read(Path.join(path, "lease.json")) do
      {:ok, bytes} -> decode_lease(bytes)
      {:error, _missing_or_unreadable} -> %{active: false, pid: nil}
    end
  end

  defp decode_lease(bytes) do
    with lease when is_map(lease) <- :json.decode(bytes),
         true <- lease["schema"] == @lease_schema,
         pid when is_binary(pid) <- lease["pid"] do
      %{active: process_alive?(pid, null_to_nil(lease["process_start"])), pid: pid}
    else
      _invalid -> %{active: false, pid: nil}
    end
  rescue
    _invalid -> %{active: false, pid: nil}
  end

  defp process_alive?(pid, expected_start) when is_binary(pid) do
    Regex.match?(~r/^\d+$/, pid) and
      case expected_start do
        nil -> pid == System.pid() or File.dir?(Path.join("/proc", pid))
        expected -> process_start(pid) == expected
      end
  end

  defp null_to_nil(value) when value in [nil, :null], do: nil
  defp null_to_nil(value), do: value

  defp process_start(pid) do
    with {:ok, stat} <- File.read(Path.join(["/proc", pid, "stat"])),
         [_command, fields] <- String.split(stat, ") ", parts: 2),
         value when is_binary(value) <- fields |> String.split() |> Enum.at(19) do
      value
    else
      _unavailable -> nil
    end
  end

  defp remove_reports(reports, parent) do
    Enum.reduce_while(reports, {:ok, []}, fn report, {:ok, removed} ->
      path = Path.expand(report.path)

      case remove_report(path, parent) do
        :ok -> {:cont, {:ok, [report | removed]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, removed} -> {:ok, Enum.reverse(removed)}
      error -> error
    end
  end

  defp remove_report(path, parent) do
    if Path.dirname(path) == parent and ordinary_directory?(path) do
      case File.rm_rf(path) do
        {:ok, _paths} -> :ok
        {:error, reason, failed_path} -> {:error, {:run_report_gc, failed_path, reason}}
      end
    else
      {:error, {:unsafe_run_report_gc_target, path}}
    end
  end

  defp ordinary_directory?(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} -> true
      _other -> false
    end
  end

  defp report_id do
    Integer.to_string(System.system_time(:microsecond)) <> "-" <> random_suffix()
  end

  defp random_suffix,
    do: 8 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp digest(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp field(map, key, default \\ nil)

  defp field(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp field(_value, _key, default), do: default
end
