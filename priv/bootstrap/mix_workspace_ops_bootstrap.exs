defmodule MixWorkspaceOpsBootstrap do
  @moduledoc false

  @schema_header "mix_workspace_ops\t1"
  @relative_overlay ".mix_workspace_ops/sources.tsv"
  @publish_tasks MapSet.new(["hex.build", "hex.publish", "deps.publish_preflight"])

  def dep(app, requirement, project_root, extra_opts \\ []) when is_atom(app) do
    case source(project_root, Atom.to_string(app)) do
      nil -> dependency_tuple(app, requirement, extra_opts)
      %{kind: :path, path: path} ->
        dependency_tuple(app, requirement, Keyword.merge(extra_opts, path: path, override: true))

      %{kind: :git, url: url, revision: revision, subdir: subdir} ->
        dependency_tuple(
          app,
          requirement,
          Keyword.merge(extra_opts, git: url, ref: revision, subdir: subdir, override: true)
        )
    end
  end

  def active?(project_root), do: not is_nil(find_overlay(project_root))

  def source(project_root, app) do
    case find_overlay(project_root) do
      nil -> nil
      path -> path |> parse_overlay!() |> Map.get(app)
    end
  end

  defp dependency_tuple(app, requirement, []), do: {app, requirement}
  defp dependency_tuple(app, requirement, opts), do: {app, requirement, opts}

  defp find_overlay(project_root) do
    project_root
    |> Path.expand()
    |> ancestors()
    |> Enum.map(&Path.join(&1, @relative_overlay))
    |> Enum.find(&File.regular?/1)
    |> reject_publish_mode!()
  end

  defp ancestors(path), do: ancestors(path, [])

  defp ancestors(path, acc) do
    parent = Path.dirname(path)

    if parent == path do
      Enum.reverse([path | acc])
    else
      ancestors(parent, [path | acc])
    end
  end

  defp reject_publish_mode!(nil), do: nil

  defp reject_publish_mode!(overlay_path) do
    if Enum.any?(System.argv(), &MapSet.member?(@publish_tasks, &1)) do
      raise "non-Hex Mix Workspace Ops overlay is active at #{overlay_path}; deactivate it before package build or publication"
    end

    overlay_path
  end

  defp parse_overlay!(path) do
    case path |> File.read!() |> String.split("\n", trim: true) do
      [@schema_header, "catalog_digest\t" <> _digest, "target\t" <> _target,
       "mode\t" <> _mode | rows] ->
        Map.new(rows, &parse_row!/1)

      _ ->
        raise "invalid Mix Workspace Ops overlay at #{path}"
    end
  end

  defp parse_row!(row) do
    case String.split(row, "\t") do
      [app, "path", path, revision] ->
        unless File.regular?(Path.join(path, "mix.exs")) do
          raise "local Mix dependency #{app} has no mix.exs at #{path}"
        end

        {app, %{kind: :path, path: path, revision: revision}}

      [app, "git", url, revision, subdir] ->
        {app, %{kind: :git, url: url, revision: revision, subdir: subdir}}

      _ ->
        raise "invalid Mix Workspace Ops overlay row: #{inspect(row)}"
    end
  end
end
