defmodule MixWorkspaceOps.Release.Chain do
  @moduledoc "Executes a catalogued release plan as resumable per-package transactions."

  alias MixWorkspaceOps.{Registry, Release.Plan}
  alias MixWorkspaceOps.Release.{LocalAdapter, Transaction}

  @schema "mix_workspace_ops.release_chain_result/v1"

  @spec run(Registry.t(), map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(%Registry{} = registry, semantic_plan, descriptor, opts \\ []) do
    adapter = Keyword.get(opts, :adapter, LocalAdapter)
    state_root = Keyword.get(opts, :state_root) || Transaction.default_state_root()
    resume_id = Keyword.get(opts, :resume)
    chain_id = resume_id || chain_id(semantic_plan, descriptor)

    with {:ok, canonical_plan} <- Plan.build(registry, field(semantic_plan, :package)),
         :ok <- validate(registry, semantic_plan, canonical_plan, descriptor),
         {:ok, units} <- execution_units(registry, semantic_plan, descriptor, opts) do
      execute(units, adapter, descriptor, semantic_plan, state_root, chain_id,
        resume?: not is_nil(resume_id)
      )
    end
  end

  defp validate(registry, plan, canonical_plan, descriptor) do
    order = field(plan, :order)
    digest = field(plan, :digest)
    canonical_digest = field(canonical_plan, :digest)
    packages = descriptor.packages |> Map.keys() |> Enum.sort()

    cond do
      digest != Plan.digest(plan) ->
        {:error, :release_plan_digest_invalid}

      digest != canonical_digest ->
        {:error, :release_plan_registry_drift}

      descriptor.release_plan_digest != digest ->
        {:error, :release_descriptor_plan_drift}

      descriptor.registry_digest != registry.digest ->
        {:error, :release_descriptor_registry_drift}

      packages != Enum.sort(order) ->
        {:error, {:release_descriptor_packages, Enum.sort(order), packages}}

      true ->
        :ok
    end
  end

  defp execution_units(registry, semantic_plan, descriptor, opts) do
    adapter_options = Keyword.get(opts, :adapter_options, %{})

    semantic_plan
    |> field(:units)
    |> Enum.reduce_while({:ok, []}, fn unit, {:ok, acc} ->
      package = field(unit, :package)
      project = field(unit, :project)
      repository = field(unit, :repository)
      repository_id = field(repository, :id)

      case Registry.checkout(registry, repository_id) do
        {:bound, root} ->
          package_descriptor = Map.fetch!(descriptor.packages, package)

          plan = %{
            package: package,
            version: package_descriptor.version,
            tag: package_descriptor.tag,
            repository: root,
            project_path: field(project, :path),
            default_branch: field(repository, :default_branch),
            gates: package_descriptor.gates,
            publisher_prefix: descriptor.publisher_prefix,
            prepared_artifact: package_descriptor.prepared_artifact,
            registry: registry,
            release_prerequisites: field(semantic_plan, :prerequisites),
            adapter_options: adapter_options
          }

          plan = maybe_put(plan, :registry_lookup, Keyword.get(opts, :registry_lookup))
          {:cont, {:ok, [{package, plan} | acc]}}

        {:absent, expected} ->
          {:halt, {:error, {:absent_release_checkout, package, repository_id, expected}}}

        :unknown ->
          {:halt, {:error, {:unbound_release_repository, package, repository_id}}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp execute(units, adapter, descriptor, semantic_plan, state_root, chain_id, opts) do
    units
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {{package, plan}, index}, {:ok, completed} ->
      transaction_id = unit_transaction_id(chain_id, index)
      resume? = opts[:resume?] and transaction_exists?(state_root, transaction_id)

      transaction_opts = [
        state_root: state_root,
        transaction_id: transaction_id,
        resume: resume?,
        descriptor: %{chain: descriptor, package: package},
        release_plan_digest: field(semantic_plan, :digest),
        registry_digest: descriptor.registry_digest
      ]

      case Transaction.run(plan, adapter, transaction_opts) do
        {:ok, result} ->
          row = %{package: package, transaction_id: transaction_id, receipt: result.receipt}
          {:cont, {:ok, [row | completed]}}

        {:error, reason} ->
          report = result(chain_id, semantic_plan, Enum.reverse(completed), package)
          {:halt, {:error, {:release_chain, package, reason, report}}}
      end
    end)
    |> case do
      {:ok, completed} ->
        completed = Enum.reverse(completed)
        {:ok, result(chain_id, semantic_plan, completed, nil)}

      error ->
        error
    end
  end

  defp result(chain_id, semantic_plan, completed, blocked_package) do
    %{
      schema: @schema,
      transaction_id: chain_id,
      package: field(semantic_plan, :package),
      order: field(semantic_plan, :order),
      completed_packages: Enum.map(completed, & &1.package),
      transactions: completed,
      blocked_package: blocked_package
    }
  end

  defp chain_id(plan, descriptor) do
    package = field(plan, :package)
    version = descriptor.packages |> Map.fetch!(package) |> Map.fetch!(:version)
    timestamp = System.system_time(:microsecond)
    nonce = :crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)
    "#{package}-#{version}-#{timestamp}-#{nonce}"
  end

  defp unit_transaction_id(chain_id, index), do: "#{chain_id}.#{index}"

  defp transaction_exists?(state_root, transaction_id) do
    state_root
    |> Path.expand()
    |> Path.join("releases")
    |> Path.join(transaction_id)
    |> Path.join("events.jsonl")
    |> File.regular?()
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end