defmodule MixWorkspaceOps.ResourceBudgetTest do
  use ExUnit.Case, async: true

  alias MixWorkspaceOps.ResourceBudget

  @gib 1024 * 1024 * 1024

  test "uses 22 slots on the low-load 24-scheduler acceptance host shape" do
    snapshot = %{
      logical_schedulers: 24,
      load_one: 0.08,
      memory_total: 160 * @gib,
      memory_available: 155 * @gib
    }

    assert %{cpu_headroom: 2, external_load: 0, cpu_slots: 22, workers: 22} =
             ResourceBudget.allocate(snapshot, :cpu, 369)
  end

  test "small CPU fanout gives each child the remaining schedulers" do
    snapshot = %{logical_schedulers: 24, load_one: 0.0}

    assert %{workers: 6, beam_schedulers: 3} =
             ResourceBudget.allocate(snapshot, :cpu, 6)
  end

  test "transport work uses one scheduler per worker" do
    snapshot = %{logical_schedulers: 24, load_one: 0.0}

    assert %{workers: 22, beam_schedulers: 1} =
             ResourceBudget.allocate(snapshot, :transport, 100)
  end

  test "initial external load and constrained memory reserve capacity" do
    snapshot = %{
      logical_schedulers: 16,
      load_one: 3.9,
      memory_total: 8 * @gib,
      memory_available: 3 * @gib
    }

    assert %{cpu_slots: 11, memory_slots: 1, workers: 1} =
             ResourceBudget.allocate(snapshot, :cpu, 20)
  end

  test "explicit expert overrides remain exact" do
    snapshot = %{logical_schedulers: 24, load_one: 0.0}

    assert %{workers: 7, beam_schedulers: 4, worker_override: true, scheduler_override: true} =
             ResourceBudget.allocate(snapshot, :cpu, 100,
               max_concurrency: 7,
               beam_schedulers: 4
             )
  end

  test "the live snapshot is usable without Linux-specific data" do
    assert %{logical_schedulers: schedulers} = snapshot = ResourceBudget.snapshot()
    assert schedulers > 0
    assert %{workers: workers} = ResourceBudget.allocate(snapshot, :cpu, 2)
    assert workers in 1..2
  end
end
