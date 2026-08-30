defmodule MixWorkspaceOps.Drift do
  @moduledoc "Fail-closed reconciliation of live checkout evidence with catalog and ledger."

  alias MixWorkspaceOps.{Binding, Discovery, Git, OperatorLedger, Registry}

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

    {classified, observed_ids, consumed_ignores} =
      Enum.reduce(inventory.entries, {[], MapSet.new(), MapSet.new()}, fn entry,
                                                                          {rows, ids, ignores} ->
        {classified, repository, ignored_path} =
          classify(entry, catalog, valid_bindings, ledger.ignores)

        ids = if repository, do: MapSet.put(ids, repository), else: ids
        ignores = if ignored_path, do: MapSet.put(ignores, ignored_path), else: ignores
        {[classified | rows], ids, ignores}
      end)

    bound_ids = valid_bindings |> Map.values() |> MapSet.new(& &1.repository)
    observed_ids = MapSet.union(observed_ids, bound_ids)
    stale_ignore_rows = stale_ignores(ledger.ignores, consumed_ignores)

    entries =
      (classified ++ binding_rows ++ stale_ignore_rows)
      |> Enum.sort_by(&{&1["path"], &1["status"], &1["source"] || "checkout"})

    counts = Enum.frequencies_by(entries, & &1["status"])
    blocking = Enum.filter(entries, &(&1["status"] in ["discovered", "failed"]))

    %{
      schema: @schema,
      observed_on: inventory.observed_on,
      registry: %{schema: registry.schema, digest: registry.digest},
      ledger: %{path: ledger.path, digest: ledger.digest},
      checkout_root: inventory.checkout_root,
      healthy: blocking == [],
      summary: %{
        total: length(entries),
        discovered: Map.get(counts, "discovered", 0),
        not_a_repository: Map.get(counts, "not_a_repository", 0),
        ignored: Map.get(counts, "ignored", 0),
        dispositioned: Map.get(counts, "dispositioned", 0),
        failed: Map.get(counts, "failed", 0),
        absent_catalog: map_size(registry.repositories) - MapSet.size(observed_ids)
      },
      entries: entries,
      absent_catalog: absent_catalog(registry, observed_ids),
      unexplained: Enum.map(blocking, & &1["path"])
    }
  end

  defp classify(%{"status" => "discovered"} = entry, catalog, bindings, ignores) do
    path = entry["path"]

    case Map.get(bindings, path) do
      %{repository: repository} ->
        {dispositioned(entry, repository, "ledger_binding"), repository, nil}

      nil ->
        classify_identity(entry, catalog, Map.get(ignores, path))
    end
  end

  defp classify(entry, _catalog, _bindings, _ignores), do: {entry, nil, nil}

  defp classify_identity(entry, catalog, ignore) do
    matches =
      entry["identities"]
      |> Enum.flat_map(&Map.get(catalog, String.downcase(&1), []))
      |> Enum.uniq()
      |> Enum.sort()

    case matches do
      [repository] ->
        {dispositioned(entry, repository, "catalog_identity"), repository, nil}

      [] ->
        classify_ignore(entry, ignore)

      several ->
        {failure(entry, "ambiguous_catalog_identity", several), nil, nil}
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
        :ok -> {Map.put(valid, binding.path, binding), failures}
        {:error, reason} -> {valid, [binding_failure(binding, reason) | failures]}
      end
    end)
  end

  defp validate_binding(binding, registry) do
    repository = Map.fetch!(registry.repositories, binding.repository)

    with true <- File.dir?(binding.path) || {:error, :absent_binding_path},
         {:ok, root} <- Git.root(binding.path),
         true <- root == binding.path || {:error, {:binding_not_git_root, root}},
         {:ok, actual} <- Git.remote_urls(binding.path),
         true <-
           actual == binding.remotes ||
             {:error, {:binding_remote_drift, binding.remotes, actual}} do
      binding_identity(repository.github, actual)
    end
  end

  defp binding_identity(expected, remotes) do
    identities = normalized_identities(remotes)
    expected = String.downcase(expected)

    case Enum.map(identities, &String.downcase/1) do
      [] -> :ok
      [^expected] -> :ok
      _other -> {:error, {:binding_wrong_identity, expected, identities}}
    end
  end

  defp normalized_identities(remotes) do
    remotes
    |> Enum.flat_map(fn remote ->
      case Binding.normalize_github(remote) do
        {:ok, identity} -> [identity]
        {:error, _reason} -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
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
