defmodule MixWorkspaceOpsBootstrap do
  @moduledoc false

  @schema_header "mix_workspace_ops.overlay/v1"
  @overlay_env "MIX_WORKSPACE_OPS_OVERLAY"
  @publish_tasks MapSet.new(["hex.build", "hex.publish", "deps.publish_preflight"])

  def dep(app, requirement, _project_root, extra_opts \\ []) when is_atom(app) do
    case source(Atom.to_string(app)) do
      nil ->
        dependency_tuple(app, requirement, extra_opts)

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

  def active?(_project_root \\ nil), do: not is_nil(overlay_path())

  def source(_project_root, app), do: source(to_string(app))

  defp source(app) do
    case overlay_path() do
      nil -> nil
      path -> path |> parse_overlay!() |> Map.get(app)
    end
  end

  defp dependency_tuple(app, requirement, []), do: {app, requirement}
  defp dependency_tuple(app, requirement, opts), do: {app, requirement, opts}

  defp overlay_path do
    case System.get_env(@overlay_env) do
      nil -> nil
      "" -> nil
      path -> validate_overlay_path!(path)
    end
  end

  defp validate_overlay_path!(path) do
    unless Path.type(path) == :absolute do
      raise "#{@overlay_env} must contain an absolute path"
    end

    unless File.regular?(path) do
      raise "#{@overlay_env} points to a missing overlay: #{path}"
    end

    if Enum.any?(System.argv(), &MapSet.member?(@publish_tasks, &1)) do
      raise "a non-Hex Mix Workspace Ops overlay is active; rerun publication without #{@overlay_env}"
    end

    path
  end

  defp parse_overlay!(path) do
    case path |> File.read!() |> String.split("\n", trim: true) do
      [@schema_header, "registry_digest\t" <> _registry_digest,
       "graph_digest\t" <> _graph_digest, "target\t" <> _target, "mode\t" <> mode | rows]
      when mode in ["local", "git"] ->
        parse_rows!(rows)

      _lines ->
        raise "invalid Mix Workspace Ops overlay at #{path}"
    end
  end

  defp parse_rows!(rows) do
    Enum.reduce(rows, %{}, fn row, sources ->
      {app, source} = parse_row!(row)

      if Map.has_key?(sources, app) do
        raise "duplicate Mix Workspace Ops source for #{app}"
      end

      Map.put(sources, app, source)
    end)
  end

  defp parse_row!(row) do
    case String.split(row, "\t") do
      [app, "path", path, revision] ->
        unless Path.type(path) == :absolute and File.regular?(Path.join(path, "mix.exs")) do
          raise "local Mix dependency #{app} has no absolute Mix project at #{path}"
        end

        {app, %{kind: :path, path: path, revision: revision}}

      [app, "git", url, revision, subdir] ->
        {app, %{kind: :git, url: url, revision: revision, subdir: subdir}}

      _parts ->
        raise "invalid Mix Workspace Ops overlay row: #{inspect(row)}"
    end
  end
end
