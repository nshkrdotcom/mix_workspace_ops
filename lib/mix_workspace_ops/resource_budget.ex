defmodule MixWorkspaceOps.ResourceBudget do
  @moduledoc """
  One invocation's small, deterministic host-resource budget.

  The host is sampled once before workers start. CPU headroom and work already
  present at that instant are reserved; MWO never feeds its own later load back
  into the calculation. Missing Linux load or memory data simply removes that
  optional constraint.
  """

  @gib 1024 * 1024 * 1024

  @type operation_class :: :transport | :cpu
  @type snapshot :: %{
          required(:logical_schedulers) => pos_integer(),
          optional(:load_one) => float() | nil,
          optional(:memory_total) => non_neg_integer() | nil,
          optional(:memory_available) => non_neg_integer() | nil
        }

  @doc "Takes the one host snapshot used for an invocation."
  @spec snapshot() :: snapshot()
  def snapshot do
    Map.merge(
      %{logical_schedulers: System.schedulers_online()},
      Map.merge(read_load(), read_memory())
    )
  end

  @doc "Allocates workers and child schedulers for one class of work."
  @spec allocate(snapshot(), operation_class(), non_neg_integer(), keyword()) :: map()
  def allocate(snapshot, class, items, opts \\ [])

  def allocate(snapshot, class, items, opts)
      when class in [:transport, :cpu] and is_integer(items) and items >= 0 do
    logical = positive(Map.fetch!(snapshot, :logical_schedulers))
    headroom = max(1, ceil_div(logical, 12))
    external_load = snapshot |> Map.get(:load_one) |> load_floor()
    cpu_slots = max(1, logical - headroom - external_load)
    memory_per_worker = if class == :transport, do: div(@gib, 4), else: @gib
    memory_slots = memory_slots(snapshot, memory_per_worker)
    natural_workers = max(1, min(items, cpu_slots))
    bounded_workers = min_optional(natural_workers, memory_slots)
    worker_override = Keyword.get(opts, :max_concurrency)
    workers = override_or(worker_override, bounded_workers)

    natural_schedulers =
      if class == :transport,
        do: 1,
        else: max(1, div(cpu_slots, workers))

    scheduler_override = Keyword.get(opts, :beam_schedulers)
    schedulers = override_or(scheduler_override, natural_schedulers)

    %{
      operation_class: class,
      items: items,
      logical_schedulers: logical,
      load_one: Map.get(snapshot, :load_one),
      external_load: external_load,
      cpu_headroom: headroom,
      cpu_slots: cpu_slots,
      memory_total: Map.get(snapshot, :memory_total),
      memory_available: Map.get(snapshot, :memory_available),
      memory_reserve: memory_reserve(snapshot),
      memory_per_worker: memory_per_worker,
      memory_slots: memory_slots,
      workers: workers,
      beam_schedulers: schedulers,
      worker_override: not is_nil(worker_override),
      scheduler_override: not is_nil(scheduler_override)
    }
  end

  def allocate(snapshot, class, items, _opts),
    do: raise(ArgumentError, "invalid resource budget: #{inspect({snapshot, class, items})}")

  defp override_or(nil, default), do: default
  defp override_or(value, _default), do: positive(value)

  defp positive(value) when is_integer(value) and value > 0, do: value

  defp positive(value),
    do: raise(ArgumentError, "resource value must be positive: #{inspect(value)}")

  defp load_floor(nil), do: 0
  defp load_floor(value) when is_number(value) and value >= 0, do: floor(value)
  defp load_floor(_invalid), do: 0

  defp memory_slots(snapshot, estimate) do
    case {Map.get(snapshot, :memory_total), Map.get(snapshot, :memory_available)} do
      {total, available}
      when is_integer(total) and total > 0 and is_integer(available) and available >= 0 ->
        available
        |> Kernel.-(max(2 * @gib, div(total, 10)))
        |> max(0)
        |> div(estimate)
        |> max(1)

      _unknown ->
        nil
    end
  end

  defp memory_reserve(snapshot) do
    case Map.get(snapshot, :memory_total) do
      total when is_integer(total) and total > 0 -> max(2 * @gib, div(total, 10))
      _unknown -> nil
    end
  end

  defp min_optional(value, nil), do: value
  defp min_optional(value, limit), do: min(value, limit)

  defp ceil_div(left, right), do: div(left + right - 1, right)

  defp read_load do
    with {:ok, bytes} <- File.read("/proc/loadavg"),
         [value | _rest] <- String.split(bytes),
         {load, ""} <- Float.parse(value) do
      %{load_one: load}
    else
      _unavailable -> %{load_one: nil}
    end
  end

  defp read_memory do
    with {:ok, bytes} <- File.read("/proc/meminfo") do
      values =
        bytes
        |> String.split("\n", trim: true)
        |> Enum.reduce(%{}, fn line, acc ->
          case Regex.run(~r/^(MemTotal|MemAvailable):\s+(\d+)\s+kB$/, line) do
            [_, key, value] -> Map.put(acc, key, String.to_integer(value) * 1024)
            _other -> acc
          end
        end)

      %{
        memory_total: Map.get(values, "MemTotal"),
        memory_available: Map.get(values, "MemAvailable")
      }
    else
      _unavailable -> %{memory_total: nil, memory_available: nil}
    end
  end
end
