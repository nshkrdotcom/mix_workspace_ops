defmodule MixWorkspaceOps.DriftTest do
  use MixWorkspaceOps.WorkspaceCase, async: true

  alias MixWorkspaceOps.{Binding, CLI, Drift, Git, Registry}

  test "uncatalogued non-Elixir repository fails until its exact ledger observation explains it",
       context do
    %{root: root, registry: registry, beta: beta, catalog: catalog} = fixture(context)

    assert {:error, {:registry_drift, report}} =
             Drift.run(registry, root, clock: fn -> ~D[2032-04-05] end)

    assert report.observed_on == "2032-04-05"
    assert report.summary.discovered == 1
    assert report.summary.failed == 0
    assert status(report, "alpha") == "dispositioned"
    assert status(report, "beta") == "discovered"

    failed_output = Path.join(Path.dirname(root), "failed-drift.json")
    empty_ledger = write_ledger!(Path.dirname(root), [], [])

    assert {:error, {:registry_drift, failed_cli_report}} =
             CLI.dispatch([
               "registry",
               "drift",
               "--registry",
               catalog,
               "--checkout-root",
               root,
               "--ledger",
               empty_ledger,
               "--output",
               failed_output
             ])

    refute failed_cli_report.healthy
    assert File.read!(failed_output) == MixWorkspaceOps.Report.encode(failed_cli_report) <> "\n"

    ledger = write_ledger!(Path.dirname(root), [], [ignore(beta, "operator scratch")])

    assert {:ok, healthy} =
             Drift.run(registry, root, ledger: ledger, clock: fn -> ~D[2032-04-05] end)

    assert healthy.healthy
    assert healthy.summary.discovered == 0
    assert healthy.summary.failed == 0
    assert status(healthy, "beta") == "ignored"

    output = Path.join(Path.dirname(root), "drift.json")

    assert {:ok, cli_report} =
             CLI.dispatch([
               "registry",
               "drift",
               "--registry",
               catalog,
               "--checkout-root",
               root,
               "--ledger",
               ledger,
               "--output",
               output
             ])

    assert cli_report.healthy
    assert File.read!(output) == MixWorkspaceOps.Report.encode(cli_report) <> "\n"

    assert CLI.dispatch(["registry", "drift", "--observed-on", "2032-04-05"]) ==
             {:usage_error, "unknown option --observed-on"}
  end

  test "path reuse, changed origin and stale ignore rows fail closed", context do
    %{root: root, registry: registry, beta: beta} = fixture(context)
    missing = Path.join(root, "missing")

    ledger =
      write_ledger!(
        Path.dirname(root),
        [],
        [
          ignore(beta, "scratch"),
          %{"path" => missing, "remotes" => ["n:example-org/missing"], "reason" => "old"}
        ]
      )

    {_, 0} =
      System.cmd("git", ["remote", "set-url", "origin", "n:example-org/reused"],
        cd: beta,
        stderr_to_stdout: true
      )

    assert {:error, {:registry_drift, report}} = Drift.run(registry, root, ledger: ledger)
    assert report.summary.failed == 2

    reasons = for row <- report.entries, row["status"] == "failed", do: row["reason"]
    assert "stale_ignore_remotes" in reasons
    assert "stale_ignore_observation" in reasons
  end

  test "duplicate clone and linked worktree of one catalog identity are dispositioned",
       context do
    base = temporary_directory!(context)
    root = Path.join(base, "checkouts")
    File.mkdir_p!(root)
    alpha = initialize_repository!(Path.join(root, "alpha"), "[]", "example-org/alpha")
    worktree = Path.join(root, "alpha-worktree")

    {_, 0} =
      System.cmd("git", ["worktree", "add", "--quiet", "-b", "fixture-worktree", worktree],
        cd: alpha,
        stderr_to_stdout: true
      )

    catalog = write_catalog!(base, [catalog_repository("alpha")])
    {:ok, registry} = Registry.load(catalog)

    assert {:ok, report} = Drift.run(registry, root)
    assert report.summary.dispositioned == 2
    assert report.summary.discovered == 0
    assert Enum.sort(Enum.map(report.entries, & &1["kind"])) == ["clone", "worktree"]
  end

  test "HTTPS, standard SSH and SSH-alias origins normalize to the same identity" do
    assert {:ok, "example-org/alpha"} =
             Binding.normalize_github("https://github.com/example-org/alpha.git")

    assert {:ok, "example-org/alpha"} =
             Binding.normalize_github("git@github.com:example-org/alpha.git")

    assert {:ok, "example-org/alpha"} =
             Binding.normalize_github("n:example-org/alpha")
  end

  test "a broken Git checkout is failed rather than skipped", context do
    base = temporary_directory!(context)
    root = Path.join(base, "checkouts")
    File.mkdir_p!(root)
    initialize_repository!(Path.join(root, "alpha"), "[]", "example-org/alpha")
    broken = Path.join(root, "broken")
    File.mkdir_p!(broken)
    File.write!(Path.join(broken, ".git"), "not a gitdir\n")
    catalog = write_catalog!(base, [catalog_repository("alpha")])
    {:ok, registry} = Registry.load(catalog)

    assert {:error, {:registry_drift, report}} = Drift.run(registry, root)
    assert report.summary.failed == 1
    assert status(report, "broken") == "failed"
    assert Enum.any?(report.unexplained, &String.ends_with?(&1, "/broken"))
  end

  test "a local-only out-of-root binding contributes exact per-path evidence", context do
    base = temporary_directory!(context)
    root = Path.join(base, "checkouts")
    File.mkdir_p!(root)
    alpha = initialize_repository!(Path.join(base, "elsewhere/alpha"), "[]", "example-org/alpha")
    mirror = Path.join(base, "mirrors/alpha.git")
    File.mkdir_p!(Path.dirname(mirror))
    {_, 0} = System.cmd("git", ["clone", "--quiet", "--bare", alpha, mirror])
    {_, 0} = System.cmd("git", ["remote", "set-url", "origin", mirror], cd: alpha)

    catalog = write_catalog!(base, [catalog_repository("alpha")])
    {:ok, registry} = Registry.load(catalog)
    ledger = write_ledger!(base, [binding("alpha", alpha)], [])

    assert {:ok, report} = Drift.run(registry, root, ledger: ledger)

    assert report.summary == %{
             absent_catalog: 0,
             discovered: 0,
             dispositioned: 1,
             failed: 0,
             ignored: 0,
             not_a_repository: 0,
             total: 1
           }

    assert [%{"path" => ^alpha, "source" => "ledger_binding", "status" => "dispositioned"}] =
             report.entries
  end

  test "an exact binding cannot recast malformed hosted evidence as a local origin", context do
    base = temporary_directory!(context)
    root = Path.join(base, "checkouts")
    File.mkdir_p!(root)
    alpha = initialize_repository!(Path.join(base, "elsewhere/alpha"), "[]", "example-org/alpha")
    malformed = "https://github.com/example-org/alpha/extra"
    {_, 0} = System.cmd("git", ["remote", "set-url", "origin", malformed], cd: alpha)

    catalog = write_catalog!(base, [catalog_repository("alpha")])
    {:ok, registry} = Registry.load(catalog)
    ledger = write_ledger!(base, [binding("alpha", alpha)], [])

    assert {:error, {:binding_remote_identity, _reason}} =
             Registry.bind(registry, root, binding_file: ledger)

    assert {:error, {:registry_drift, report}} = Drift.run(registry, root, ledger: ledger)
    assert report.summary.failed == 1
    assert [%{"reason" => reason}] = report.entries
    assert reason =~ "binding_remote_identity"
  end

  test "a linked worktree cannot masquerade as a bindable canonical checkout", context do
    base = temporary_directory!(context)
    root = Path.join(base, "checkouts")
    File.mkdir_p!(root)
    source = initialize_repository!(Path.join(base, "source"), "[]", "example-org/alpha")
    worktree = Path.join(base, "elsewhere/alpha")
    File.mkdir_p!(Path.dirname(worktree))

    {_, 0} =
      System.cmd("git", ["worktree", "add", "--quiet", "-b", "binding-proof", worktree],
        cd: source
      )

    catalog = write_catalog!(base, [catalog_repository("alpha")])
    {:ok, registry} = Registry.load(catalog)
    ledger = write_ledger!(base, [binding("alpha", worktree)], [])

    assert {:error, {:registry_drift, report}} = Drift.run(registry, root, ledger: ledger)
    assert report.summary.failed == 1
    assert report.summary.absent_catalog == 1
    assert [%{"path" => ^worktree, "reason" => reason}] = report.entries
    assert reason =~ "binding_noncanonical_git_common_dir"
  end

  test "an ignore path reused by an ordinary directory yields one failed row", context do
    %{root: root, registry: registry} = fixture(context)
    ordinary = Path.join(root, "ordinary")
    File.mkdir_p!(ordinary)

    ledger =
      write_ledger!(
        Path.dirname(root),
        [],
        [%{"path" => ordinary, "remotes" => ["n:example-org/old"], "reason" => "old"}]
      )

    assert {:error, {:registry_drift, report}} = Drift.run(registry, root, ledger: ledger)

    assert [%{"status" => "failed", "reason" => "stale_ignore_checkout"}] =
             Enum.filter(report.entries, &(&1["path"] == ordinary))
  end

  defp fixture(context) do
    base = temporary_directory!(context)
    root = Path.join(base, "checkouts")
    File.mkdir_p!(root)
    initialize_repository!(Path.join(root, "alpha"), "[]", "example-org/alpha")
    beta = initialize_repository!(Path.join(root, "beta"), "[]", "example-org/beta")
    File.rm!(Path.join(beta, "mix.exs"))
    File.write!(Path.join(beta, "README.md"), "non-Elixir fixture\n")

    {_, 0} = System.cmd("git", ["add", "-A"], cd: beta, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["commit", "--quiet", "-m", "non-Elixir"], cd: beta)
    catalog = write_catalog!(base, [catalog_repository("alpha")])
    {:ok, registry} = Registry.load(catalog)
    %{root: root, registry: registry, beta: beta, catalog: catalog}
  end

  defp ignore(path, reason) do
    {:ok, remotes} = Git.remote_urls(path)
    %{"path" => path, "remotes" => remotes, "reason" => reason}
  end

  defp binding(repository, path) do
    {:ok, remotes} = Git.remote_urls(path)
    %{"repository" => repository, "path" => path, "remotes" => remotes}
  end

  defp write_ledger!(root, bindings, ignores) do
    path = Path.join(root, "operator_ledger_#{System.unique_integer([:positive])}.json")

    File.write!(
      path,
      :json.encode(%{
        "schema" => "mix_workspace_ops.operator_ledger/v1",
        "bindings" => bindings,
        "ignores" => ignores
      })
    )

    path
  end

  defp status(report, name) do
    report.entries |> Enum.find(&(&1["name"] == name)) |> Map.fetch!("status")
  end
end
