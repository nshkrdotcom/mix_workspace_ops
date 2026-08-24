defmodule MixWorkspaceOpsBootstrap do
  @moduledoc false

  @schema_header "mix_workspace_ops.overlay/v1"
  @overlay_env "MIX_WORKSPACE_OPS_OVERLAY"
  @lockfile_env "MIX_WORKSPACE_OPS_LOCKFILE"
  # The publish and quiet task lists, and the parser that reads them, are
  # duplicated from `MixWorkspaceOps.PublishMode` on purpose: this file is
  # loaded standalone by a `mix.exs` that has no access to Mix Workspace Ops.
  # A test holds the two implementations to the same table of argv cases so
  # they cannot drift.
  @publish_tasks ["hex.publish", "hex.build", "deps.publish_preflight"]
  @quiet_tasks ["run", "eval", "cmd", "app.start", "app.config", "escript.build",
                "deps.sources", "deps.publish_preflight"]
  @maximum_overlay_bytes 16 * 1024 * 1024

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

  def project_options(_project_root \\ nil) do
    case System.get_env(@lockfile_env) do
      nil -> []
      "" -> []
      path -> [lockfile: validate_lockfile!(path)]
    end
  end

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

    if File.stat!(path).size > @maximum_overlay_bytes do
      raise "#{@overlay_env} points to an oversized overlay"
    end

    if publish_mode?(System.argv()) do
      raise "a non-Hex Mix Workspace Ops overlay is active; rerun publication without #{@overlay_env}"
    end

    verify_content_address!(path)
  end

  defp validate_lockfile!(path) do
    unless Path.type(path) == :absolute do
      raise "#{@lockfile_env} must contain an absolute path"
    end

    unless File.regular?(path) do
      raise "#{@lockfile_env} points to a missing lockfile: #{path}"
    end

    path
  end

  defp parse_overlay!(path) do
    case path |> File.read!() |> String.split("\n", trim: true) do
      [@schema_header, "registry_digest\t" <> _registry_digest,
       "graph_digest\t" <> _graph_digest, "context_digest\t" <> _context_digest,
       "target\t" <> _target, "mode\t" <> mode,
       "target_head\t" <> _target_head,
       "target_source_digest\t" <> _target_source_digest,
       "lock_digest\t" <> _lock_digest,
       "toolchain\t" <> _toolchain | rows]
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
      [app, "path", path, revision, source_digest] ->
        unless Path.type(path) == :absolute and File.regular?(Path.join(path, "mix.exs")) do
          raise "local Mix dependency #{app} has no absolute Mix project at #{path}"
        end

        {app,
         %{kind: :path, path: path, revision: revision, source_digest: source_digest}}

      [app, "git", url, revision, subdir] ->
        {app, %{kind: :git, url: url, revision: revision, subdir: subdir}}

      _parts ->
        raise "invalid Mix Workspace Ops overlay row: #{inspect(row)}"
    end
  end

  # Task position only: `mix do compile, hex.publish` publishes and
  # `mix run --arg hex.publish` does not.
  def publish_mode?(argv) when is_list(argv) do
    argv |> task_tokens() |> Enum.any?(&(&1 in @publish_tasks))
  end

  def quiet_task?(argv) when is_list(argv) do
    argv |> task_tokens() |> Enum.any?(&(&1 in @quiet_tasks))
  end

  def task_tokens(argv) when is_list(argv) do
    argv
    |> Enum.flat_map(&split_separators/1)
    |> collect_tasks([], true)
    |> Enum.reverse()
  end

  defp split_separators(argument) do
    case String.split(argument, ",") do
      [single] -> [single]
      parts -> parts |> Enum.intersperse(",") |> Enum.reject(&(&1 == ""))
    end
  end

  defp collect_tasks([], acc, _task?), do: acc

  defp collect_tasks([token | rest], acc, _task?) when token in [",", "+"],
    do: collect_tasks(rest, acc, true)

  defp collect_tasks(["do" | rest], acc, true), do: collect_tasks(rest, acc, true)
  defp collect_tasks(["" | rest], acc, true), do: collect_tasks(rest, acc, true)
  defp collect_tasks([token | rest], acc, true), do: collect_tasks(rest, [token | acc], false)
  defp collect_tasks([_token | rest], acc, false), do: collect_tasks(rest, acc, false)

  defp verify_content_address!(path) do
    bytes = File.read!(path)
    expected = Path.basename(path, ".tsv")
    actual = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

    if expected == actual do
      path
    else
      raise "Mix Workspace Ops overlay digest mismatch at #{path}"
    end
  end
end
