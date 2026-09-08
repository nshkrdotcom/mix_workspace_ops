defmodule MixWorkspaceOps.RunReportTest do
  use ExUnit.Case, async: true

  alias MixWorkspaceOps.{Report, RunReport}

  test "persists one private detailed report and keeps the summary bounded" do
    state_root =
      Path.join(System.tmp_dir!(), "mwo-run-report-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(state_root) end)

    assert {:ok, root} = RunReport.prepare(state_root)
    assert File.stat!(root).mode |> Bitwise.band(0o777) == 0o700
    assert [%{path: ^root, active: true, complete: false}] = RunReport.list(state_root)

    affected = Enum.map(1..1_000, &"project-#{&1}")
    logs = Enum.map(affected, &RunReport.unit_log(root, &1))

    report = %{
      schema: "mix_workspace_ops.run/v1",
      status: :failed,
      plan: %{command: %{executable: "mix", args: ["compile"]}},
      binding: %{
        plan_digest: String.duplicate("a", 64),
        lifecycle: :compile,
        started_at: 100,
        finished_at: 125,
        phases: [%{name: :execute, duration_ms: 10}],
        resource_budget: %{workers: 22, beam_schedulers: 1}
      },
      results: Enum.map(affected, &%{id: &1, status: :blocked}),
      causes: [
        %{
          id: String.duplicate("b", 64),
          kind: :dependency_context,
          affected_units: affected,
          affected_contexts: Enum.map(1..100, &"context-#{&1}"),
          log_paths: logs,
          reason: String.duplicate("r", 2_000),
          diagnostic: [String.duplicate("d", 2_000)]
        }
      ]
    }

    assert {:ok, persisted} = RunReport.persist(report, root)
    assert File.stat!(persisted.detail_path).mode |> Bitwise.band(0o777) == 0o600
    assert [%{path: ^root, active: false, complete: true}] = RunReport.list(state_root)

    assert File.read!(persisted.detail_path) |> :json.decode() |> Map.fetch!("causes") |> length() ==
             1

    summary = RunReport.summary(persisted)
    assert summary.schema == "mix_workspace_ops.run_summary/v1"

    assert summary.counts == %{
             absent: 0,
             blocked: 1_000,
             failed: 0,
             not_run: 0,
             passed: 0,
             total: 1_000
           }

    assert [cause] = summary.causes
    assert cause.affected_count == 1_000
    assert length(cause.affected_units) == 8
    assert cause.context_count == 100
    assert length(cause.affected_contexts) == 8
    assert cause.log_count == 1_000
    assert length(cause.log_paths) == 8
    assert byte_size(Report.encode(summary)) < 10_000

    now = System.system_time(:second) + 1
    assert {:ok, [%{path: ^root}]} = RunReport.gc(state_root, 0, now: now, dry_run: true)
    assert File.dir?(root)
    assert {:ok, [%{path: ^root}]} = RunReport.gc(state_root, 0, now: now)
    refute File.exists?(root)
  end

  test "an explicit report directory cannot overwrite earlier evidence" do
    state_root =
      Path.join(System.tmp_dir!(), "mwo-run-report-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(state_root) end)
    report_root = Path.join(state_root, "chosen-report")

    assert {:ok, ^report_root} = RunReport.prepare(state_root, report_root: report_root)
    assert RunReport.prepare(state_root, report_root: report_root) == {:error, :eexist}
  end

  test "an explicit report directory does not change its parent permissions" do
    state_root =
      Path.join(System.tmp_dir!(), "mwo-run-report-#{System.unique_integer([:positive])}")

    parent = Path.join(state_root, "operator-owned")
    report_root = Path.join(parent, "chosen-report")
    File.mkdir_p!(parent)
    File.chmod!(parent, 0o755)
    on_exit(fn -> File.rm_rf!(state_root) end)

    assert {:ok, ^report_root} = RunReport.prepare(state_root, report_root: report_root)
    assert File.stat!(parent).mode |> Bitwise.band(0o777) == 0o755
    assert File.stat!(report_root).mode |> Bitwise.band(0o777) == 0o700
  end
end
