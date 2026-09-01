defmodule MixWorkspaceOps.Selection do
  @moduledoc "Normalized project selection, including conservative affected scope."

  alias MixWorkspaceOps.{DependencyIndex, Impact, Registry}

  @spec affected(Registry.t(), DependencyIndex.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def affected(registry, index, target) do
    with {:ok, impact} <- Impact.analyze(registry, index, target) do
      base = index.selected_projects

      if index.complete do
        {:ok,
         %{
           kind: :affected,
           target: impact.target,
           base_projects: base,
           projects: impact.selected_affected_projects,
           impact_complete: true,
           fallback_to_full_scope: false,
           fallback_reason: nil,
           coverage: impact.coverage,
           impact: impact
         }}
      else
        {:ok,
         %{
           kind: :affected,
           target: impact.target,
           base_projects: base,
           projects: base,
           impact_complete: false,
           fallback_to_full_scope: true,
           fallback_reason: :dependency_index_incomplete,
           coverage: impact.coverage,
           impact: impact
         }}
      end
    end
  end
end
