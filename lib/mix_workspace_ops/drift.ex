defmodule MixWorkspaceOps.Drift do
  @moduledoc "Severity-aware reconciliation of live checkout evidence with registry and operator ledger."

  alias MixWorkspaceOps.{Discovery, Git, OperatorLedger, Registry, RemoteIdentity}

  @schema "mix_workspace_ops.registry_drift/v1"

  @spec run(Registry.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, {:registry_drift, map()}} | {:error, term()}
  def run(%Registry{} = registry, checkout_root, opts \\ []) do
    ledger_path = Keyword.get(opts, :ledger)
    discovery_opts = Keyword.take(opts, [:clock, :max_concurrency, :mix_inspector, :timeout])

    with {:ok, ledger} <- OperatorLedger.load(ledger_path, registry),
         {:ok, inventory} <- Discovery.inventory(checkout_root, discovery_opts) do
      report = reconcile(registry, ledger, inventory)

      if report.healthy,
        do: {:ok, report},
        else: {:error, {:registry_drift, report}}
    end
  end

  defp reconcile(registry, ledger, inventory) do
    catalog = catalog_identities(registry)
    {valid_bindings, binding_rows} = validate_bindings(ledger, registry)

    binding_failures =
      binding_rows
      |> Enum.filter(&(&1["status"] == "failed"))
      |> Map.new(&{&1["path"], &1})

    inventory_paths = MapSet.new(inventory.entries, & &1["path"])

    {classified, observed_ids, consumed_ignores} =
      Enum.reduce(inventory.entries, {[], MapSet.new(), MapSet.new()}, fn entry,
                                                                          {rows, ids, ignores} ->
        {classified, repository, ignored_path} =
          classify(entry, catalog, valid_bindings, binding_failures, ledger.ignores)

        ids = if repository, do: MapSet.put(ids, repository), else: ids
        ignores = if ignored_path, do: MapSet.put(ignores, ignored_path), else: ignores
        {[classified | rows], ids, ignores}
      end)

    bound_ids = valid_bindings |> Map.values() |> MapSet.new(& &1.repository)
    observed_ids = MapSet.union(observed_ids, bound_ids)
    stale_ignore_rows = stale_ignores(ledger.ignores, consumed_ignores)

    entries =
      (classified ++
         Enum.reject(binding_rows, &MapSet.member?(inventory_paths, &1["path"])) ++
         stale_ignore_rows)
      |> Enum.sort_by(&{&1["path"], &1["status"], &1["source"] || "checkout"})

    entries = Enum.map(entries, &put_severity/1)
    counts = Enum.frequencies_by(entries, & &1["status"])
    errors = Enum.filter(entries, &(&1["severity"] == "error"))
    warnings = Enum.filter(entries, &(&1["severity"] == "warning"))
    info = Enum.filter(entries, &(&1["severity"] == "info"))

    %{
      schema: @schema,
      observed_on: inventory.observed_on,
      registry: %{schema: registry.schema, digest: registry.digest},
      ledger: %{path: ledger.path, digest: ledger.digest},
      checkout_root: inventory.checkout_root,
      healthy: errors == [],
      errors: errors,
      warnings: warnings,
      info: info,
      summary: %{
        total: length(entries),
        discovered: Map.get(counts, "discovered", 0),
        not_a_repository: Map.get(counts, "not_a_repository", 0),
        ignored: Map.get(counts, "ignored", 0),
        dispositioned: Map.get(counts, "dispositioned", 0),
        failed: Map.get(counts, "failed", 0),
        errors: length(errors),
        warnings: length(warnings),
        info: length(info),
        absent_catalog: map_size(registry.repositories) - MapSet.size(observed_ids)
      },
      entries: entries,
      absent_catalog: absent_catalog(registry, observed_ids),
      unexplained: Enum.map(errors ++ warnings, & &1["path"]) |> Enum.uniq() |> Enum.sort()
    }
  end

  defp classify(entry, catalog, bindings, binding_failures, ignores) do
    path = entry["path"]

    case Map.get(binding_failures, path) do
      nil -> classify_checkout(entry, catalog, bindings, ignores)
      failure -> {failure, nil, nil}
    end
  end

  defp classify_checkout(%{"status" => "discovered"} = entry, catalog, bindings, ignores) do
    case Map.get(bindings, entry["path"]) do
      %{repository: repository} ->
        {dispositioned(entry, repository, "ledger_binding"), repository, nil}

      nil ->
        classify_identity(entry, catalog, Map.get(ignores, entry["path"]))
    end
  end

  defp classify_checkout(entry, _catalog, _bindings, ignores) do
    case Map.get(ignores, entry["path"]) do
      nil ->
        {entry, nil, nil}

      ignore ->
        evidence = %{
          expected_remotes: ignore.remotes,
          checkout_status: entry["status"],
          checkout_reason: entry["reason"]
        }

        {failure(entry, "stale_ignore_checkout", evidence), nil, ignore.path}
    end
  end

  defp classify_identity(entry, catalog, ignore) do
    matches =
      entry["identities"]
      |> Enum.flat_map(&Map.get(catalog, String.downcase(&1), []))
      |> Enum.uniq()
      |> Enum.sort()

    case matches do
      [repository] ->
        classify_catalog_identity(entry, repository, ignore)

      [] ->
        classify_ignore(entry, ignore)

      several ->
        {failure(entry, "ambiguous_catalog_identity", several), nil, nil}
    end
  end

  defp classify_catalog_identity(entry, repository, nil) do
    {dispositioned(entry, repository, "catalog_identity"), repository, nil}
  end

  defp classify_catalog_identity(entry, repository, ignore) do
    if entry["remotes"] == ignore.remotes do
      classified =
        entry
        |> dispositioned(repository, "catalog_identity")
        |> Map.put("ledger_ignore_reason", ignore.reason)

      {classified, repository, ignore.path}
    else
      classified =
        failure(entry, "stale_ignore_remotes", %{
          expected: ignore.remotes,
          actual: entry["remotes"]
        })

      {classified, repository, ignore.path}
    end
  end

  defp classify_ignore(entry, nil), do: {entry, nil, nil}

  defp classify_ignore(entry, ignore) do
    if entry["remotes"] == ignore.remotes do
      {
        entry
        |> Map.put("status", "ignored")
        |> Map.put("source", "operator_ledger")
        |> Map.put("reason", ignore.reason),
        nil,
        ignore.path
      }
    else
      {failure(entry, "stale_ignore_remotes", %{
         expected: ignore.remotes,
         actual: entry["remotes"]
       }), nil, ignore.path}
    end
  end

  defp dispositioned(entry, repository, source) do
    entry
    |> Map.put("status", "dispositioned")
    |> Map.put("source", source)
    |> Map.put("repository", repository)
  end

  defp catalog_identities(registry) do
    registry.repositories
    |> Map.values()
    |> Enum.group_by(&String.downcase(&1.github), & &1.id)
  end

  defp validate_bindings(ledger, registry) do
    Enum.reduce(ledger.bindings, {%{}, []}, fn {_repository, binding}, {valid, failures} ->
      case validate_binding(binding, registry) do
        :ok ->
          row = binding_success(binding)
          {Map.put(valid, binding.path, binding), [row | failures]}

        {:error, reason} ->
          {valid, [binding_failure(binding, reason) | failures]}
      end
    end)
  end

  defp validate_binding(binding, registry) do
    repository = Map.fetch!(registry.repositories, binding.repository)

    with true <- File.dir?(binding.path) || {:error, :absent_binding_path},
         {:ok, root} <- Git.root(binding.path),
         true <- root == binding.path || {:error, {:binding_not_git_root, root}},
         {:ok, common_dir} <- Git.common_dir(binding.path),
         true <-
           common_dir == Path.join(binding.path, ".git") ||
             {:error, {:binding_noncanonical_git_common_dir, common_dir}},
         {:ok, actual} <- Git.remote_urls(binding.path),
         true <-
           actual == binding.remotes ||
             {:error, {:binding_remote_drift, binding.remotes, actual}} do
      binding_identity(repository.github, actual)
    end
  end

  defp binding_identity(expected, remotes) do
    case RemoteIdentity.hosted_identities(remotes) do
      {:ok, identities} ->
        expected = String.downcase(expected)

        case Enum.map(identities, &String.downcase/1) do
          [] -> :ok
          [^expected] -> :ok
          _other -> {:error, {:binding_wrong_identity, expected, identities}}
        end

      {:error, reason} ->
        {:error, {:binding_remote_identity, reason}}
    end
  end

  defp binding_failure(binding, reason) do
    %{
      "path" => binding.path,
      "name" => Path.basename(binding.path),
      "status" => "failed",
      "source" => "ledger_binding",
      "repository" => binding.repository,
      "reason" => inspect(reason, limit: :infinity)
    }
  end

  defp binding_success(binding) do
    %{
      "path" => binding.path,
      "name" => Path.basename(binding.path),
      "status" => "dispositioned",
      "source" => "ledger_binding",
      "repository" => binding.repository,
      "remotes" => binding.remotes
    }
  end

  defp stale_ignores(ignores, consumed) do
    for {path, ignore} <- ignores,
        not MapSet.member?(consumed, path) do
      %{
        "path" => path,
        "name" => Path.basename(path),
        "status" => "failed",
        "source" => "ledger_ignore",
        "reason" => "stale_ignore_observation",
        "expected_remotes" => ignore.remotes
      }
    end
  end

  defp failure(entry, reason, evidence) do
    entry
    |> Map.put("status", "failed")
    |> Map.put("reason", reason)
    |> Map.put("evidence", evidence)
  end

  # Severity is intentionally independent of legacy discovery status. An
  # unexplained scratch checkout or stale ignore is a warning; contradictions
  # in an exact binding or ambiguous portfolio identity are errors.
  defp put_severity(%{"severity" => _severity} = entry), do: entry

  defp put_severity(%{"source" => "ledger_binding", "status" => "failed"} = entry),
    do: Map.put(entry, "severity", "error")

  defp put_severity(%{"reason" => "ambiguous_catalog_identity"} = entry),
    do: Map.put(entry, "severity", "error")

  defp put_severity(%{"status" => "failed"} = entry),
    do: Map.put(entry, "severity", "warning")

  defp put_severity(%{"status" => "discovered"} = entry),
    do: Map.put(entry, "severity", "warning")

  defp put_severity(%{"status" => "not_a_repository"} = entry),
    do: Map.put(entry, "severity", "info")

  defp put_severity(entry), do: Map.put(entry, "severity", "info")

  defp absent_catalog(registry, observed_ids) do
    registry.repositories
    |> Map.values()
    |> Enum.reject(&MapSet.member?(observed_ids, &1.id))
    |> Enum.sort_by(& &1.id)
    |> Enum.map(fn repository ->
      %{
        repository: repository.id,
        github: repository.github,
        disposition: repository.disposition,
        lifecycle: repository.lifecycle
      }
    end)
  end
end
