defmodule MixWorkspaceOps.Release.Plan do
  @moduledoc "Portable, self-digested semantic plans for a catalogued release chain."

  alias MixWorkspaceOps.{Registry, Report}
  alias MixWorkspaceOps.Registry.ReleaseChain

  @schema "mix_workspace_ops.release_plan/v1"

  @type t :: map()

  @doc "Builds the catalog-only release plan for `package` and its prerequisites."
  @spec build(Registry.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def build(%Registry{} = registry, package) when is_binary(package) do
    with {:ok, prerequisites} <- ReleaseChain.derive(registry),
         {:ok, order} <- ReleaseChain.order(registry, package),
         {:ok, units} <- units(registry, order) do
      base = %{
        schema: @schema,
        registry: %{schema: registry.schema, digest: registry.digest},
        package: package,
        prerequisites: prerequisites,
        order: order,
        units: units
      }

      {:ok, Map.put(base, :digest, digest(base))}
    end
  end

  def build(%Registry{}, _package), do: {:error, :invalid_release_package}

  @doc "Returns the digest of a release plan without trusting a stored digest field."
  @spec digest(map()) :: String.t()
  def digest(plan) when is_map(plan) do
    plan
    |> Map.drop([:digest, "digest"])
    |> Report.encode()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp units(registry, order) do
    Enum.reduce_while(order, {:ok, []}, fn package, {:ok, acc} ->
      case Registry.resolve_dependency(registry, package) do
        {:ok, project} ->
          repository = Registry.repository!(registry, project.repository)

          unit = %{
            package: package,
            project: %{id: project.id, path: project.path},
            repository: %{
              id: repository.id,
              github: repository.github,
              default_branch: repository.default_branch
            }
          }

          {:cont, {:ok, [unit | acc]}}

        {:known_unselected, project_ids} ->
          {:halt, {:error, {:unselected_release_package, package, project_ids}}}

        {:error, reason} ->
          {:halt, {:error, {:release_package, package, reason}}}

        :unknown ->
          {:halt, {:error, {:release_package, package, {:unprovided_application, package}}}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end
end
