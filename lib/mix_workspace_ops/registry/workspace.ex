defmodule MixWorkspaceOps.Registry.Workspace do
  @moduledoc """
  Membership of a repository's Mix umbrella or Blitz workspace.

  Membership has one authority: derivation from the project metadata the catalog
  already carries. The catalog records exceptions and nothing else, so a
  relationship is never stated twice and the two statements can never disagree.

  The derived rule is the same for both workspace kinds:

    * the project the workspace is rooted at is the container, not a member — an
      umbrella root never builds itself, and a Blitz root is a member only where
      its own project globs name it;
    * a `generated` project is build output, so it is never a member and cannot
      be made one;
    * every other project in the repository is a member.

  `include_project_ids` adds a root that does belong to its own workspace.
  `exclude_project_ids` removes a project derivation wrongly includes. Both are
  exceptions and both are expected to stay rare.
  """

  alias MixWorkspaceOps.Registry

  @container_kinds ~w(workspace_root)
  @never_member_kinds ~w(generated)

  @doc "The project kinds derivation never treats as workspace members."
  @spec never_member_kinds() :: [String.t()]
  def never_member_kinds, do: @never_member_kinds

  @doc """
  The members of a repository's workspace, sorted by project id.

  Returns `{:error, {:not_a_workspace, repository_id}}` where the repository
  declares no workspace, so a caller cannot mistake "no workspace" for "an empty
  one".
  """
  @spec members(Registry.t(), Registry.repository() | String.t()) ::
          {:ok, [Registry.project()]} | {:error, term()}
  def members(registry, repository_id) when is_binary(repository_id) do
    members(registry, Registry.repository!(registry, repository_id))
  end

  def members(_registry, %{workspace: nil} = repository) do
    {:error, {:not_a_workspace, repository.id}}
  end

  def members(_registry, repository), do: {:ok, derive(repository)}

  @doc "Every repository declaring a workspace, with its derived members."
  @spec workspaces(Registry.t()) :: [{Registry.repository(), [Registry.project()]}]
  def workspaces(%Registry{} = registry) do
    registry
    |> Registry.selected_repositories()
    |> Enum.filter(& &1.workspace)
    |> Enum.map(&{&1, derive(&1)})
  end

  defp derive(repository) do
    included = MapSet.new(repository.workspace.include_project_ids)
    excluded = MapSet.new(repository.workspace.exclude_project_ids)

    repository.projects
    |> Enum.filter(&member?(&1, included, excluded))
    |> Enum.sort_by(& &1.id)
  end

  defp member?(project, included, excluded) do
    cond do
      project.kind in @never_member_kinds -> false
      MapSet.member?(excluded, project.id) -> false
      MapSet.member?(included, project.id) -> true
      project.kind in @container_kinds -> false
      true -> true
    end
  end
end
